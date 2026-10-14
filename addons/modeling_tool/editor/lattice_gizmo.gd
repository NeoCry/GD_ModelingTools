@tool
extends EditorNode3DGizmoPlugin
## Lattice3D cage in the viewport. Its control points are sub-gizmos: click or
## box-select them (Shift adds), then move, rotate or scale them with the standard
## Godot transform gizmo (W / E / R). Every edit is one undo step.

var editor_plugin: EditorPlugin
var point_material: StandardMaterial3D
var selected_material: StandardMaterial3D

func _init() -> void:
	create_material("cage", Color(0.95, 0.6, 0.2, 0.85), false, true)
	point_material = dot_material(Color(0.95, 0.6, 0.2))
	selected_material = dot_material(Color(1, 1, 1))

func dot_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.use_point_size = true
	material.point_size = 9
	material.no_depth_test = true
	material.albedo_color = color
	material.render_priority = 1
	return material

func _has_gizmo(node: Node3D) -> bool:
	return node is Lattice3D

func _get_gizmo_name() -> String:
	return "Lattice"

func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var lattice := gizmo.get_node_3d() as Lattice3D
	if not lattice or lattice.points.size() != lattice.get_point_count(): return
	var points := lattice.points
	var resolution := lattice.resolution
	var lines := PackedVector3Array()
	for k in resolution.z:
		for j in resolution.y:
			for i in resolution.x:
				var here := points[lattice.point_index(i, j, k)]
				if i + 1 < resolution.x: lines.append_array([here, points[lattice.point_index(i + 1, j, k)]])
				if j + 1 < resolution.y: lines.append_array([here, points[lattice.point_index(i, j + 1, k)]])
				if k + 1 < resolution.z: lines.append_array([here, points[lattice.point_index(i, j, k + 1)]])
	gizmo.add_lines(lines, get_material("cage", gizmo))
	var normal := PackedVector3Array()
	var selected := PackedVector3Array()
	for index in points.size():
		if gizmo.is_subgizmo_selected(index): selected.append(points[index])
		else: normal.append(points[index])
	for pair in [[normal, point_material], [selected, selected_material]]:
		if pair[0].is_empty(): continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = pair[0]
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
		gizmo.add_mesh(mesh, pair[1])

func _subgizmos_intersect_ray(gizmo: EditorNode3DGizmo, camera: Camera3D, screen_position: Vector2) -> int:
	var lattice := gizmo.get_node_3d() as Lattice3D
	var best := -1
	var closest := 12.0
	for index in lattice.points.size():
		var world := lattice.global_transform * lattice.points[index]
		if camera.is_position_behind(world): continue
		var distance := camera.unproject_position(world).distance_to(screen_position)
		if distance < closest:
			closest = distance
			best = index
	return best

func _subgizmos_intersect_frustum(gizmo: EditorNode3DGizmo, camera: Camera3D, frustum: Array[Plane]) -> PackedInt32Array:
	var lattice := gizmo.get_node_3d() as Lattice3D
	var inside := PackedInt32Array()
	for index in lattice.points.size():
		var world := lattice.global_transform * lattice.points[index]
		var contained := true
		for plane in frustum:
			if plane.is_point_over(world): contained = false; break
		if contained: inside.append(index)
	return inside

func _get_subgizmo_transform(gizmo: EditorNode3DGizmo, id: int) -> Transform3D:
	var lattice := gizmo.get_node_3d() as Lattice3D
	return Transform3D(Basis(), lattice.points[id])

func _set_subgizmo_transform(gizmo: EditorNode3DGizmo, id: int, transform: Transform3D) -> void:
	var lattice := gizmo.get_node_3d() as Lattice3D
	var points := lattice.points
	points[id] = transform.origin
	lattice.points = points

func _commit_subgizmos(gizmo: EditorNode3DGizmo, ids: PackedInt32Array, restores: Array[Transform3D], cancel: bool) -> void:
	var lattice := gizmo.get_node_3d() as Lattice3D
	var before := lattice.points.duplicate()
	for index in ids.size(): before[ids[index]] = restores[index].origin
	if cancel:
		lattice.points = before
		return
	var undo := editor_plugin.get_undo_redo()
	undo.create_action("Move lattice points", UndoRedo.MERGE_DISABLE, lattice)
	undo.add_do_property(lattice, "points", lattice.points.duplicate())
	undo.add_undo_property(lattice, "points", before)
	undo.commit_action()
