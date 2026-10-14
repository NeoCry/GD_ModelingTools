@tool
extends RefCounted
var grid := false
var vertices := false
var edges := false
var edge_centers := false
var face_centers := false
var meshes: Array[Dictionary] = []
var candidate := {}

func clear() -> void:
	meshes.clear()
	candidate = {}

func has_geometry_targets() -> bool:
	return vertices or edges or edge_centers or face_centers

func begin(root: Node, source: MeshInstance3D, excluded: Array = []) -> void:
	clear()
	if not has_geometry_targets(): return
	_collect(root,source,excluded)

func _collect(current: Node, source: MeshInstance3D, excluded: Array = []) -> void:
	if current == source or current in excluded: return
	if current is MeshInstance3D and current.is_visible_in_tree() and current.mesh and current.skin == null:
		var data: Dictionary = ModelingKernels.snap_mesh_data(current)
		data.node = weakref(current)
		meshes.append(data)
	for child in current.get_children(): _collect(child,source,excluded)

static func grid_position(position: Vector3, origin: Vector3, axis: Vector3, step: float) -> Vector3:
	if step <= 0 or not is_finite(step): return position
	if axis.is_zero_approx(): return position.snapped(Vector3.ONE*step)
	var component := axis.abs().max_axis_index()
	return origin+axis*((snappedf(position[component],step)-origin[component])/axis[component])

func pick(camera: Camera3D, mouse: Vector2, radius: float, origin: Vector3, axis: Vector3, xray: bool = false) -> Dictionary:
	# Priority vertex > edge/face center > edge, then screen distance; hidden targets are skipped unless X-ray.
	candidate = ModelingKernels.snap_pick(meshes, camera, mouse, radius, origin, axis, vertices, edges, edge_centers, face_centers, xray)
	return candidate

func draw(control: Control, camera: Camera3D) -> void:
	if candidate.is_empty() or camera.is_position_behind(candidate.position): return
	var ratio := control.size/camera.get_viewport().get_visible_rect().size
	var point := camera.unproject_position(candidate.position)*ratio
	var color := Color(0,1,1)
	if candidate.kind == "Edge":
		var segment: PackedVector3Array = candidate.segment
		control.draw_line(camera.unproject_position(segment[0])*ratio,camera.unproject_position(segment[1])*ratio,Color.BLACK,7,true)
		control.draw_line(camera.unproject_position(segment[0])*ratio,camera.unproject_position(segment[1])*ratio,color,4,true)
	control.draw_circle(point,9,Color.BLACK,true,-1,true)
	control.draw_circle(point,7,color,true,-1,true)
	control.draw_circle(point,3,Color.WHITE,true,-1,true)
	if not camera.is_position_behind(candidate.snapped_position):
		var destination := camera.unproject_position(candidate.snapped_position)*ratio
		if destination.distance_to(point) > 3:
			control.draw_dashed_line(point,destination,color,2,6,true)
			control.draw_circle(destination,6,color,false,2,true)
	control.draw_string(control.get_theme_default_font(),point+Vector2(13,-12),"Snap: "+candidate.kind,HORIZONTAL_ALIGNMENT_LEFT,-1,16,color)
