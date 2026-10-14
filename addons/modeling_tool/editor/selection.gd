@tool
extends RefCounted
## Picking uses editable polygons, never generated render vertex indices.

static func selected_ids(poly: PolyMesh, mode: String) -> PackedInt64Array:
	match mode:
		"vertex": return poly.get_selected_vertices()
		"edge": return poly.get_selected_edges()
	return poly.get_selected_faces()

static func all_ids(poly: PolyMesh, mode: String) -> PackedInt64Array:
	match mode:
		"vertex": return poly.get_vertex_ids()
		"edge": return poly.get_edge_ids()
	return poly.get_face_ids()

static func inverted_ids(poly: PolyMesh, mode: String) -> PackedInt64Array:
	var selected := {}
	for id in selected_ids(poly, mode): selected[id] = true
	var result := PackedInt64Array()
	for id in all_ids(poly, mode):
		if not selected.has(id): result.append(id)
	return result

static func transform_ids(poly: PolyMesh, mode: String) -> PackedInt64Array:
	if mode not in ["vertex", "edge", "face"]: return PackedInt64Array()
	return poly.get_selection_vertices(mode)

static func _face_hit(node: EditableMesh, camera: Camera3D, mouse: Vector2) -> Dictionary:
	var inverse := node.global_transform.affine_inverse()
	var origin := inverse * camera.project_ray_origin(mouse)
	var direction := inverse.basis * camera.project_ray_normal(mouse)
	var hit: Dictionary = node.poly_mesh.raycast(origin, direction)
	if hit.id < 0: return {"id": -1, "distance": INF, "position": Vector3.ZERO}
	var position: Vector3 = hit.position
	return {"id": hit.id, "distance": camera.global_position.distance_to(node.global_transform * position), "position": position}

static func pick(node: EditableMesh, camera: Camera3D, mouse: Vector2, mode: String, xray: bool, radius: float = 20.0) -> int:
	if mode == "face": return _face_hit(node, camera, mouse).id
	# Sorted by screen distance, then depth, then ID.
	for candidate in node.poly_mesh.pick_candidates(camera, node.global_transform, mouse, mode, radius):
		if not xray:
			# Check occlusion at the candidate, not at the nearby mouse position.
			var hit := _face_hit(node, camera, candidate.point)
			if candidate.depth > hit.distance + maxf(0.002, candidate.depth * 0.0005): continue
		return candidate.id
	return -1

static func overlay(node: EditableMesh, mode: String, xray: bool = false) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if not node or not node.poly_mesh: return mesh
	var poly := node.poly_mesh
	var wire: Array = poly.build_wire_arrays(mode, PackedColorArray([Color.GREEN, Color.RED, Color("cc70ff"), Color("45cfff")]))
	if not wire.is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, wire)
		mesh.surface_set_material(0, _shared_material("line", xray))
	if mode == "vertex":
		var markers: Array = poly.build_marker_arrays(PackedColorArray([Color.GREEN, Color.RED]))
		if not markers.is_empty():
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, markers)
			mesh.surface_set_material(mesh.get_surface_count()-1, _shared_material("marker", xray))
	if mode == "face":
		var fill := poly.get_face_triangles(poly.get_selected_faces())
		if not fill.is_empty():
			var fill_colors := PackedColorArray()
			fill_colors.resize(fill.size())
			fill_colors.fill(Color(1,0,0,0.25))
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = fill
			arrays[Mesh.ARRAY_COLOR] = fill_colors
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			mesh.surface_set_material(mesh.get_surface_count()-1, _shared_material("fill", xray))
	return mesh

# Overlays are rebuilt on every edit; reuse their materials instead of allocating new ones.
static var _materials := {}

static func _shared_material(kind: String, xray: bool) -> ShaderMaterial:
	var key := "%s/%s" % [kind, xray]
	var material: ShaderMaterial = _materials.get(key)
	if material: return material
	if kind == "marker": material = marker_material(7.0, xray)
	else: material = overlay_material(kind == "fill", xray)
	_materials[key] = material
	return material

static func hover_overlay(node: EditableMesh, mode: String, id: int, xray: bool = false) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if id < 0 or not node or not node.poly_mesh: return mesh
	var poly := node.poly_mesh
	var color := Color.RED if id in selected_ids(poly, mode) else Color.YELLOW
	var positions := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	if mode == "vertex":
		var vertex := poly.get_vertex(id)
		if vertex.is_empty(): return mesh
		_add_marker(positions, uvs, colors, vertex.position, color)
		_add_marker_surface(mesh, positions, uvs, colors, xray, 11.0)
	elif mode == "edge":
		var edge := poly.get_edge(id)
		if edge.is_empty(): return mesh
		var directions := PackedVector3Array()
		_add_line(positions, directions, uvs, colors, poly.get_vertex(edge.vertex_a).position, poly.get_vertex(edge.vertex_b).position, color)
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = positions
		arrays[Mesh.ARRAY_NORMAL] = directions
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_COLOR] = colors
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var material := overlay_material(false, xray)
		material.set_shader_parameter("line_width_pixels", 4.0)
		material.render_priority = 3
		mesh.surface_set_material(0, material)
	return mesh

static func _add_marker(positions: PackedVector3Array, uvs: PackedVector2Array, colors: PackedColorArray, position: Vector3, color: Color) -> void:
	for uv in [Vector2(-1,-1),Vector2(-1,1),Vector2(1,1),Vector2(-1,-1),Vector2(1,1),Vector2(1,-1)]:
		positions.append(position)
		uvs.append(uv)
		colors.append(color)

static func _add_marker_surface(mesh: ArrayMesh, positions: PackedVector3Array, uvs: PackedVector2Array, colors: PackedColorArray, xray: bool, size: float) -> void:
	if positions.is_empty(): return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(mesh.get_surface_count()-1, marker_material(size, xray))

static func marker_material(size: float, xray: bool) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load("res://addons/modeling_tool/editor/overlay_marker.gdshader")
	material.set_shader_parameter("size_pixels", size)
	material.set_shader_parameter("xray", xray)
	material.render_priority = 3
	return material

static func _add_line(positions: PackedVector3Array, directions: PackedVector3Array, sides: PackedVector2Array, colors: PackedColorArray, a: Vector3, b: Vector3, color: Color) -> void:
	var direction := (b-a).normalized()
	for corner in [Vector2(0,-1),Vector2(0,1),Vector2(1,1),Vector2(0,-1),Vector2(1,1),Vector2(1,-1)]:
		positions.append(a if corner.x == 0 else b)
		directions.append(direction)
		sides.append(Vector2(corner.y,0))
		colors.append(color)

static func overlay_material(fill: bool = false, xray: bool = false) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load("res://addons/modeling_tool/editor/overlay_fill.gdshader" if fill else "res://addons/modeling_tool/editor/overlay_line.gdshader")
	material.set_shader_parameter("xray", xray)
	if not fill: material.set_shader_parameter("line_width_pixels", 2.0)
	material.render_priority = 1 if fill else 2
	return material
