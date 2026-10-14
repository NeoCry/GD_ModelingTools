@tool
extends RefCounted
const Selection = preload("res://addons/modeling_tool/editor/selection.gd")

static func edge_between(poly: PolyMesh, a: int, b: int) -> int:
	return poly.find_edge(a, b)

static func ring(poly: PolyMesh, seed: int) -> Dictionary:
	return poly.get_loop_ring(seed)

static func edge_point(poly: PolyMesh, eid: int, ratio: float) -> Vector3:
	var e := poly.get_edge(eid)
	var a: Vector3 = poly.get_vertex(e.vertex_a).position
	return a.lerp(poly.get_vertex(e.vertex_b).position,ratio)

static func ring_lines(poly: PolyMesh, topology: Dictionary, ratio: float, count: int) -> PackedVector3Array:
	if topology.is_empty(): return PackedVector3Array()
	return poly.get_ring_lines(topology.seed, ratio, count)

static func edge_loop(poly: PolyMesh, seed: int) -> PackedInt64Array:
	return poly.get_edge_loop(seed)

static func edge_ratio(node: EditableMesh, camera: Camera3D, eid: int, mouse: Vector2) -> float:
	var a := node.global_transform * edge_point(node.poly_mesh,eid,0)
	var b := node.global_transform * edge_point(node.poly_mesh,eid,1)
	var pa := camera.unproject_position(a)
	var pb := camera.unproject_position(b)
	var d := pb-pa
	var t := clampf((mouse-pa).dot(d)/maxf(d.length_squared(),0.000001),0,1)
	if camera.projection != Camera3D.PROJECTION_ORTHOGONAL:
		var view := camera.global_transform.affine_inverse()
		var za := maxf(0.00001,-(view*a).z)
		var zb := maxf(0.00001,-(view*b).z)
		t = (t/zb)/((1-t)/za+t/zb)
	return t

static func point_on_edge(poly: PolyMesh, eid: int, ratio: float) -> Dictionary:
	var e := poly.get_edge(eid)
	if ratio < 0.00001: return {"vertex": e.vertex_a, "position": poly.get_vertex(e.vertex_a).position}
	if ratio > 0.99999: return {"vertex": e.vertex_b, "position": poly.get_vertex(e.vertex_b).position}
	var t := snappedf(ratio,0.0000001)
	return {"edge": eid,"ratio": t,"position": edge_point(poly,eid,t)}

static func knife_point(node: EditableMesh, camera: Camera3D, mouse: Vector2, radius: float, allow_face: bool = false) -> Dictionary:
	var v := Selection.pick(node,camera,mouse,"vertex",false,minf(radius,12))
	if v >= 0: return {"vertex": v,"position": node.poly_mesh.get_vertex(v).position}
	var e := Selection.pick(node,camera,mouse,"edge",false,radius)
	if e < 0:
		if allow_face:
			var hit := Selection._face_hit(node,camera,mouse)
			if hit.id >= 0: return {"face":hit.id,"position":hit.position}
		return {}
	return point_on_edge(node.poly_mesh,e,edge_ratio(node,camera,e,mouse))

static func point_in_face(poly: PolyMesh, point: Dictionary, fid: int) -> bool:
	if point.has("face"): return point.face == fid
	if point.has("vertex"): return point.vertex in poly.get_face(fid).vertices
	return fid in poly.get_edge(point.edge).faces

static func knife_stroke(node: EditableMesh, camera: Camera3D, start: Dictionary, mouse: Vector2, radius: float) -> Array:
	var finish := knife_point(node,camera,mouse,radius,true)
	var a := camera.unproject_position(node.global_transform * Vector3(start.position))
	var b := camera.unproject_position(node.global_transform * Vector3(finish.position)) if not finish.is_empty() else mouse
	if a.distance_to(b) < 1: return []
	var points: Array = [{"screen":a,"point":start,"t":0.0}]
	if not finish.is_empty(): points.append({"screen":b,"point":finish,"t":1.0})
	for crossed in node.poly_mesh.knife_crossings(camera, node.global_transform, a, b):
		var eid: int = crossed.edge
		var crossing: Vector2 = crossed.screen
		var point := point_on_edge(node.poly_mesh,eid,edge_ratio(node,camera,eid,crossing))
		var distance := camera.global_position.distance_to(node.global_transform * Vector3(point.position))
		var hit := Selection._face_hit(node,camera,crossing)
		if distance > hit.distance + maxf(0.002,distance*0.0005): continue
		points.append({"screen":crossing,"point":point,"t":(Vector2(crossing)-a).dot(b-a)/(b-a).length_squared()})
	points.sort_custom(func(x: Dictionary,y: Dictionary) -> bool: return x.t < y.t)
	var unique: Array = []
	for point in points:
		if unique.is_empty() or Vector2(point.screen).distance_to(unique[-1].screen) > 0.1: unique.append(point)
	var segments: Array = []
	for i in range(unique.size()-1):
		var first: Dictionary = unique[i]
		var second: Dictionary = unique[i+1]
		var fid: int = Selection._face_hit(node,camera,Vector2(first.screen).lerp(second.screen,0.5)).id
		if fid < 0 or not point_in_face(node.poly_mesh,first.point,fid) or not point_in_face(node.poly_mesh,second.point,fid): continue
		segments.append({"face":fid,"a":first.point,"b":second.point})
	return segments

static func preview_mesh(lines: PackedVector3Array, markers: PackedVector3Array = PackedVector3Array()) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var positions := PackedVector3Array()
	var directions := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	for i in range(0,lines.size(),2): Selection._add_line(positions,directions,uvs,colors,lines[i],lines[i+1],Color.YELLOW)
	if not positions.is_empty():
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = positions
		arrays[Mesh.ARRAY_NORMAL] = directions
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_COLOR] = colors
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
		var material := Selection.overlay_material(false,false)
		material.set_shader_parameter("line_width_pixels",3.0)
		mesh.surface_set_material(0,material)
	positions = PackedVector3Array()
	uvs = PackedVector2Array()
	colors = PackedColorArray()
	for point in markers: Selection._add_marker(positions,uvs,colors,point,Color.YELLOW)
	Selection._add_marker_surface(mesh,positions,uvs,colors,false,10)
	return mesh
