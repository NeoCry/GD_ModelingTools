@tool
extends EditorNode3DGizmoPlugin
const Selection = preload("res://addons/modeling_tool/editor/selection.gd")
const AXES := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
const RADIUS := 0.65
var editor_plugin: EditorPlugin
var preview_delta: MeshDelta
var drag_center := Vector3.ZERO
var drag_ids := PackedInt64Array()
var drag_tool := "move"
var drag_node: WeakRef
var dragging := false

func _init() -> void:
	create_material("x", Color("ef7373"), false, true)
	create_material("y", Color("88d89b"), false, true)
	create_material("z", Color("78a5ff"), false, true)
	create_material("uniform", Color.WHITE, false, true)
	create_handle_material("handles")

func _has_gizmo(node: Node3D) -> bool:
	return node is EditableMesh

func _get_gizmo_name() -> String:
	return "Polygon selection"

func center(node: EditableMesh) -> Vector3:
	var ids := Selection.transform_ids(node.poly_mesh, editor_plugin.panel.mode)
	var value := Vector3.ZERO
	for position in node.poly_mesh.get_vertex_positions(ids): value += position
	return value / ids.size() if not ids.is_empty() else value

func ring_direction(axis: int, angle: float) -> Vector3:
	var u: Vector3 = AXES[(axis + 1) % 3]
	var v: Vector3 = AXES[axis].cross(u)
	return u * cos(angle) + v * sin(angle)

func handle_offsets(tool: String) -> PackedVector3Array:
	var points := PackedVector3Array()
	if tool == "rotate":
		for axis in 3:
			for quadrant in 4:
				points.append(ring_direction(axis, PI * 0.25 + quadrant * PI * 0.5) * RADIUS)
	else:
		for axis in AXES: points.append(axis * RADIUS)
		if tool == "scale": points.append(Vector3.ONE.normalized() * RADIUS)
		elif tool == "move": points.append(Vector3.ZERO)
	return points

func hit_handle(node: EditableMesh, camera: Camera3D, mouse: Vector2) -> bool:
	if editor_plugin.cut_tool.kind != "" or editor_plugin.offset_tool.active or editor_plugin.workflow.mode!="": return false
	if Selection.transform_ids(node.poly_mesh, editor_plugin.panel.mode).is_empty(): return false
	var origin := center(node)
	for offset in handle_offsets(editor_plugin.transform_mode):
		var point: Vector3 = node.global_transform * (origin + offset)
		if not camera.is_position_behind(point) and camera.unproject_position(point).distance_to(mouse) < 14: return true
	return false

func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var node := gizmo.get_node_3d() as EditableMesh
	if not node.poly_mesh or not is_instance_valid(editor_plugin) or editor_plugin.target != node or not editor_plugin.edit_polygons or editor_plugin.cut_tool.kind != "" or editor_plugin.offset_tool.active or editor_plugin.workflow.mode!="": return
	if Selection.transform_ids(node.poly_mesh, editor_plugin.panel.mode).is_empty(): return
	var origin := center(node)
	var tool: String = editor_plugin.transform_mode
	if tool == "rotate":
		for axis in 3:
			var lines := PackedVector3Array()
			for segment in 64:
				lines.append(origin + ring_direction(axis, TAU * segment / 64.0) * RADIUS)
				lines.append(origin + ring_direction(axis, TAU * (segment+1) / 64.0) * RADIUS)
			gizmo.add_lines(lines, get_material(["x","y","z"][axis], gizmo))
	var handles := PackedVector3Array()
	var ids := PackedInt32Array()
	var offsets := handle_offsets(tool)
	for i in offsets.size():
		var endpoint := origin + offsets[i]
		if tool != "rotate" and not offsets[i].is_zero_approx():
			var lines := PackedVector3Array([origin,endpoint])
			if tool == "scale":
				var a: Vector3 = AXES[(i+1)%3] * 0.045
				var b: Vector3 = AXES[(i+2)%3] * 0.045
				var corners := [endpoint-a-b,endpoint+a-b,endpoint+a+b,endpoint-a+b]
				for j in 4: lines.append_array(PackedVector3Array([corners[j],corners[(j+1)%4]]))
			gizmo.add_lines(lines, get_material(["x","y","z","uniform"][i], gizmo))
		handles.append(endpoint)
		ids.append(i)
	gizmo.add_handles(handles, get_material("handles", gizmo), ids)

func _get_handle_name(_gizmo: EditorNode3DGizmo, id: int, _secondary: bool) -> String:
	var tool: String = editor_plugin.transform_mode
	if tool == "move" and id == 3: return "Free move / snap selection center"
	var axis := int(id / 4) if tool == "rotate" else id
	return tool.capitalize() + " selection " + ["X","Y","Z","uniform"][axis]

func _get_handle_value(gizmo: EditorNode3DGizmo, _id: int, _secondary: bool) -> Variant:
	return center(gizmo.get_node_3d())

