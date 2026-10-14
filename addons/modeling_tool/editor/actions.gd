@tool
extends RefCounted
const GeometryTools = preload("res://addons/modeling_tool/editor/geometry_tools.gd")
const Selection = preload("res://addons/modeling_tool/editor/selection.gd")

static func run(poly: PolyMesh, mode: String, name: String, options: Dictionary) -> Dictionary:
	if name in ["merge","weld","cleanup"]: options["allow_non_manifold"]=true
	var ids := Selection.selected_ids(poly, mode)
	if name == "shade": ids = poly.get_face_ids()
	if name == "weighted_normals":
		ids = poly.get_selected_faces() if mode == "face" else PackedInt64Array()
		if ids.is_empty(): ids = poly.get_face_ids()
	if name=="dissolve" and mode=="vertex": name="dissolve_vertices"
	if name=="collapse" and mode=="face": name="collapse_faces"
	if name=="bridge" and mode=="face": name="bridge_faces"
	if name=="bevel" and mode=="vertex": name="bevel_vertices"
	if name=="connect":
		if mode != "vertex": return {"ok": false, "error": "Connect joins vertices: switch to Vertex mode and select two vertices of one polygon"}
		var connected := poly.execute("connect", ids, options)
		if connected.ok: poly.select("vertex", ids)
		return connected
	if name=="circle":
		# Circle works on the vertices of any selection; a polygon patch rounds its border.
		ids = poly.get_selection_vertices(mode)
		var rounded := poly.execute("circle", ids, options)
		if rounded.ok: poly.select(mode, Selection.selected_ids(poly, mode))
		return rounded
	var face_ops := ["bridge_faces", "collapse_faces", "extrude_normals", "inset", "triangulate", "untriangulate", "subdivide", "flip", "material", "uv"]
	var edge_ops := ["edge_attributes", "bevel", "loop_cut", "split_edge", "dissolve", "collapse", "fill", "bridge"]
	if name in face_ops and mode != "face": return {"ok": false, "error": "Switch to Face mode for this operation"}
	if name == "bridge" and mode != "edge": return {"ok": false, "error": "Bridge works on two edge loops (Edge mode) or two polygons / regions (Polygon mode)"}
	if name in edge_ops and mode != "edge": return {"ok": false, "error": "Bevel works on edges (Edge mode) or vertices (Vertex mode)" if name == "bevel" else "Switch to Edge mode for this operation"}
	if name == "merge" and mode != "vertex": return {"ok": false, "error": "Switch to Vertex mode to merge"}
	if name == "extrude":
		name = "extrude_faces" if mode == "face" else "extrude_edges" if mode == "edge" else "extrude_vertices"
		if options.get("auto", false) and not ids.is_empty():
			options.distance = float(poly.suggest_amount(name, ids).value)
		if int(options.get("axis",-1))>=0:
			var direction := Vector3.ZERO
			direction[int(options.axis)]=1
			options.offset=direction*options.get("distance",0.25)
		elif mode != "face": options.offset = Vector3.UP * options.get("distance", 0.25)
	if name == "delete": name = "delete_faces" if mode == "face" else "delete_edges" if mode == "edge" else "delete_vertices"
	if name in ["move", "rotate", "scale"]:
		ids = Selection.transform_ids(poly, mode)
		var center := Vector3.ZERO
		for position in poly.get_vertex_positions(ids): center += position
		if not ids.is_empty(): center /= ids.size()
		var vector: Vector3 = options.vector
		var transform := Transform3D.IDENTITY
		if name == "move": transform.origin = vector
		else:
			transform.basis = Basis.from_euler(vector * PI / 180.0) if name == "rotate" else Basis.from_scale(Vector3.ONE + vector)
			transform.origin = center - transform.basis * center
		options.transform = transform
		var clip := {}
		for key in ["clip_axes","clip_center","clip_distance","symmetry_axes","symmetry_center"]: if options.has(key): clip[key] = options[key]
		return GeometryTools.transform(poly,ids,transform,clip)
	if name == "knife":
		var vertices := poly.get_selected_vertices()
		var faces := poly.get_selected_faces()
		if vertices.size() != 2 or faces.size() != 1:
			return {"ok": false, "error": "Knife: select one face, switch to Vertex, select two non-adjacent corners"}
		ids = faces
		options.a = vertices[0]
		options.b = vertices[1]
	var result := poly.execute(name, ids, options)
	if result.ok:
		var key := "new_vertices" if mode == "vertex" else "new_edges" if mode == "edge" else "new_faces"
		if not result[key].is_empty(): poly.select(mode, result[key])
	return result
