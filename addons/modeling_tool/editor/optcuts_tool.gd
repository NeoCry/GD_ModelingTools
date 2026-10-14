@tool
extends RefCounted
var job := ""
var cancelled := false
const BIN := "res://addons/modeling_tool/bin/optcuts/"

func cancel() -> void:
	cancelled = true
	if not job.is_empty():
		var file := FileAccess.open(job.path_join("cancel"),FileAccess.WRITE)
		if file: file.close()

func unwrap(tree: SceneTree, source: ArrayMesh) -> Dictionary:
	cancelled = false
	if OS.get_name() != "Windows": return fail("Bundled OptCuts supports Windows x64")
	var exe := ProjectSettings.globalize_path(BIN+"OptCuts_bin-windows-x86_64.exe")
	if not FileAccess.file_exists(exe): return fail("OptCuts executable is missing; reinstall the complete addon")
	var vertices := PackedVector3Array()
	var vertex_map := {}
	var triangles: Array[Dictionary] = []
	var surfaces: Array[Array] = []
	var adjacency := {}
	for surface in source.get_surface_count():
		var arrays := source.surface_get_arrays(surface).duplicate(true)
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		# PolyMesh export is a triangle list with per-corner attributes.
		if positions.size()%3 != 0: return fail("Invalid triangulated mesh")
		arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array()
		arrays[Mesh.ARRAY_TEX_UV].resize(positions.size())
		surfaces.append(arrays)
		for i in range(0,positions.size(),3):
			var ids := PackedInt32Array()
			for k in 3:
				var p := positions[i+k]
				if not vertex_map.has(p):
					vertex_map[p] = vertices.size()
					vertices.append(p)
				var id: int = vertex_map[p]
				ids.append(id)
				if not adjacency.has(id): adjacency[id] = []
				adjacency[id].append(triangles.size())
			triangles.append({"ids":ids,"surface":surface,"offset":i})
	if triangles.is_empty(): return fail("Mesh has no faces")
	var unseen := {}
	for i in triangles.size(): unseen[i] = true
	var components: Array[Array] = []
	while not unseen.is_empty():
		var stack := [unseen.keys()[0]]
		var component := []
		while not stack.is_empty():
			var t: int = stack.pop_back()
			if not unseen.has(t): continue
			unseen.erase(t)
			component.append(t)
			for v in triangles[t].ids:
				for neighbor in adjacency[v]:
					if unseen.has(neighbor): stack.append(neighbor)
		components.append(component)
	var columns := ceili(sqrt(components.size()))
	for c in components.size():
		if cancelled: return fail("OptCuts cancelled")
		job = ProjectSettings.globalize_path("res://.godot/modeling_optcuts/%d_%d_%d" % [OS.get_process_id(),Time.get_ticks_usec(),c])
		if DirAccess.make_dir_recursive_absolute(job) != OK: return fail("Cannot create OptCuts working directory")
		var text := ""
		var local_vertices := PackedVector3Array()
		var local_ids := {}
		var lookup := {}
		for t in components[c]:
			for v in triangles[t].ids:
				if not local_ids.has(v):
					local_ids[v] = local_vertices.size()
					local_vertices.append(vertices[v])
		for p in local_vertices: text += "v %.17f %.17f %.17f\n" % [p.x,p.y,p.z]
		for t in components[c]:
			var ids: PackedInt32Array = triangles[t].ids
			var a: int = local_ids[ids[0]]
			var b: int = local_ids[ids[1]]
			var d: int = local_ids[ids[2]]
			var key := face_key(PackedInt32Array([a,b,d]))
			if lookup.has(key): return fail("OptCuts requires non-overlapping manifold faces")
			lookup[key] = {"triangle":t,"ids":PackedInt32Array([a,b,d])}
			# OBJ uses opposite winding to Godot.
			text += "f %d %d %d\n" % [a+1,d+1,b+1]
		var file := FileAccess.open(job.path_join("input.obj"),FileAccess.WRITE)
		if not file: return fail("Cannot write OptCuts input")
		file.store_string(text)
		file.close()
		var pid := OS.create_process("powershell.exe",PackedStringArray(["-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-File",ProjectSettings.globalize_path(BIN+"run.ps1"),"-JobDir",job,"-Executable",exe]),false)
		if pid < 0: return fail("Cannot start OptCuts")
		var deadline := Time.get_ticks_msec()+190000
		while not FileAccess.file_exists(job.path_join("done.json")):
			await tree.create_timer(0.1).timeout
			if cancelled: return fail("OptCuts cancelled")
			if Time.get_ticks_msec()>deadline:
				cancel()
				return fail("OptCuts timed out; see "+job)
		var status = JSON.parse_string(FileAccess.get_file_as_string(job.path_join("done.json")).trim_prefix("\ufeff"))
		if not status is Dictionary or status.get("exit_code",-1) != 0: return fail("OptCuts failed; logs: "+job)
		var output := find_output(job)
		if output.is_empty(): return fail("OptCuts did not produce UV coordinates; logs: "+job)
		var parsed := read_uv(output,local_vertices,lookup)
		if not parsed.ok: return parsed
		var lo := Vector2(INF,INF)
		var hi := -lo
		for values in parsed.uv.values():
			for uv in values:
				lo = lo.min(uv)
				hi = hi.max(uv)
		var scale := maxf((hi-lo).x,(hi-lo).y)
		if scale<0.000001: return fail("OptCuts returned degenerate UVs")
		for t in parsed.uv:
			var tri: Dictionary = triangles[t]
			var uv: PackedVector2Array = surfaces[tri.surface][Mesh.ARRAY_TEX_UV]
			for k in 3:
				uv[tri.offset+k] = (Vector2(c%columns,int(c/columns))+Vector2.ONE*0.02+(parsed.uv[t][k]-lo)/scale*0.96)/columns
			surfaces[tri.surface][Mesh.ARRAY_TEX_UV] = uv
	var mesh := ArrayMesh.new()
	for s in surfaces.size():
		# Tangents are recalculated by PolyMesh when importing the result.
		surfaces[s][Mesh.ARRAY_TANGENT] = null
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,surfaces[s])
		mesh.surface_set_material(s,source.surface_get_material(s))
	return {"ok":true,"mesh":mesh}