func _set_handle(gizmo: EditorNode3DGizmo, id: int, _secondary: bool, camera: Camera3D, screen_pos: Vector2) -> void:
	var node := gizmo.get_node_3d() as EditableMesh
	var poly := node.poly_mesh
	if not dragging:
		drag_center = center(node)
		drag_ids = Selection.transform_ids(poly, editor_plugin.panel.mode)
		drag_tool = editor_plugin.transform_mode
		drag_node = weakref(node)
		dragging = true
		if drag_tool == "move": editor_plugin.snapping.begin(editor_plugin.get_editor_interface().get_edited_scene_root(),node)
	var inverse := node.global_transform.affine_inverse()
	var ray_origin := inverse * camera.project_ray_origin(screen_pos)
	var ray_direction := (inverse.basis * camera.project_ray_normal(screen_pos)).normalized()
	var transform := Transform3D.IDENTITY
	var snap := Input.is_key_pressed(KEY_CTRL)
	if drag_tool == "move" and id == 3:
		var world_center := node.global_transform*drag_center
		var plane := Plane(camera.global_transform.basis.z,world_center)
		var point = plane.intersects_ray(camera.project_ray_origin(screen_pos),camera.project_ray_normal(screen_pos))
		if point == null: return
		transform.origin = editor_plugin.snap_move(node,camera,screen_pos,drag_center,inverse*Vector3(point)-drag_center,Vector3.ZERO,snap)
	elif drag_tool == "rotate":
		var axis_id := int(id / 4)
		var axis: Vector3 = AXES[axis_id]
		var initial := ring_direction(axis_id, PI * 0.25 + (id % 4) * PI * 0.5)
		var denominator := axis.dot(ray_direction)
		var angle: float
		if absf(denominator) > 0.0001:
			var distance := axis.dot(drag_center-ray_origin) / denominator
			var radial := ray_origin + ray_direction*distance - drag_center
			if radial.length_squared() < 0.000001: return
			angle = initial.signed_angle_to(radial.normalized(), axis)
		else:
			# Edge-on ring: use its screen tangent instead of an unstable plane hit.
			var start := node.global_transform * (drag_center + initial * RADIUS)
			var tangent := node.global_transform.basis * axis.cross(initial) * RADIUS
			var screen_start := camera.unproject_position(start)
			var screen_tangent := camera.unproject_position(start+tangent) - screen_start
			if screen_tangent.length_squared() < 0.0001: return
			angle = (screen_pos-screen_start).dot(screen_tangent) / screen_tangent.length_squared()
		if snap: angle = snappedf(angle, deg_to_rad(15))
		transform.basis = Basis(axis, angle)
		transform.origin = drag_center - transform.basis * drag_center
	else:
		var axis: Vector3 = Vector3.ONE.normalized() if id == 3 else AXES[id]
		var parameter: float
		if drag_tool == "scale" and id == 3:
			# Uniform scale also works when the diagonal points at the camera.
			var start := camera.unproject_position(node.global_transform * (drag_center+axis*RADIUS))
			parameter = RADIUS * exp(((screen_pos-start).x-(screen_pos-start).y) * 0.01)
		else:
			var closest := Geometry3D.get_closest_points_between_segments(drag_center-axis*10000, drag_center+axis*10000, ray_origin, ray_origin+ray_direction*10000)
			parameter = (closest[0]-drag_center).dot(axis)
		if drag_tool == "move":
			var amount := parameter - RADIUS
			transform.origin = editor_plugin.snap_move(node,camera,screen_pos,drag_center,axis*amount,axis,snap)
		else:
			var factor := parameter / RADIUS
			if snap: factor = snappedf(factor, 0.1)
			factor = clampf(factor, 0.01, 100.0)
			var scale := Vector3.ONE * factor if id == 3 else Vector3.ONE + axis * (factor-1.0)
			transform.basis = Basis.from_scale(scale)
			transform.origin = drag_center - transform.basis * drag_center
	# Revert silently: the new preview below notifies once, so the mesh and
	# overlays are rebuilt once per drag step instead of twice.
	var reverted := false
	if preview_delta:
		reverted = poly.apply_delta(preview_delta, false, false)
		preview_delta = null
	var result := preload("res://addons/modeling_tool/editor/geometry_tools.gd").transform(poly,drag_ids,transform,editor_plugin.clip_options())
	if result.ok:
		preview_delta = result.delta
	else:
		if reverted:
			poly.emit_changed()
			poly.emit_signal("selection_changed")
		editor_plugin.panel.report(result.error, true)
	poly.clear_history()

func cancel_drag() -> void:
	if is_instance_valid(editor_plugin):
		editor_plugin.snapping.clear()
		editor_plugin.update_overlays()
	var node: EditableMesh = drag_node.get_ref() if drag_node else null
	if preview_delta and is_instance_valid(node): node.poly_mesh.apply_delta(preview_delta, false)
	preview_delta = null
	drag_node = null
	dragging = false

func _commit_handle(gizmo: EditorNode3DGizmo, _id: int, _secondary: bool, _restore: Variant, cancel: bool) -> void:
	var node := gizmo.get_node_3d() as EditableMesh
	if cancel:
		cancel_drag()
		return
	dragging = false
	drag_node = null
	editor_plugin.snapping.clear()
	editor_plugin.update_overlays()
	if not preview_delta: return
	var delta := preview_delta
	preview_delta = null
	var poly := node.poly_mesh
	var selected := Selection.selected_ids(poly, editor_plugin.panel.mode)
	editor_plugin._record_delta(poly, delta, drag_tool.capitalize() + " selection", selected, selected)