static func face_key(ids: PackedInt32Array) -> String:
	var sorted := ids.duplicate()
	sorted.sort()
	return "%d/%d/%d" % [sorted[0],sorted[1],sorted[2]]

static func find_output(path: String) -> String:
	for name in DirAccess.get_files_at(path):
		if name == "finalResult_mesh.obj": return path.path_join(name)
	for name in DirAccess.get_directories_at(path):
		var found := find_output(path.path_join(name))
		if not found.is_empty(): return found
	return ""

static func read_uv(path: String, original: PackedVector3Array, lookup: Dictionary) -> Dictionary:
	var mapping := PackedInt32Array()
	var texcoords := PackedVector2Array()
	var faces: Array[PackedStringArray] = []
	var bounds := AABB(original[0],Vector3.ZERO)
	for p in original: bounds = bounds.expand(p)
	var tolerance := maxf(bounds.size.length()*0.00001,0.000001)
	var position_cache := {}
	for i in original.size(): position_cache[original[i]] = i
	for line in FileAccess.get_file_as_string(path).split("\n"):
		var values := line.strip_edges().replace("\t"," ").split(" ",false)
		if values.is_empty(): continue
		if values[0] == "v" and values.size() >= 4:
			var point := Vector3(float(values[1]),float(values[2]),float(values[3]))
			var found: int = position_cache.get(point,-1)
			if found < 0:
				for i in original.size():
					if original[i].distance_to(point)<=tolerance:
						found = i
						break
				if found >= 0: position_cache[point] = found
			if found<0: return fail("OptCuts changed geometry; original mesh preserved")
			mapping.append(found)
		elif values[0] == "vt" and values.size()>=3:
			var uv := Vector2(float(values[1]),float(values[2]))
			if not uv.is_finite(): return fail("Invalid OptCuts UV")
			texcoords.append(uv)
		elif values[0] == "f": faces.append(values)
	var result := {}
	for face in faces:
		if face.size()!=4: return fail("OptCuts returned a non-triangle face")
		var ids := PackedInt32Array()
		var uv := PackedVector2Array()
		for k in range(1,4):
			var indices := face[k].split("/")
			if indices.size()<2: return fail("OptCuts output has no UVs")
			var v := int(indices[0])-1
			var t := int(indices[1])-1
			if v<0 or v>=mapping.size() or t<0 or t>=texcoords.size(): return fail("Invalid OptCuts OBJ indices")
			ids.append(mapping[v])
			uv.append(texcoords[t])
		var key := face_key(ids)
		if not lookup.has(key): return fail("OptCuts changed faces; original mesh preserved")
		var source: Dictionary = lookup[key]
		if result.has(source.triangle): return fail("Duplicate OptCuts face")
		var ordered := PackedVector2Array()
		for v in source.ids: ordered.append(uv[ids.find(v)])
		result[source.triangle] = ordered
	if result.size()!=lookup.size(): return fail("Incomplete OptCuts output")
	return {"ok":true,"uv":result}

static func fail(message: String) -> Dictionary:
	return {"ok":false,"error":message}
