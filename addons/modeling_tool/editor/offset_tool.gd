@tool
extends RefCounted
const Selection = preload("res://addons/modeling_tool/editor/selection.gd")
const GeometryTools = preload("res://addons/modeling_tool/editor/geometry_tools.gd")
var operation := "bevel"
var mode := "edge"
var result_key := "new_edges"
var plugin: EditorPlugin
var active := false
var updating := false
var node: EditableMesh
var poly: PolyMesh
var ids := PackedInt64Array()
var delta: MeshDelta
var result := {}
var width := 0.0
var count := 1
var vertex_rail := 0
var offset_even := false
var individual := false
var error := ""
var mouse_start := Vector2.ZERO
var dragging := false
var anchor := Vector3.ZERO
var direction := Vector3.ZERO
var drag_direction := Vector2.ZERO
var initial_width := 0.0
var units_per_pixel := 0.01
var max_width := -1.0
var auto_amount := false

func start(owner_plugin: EditorPlugin, options: Dictionary, tool: String = "bevel") -> void:
	cancel()
	plugin = owner_plugin
	if tool == "bevel" and plugin.panel.mode == "vertex": tool = "bevel_vertices"
	operation = tool
	mode = "face" if tool in ["inset","extrude_normals"] else "vertex" if tool in ["slide_vertex","bevel_vertices"] else "edge"
	result_key = "new_faces" if tool in ["inset","extrude_normals"] else "new_vertices" if tool in ["slide_vertex","bevel_vertices"] else "new_edges"
	if plugin.panel.mode != mode or Selection.selected_ids(plugin.target.poly_mesh,mode).is_empty():
		plugin.panel.report(tool.capitalize()+": select polygons in Face mode first" if tool in ["inset","extrude_normals"] else "Slide Vertex: select vertices in Vertex mode first" if tool=="slide_vertex" else "Bevel: select vertices first" if tool=="bevel_vertices" else tool.capitalize()+": select edges in Edge mode first",true)
		return
	plugin.cut_tool.cancel()
	plugin.gizmo_plugin.cancel_drag()
	node = plugin.target
	poly = node.poly_mesh
	ids = Selection.selected_ids(poly,mode)
	width = maxf(0.00001,float(options.get("amount" if operation == "inset" else "width",0.25)))
	if operation in ["slide_edge","slide_vertex"]: width=0.0
	vertex_rail=0
	if operation=="extrude_normals": width=float(options.get("distance",0.25))
	offset_even=bool(options.get("offset_even",false))
	individual=bool(options.get("individual",false))
	count = clampi(int(options.get("segments",1)),1,32)
	auto_amount = bool(options.get("auto",false))
	max_width = -1.0
	if auto_amount and operation in ["bevel","bevel_vertices","inset","extrude_normals"]:
		width = suggest(true)
		plugin.panel.show_amount(width)
	initial_width = width
	dragging = false
	anchor = Vector3.ZERO
	direction = Vector3.ZERO
	for id in ids:
		if operation in ["inset","extrude_normals"]:
			var face := poly.get_face(id)
			var center := Vector3.ZERO
			for vid in face.vertices: center += Vector3(poly.get_vertex(vid).position)
			center /= face.vertices.size()
			anchor += center
			# Place the handle along the face plane towards its first edge midpoint.
			var midpoint := (Vector3(poly.get_vertex(face.vertices[0]).position)+Vector3(poly.get_vertex(face.vertices[1]).position))*0.5
			direction += Vector3(face.normal) if operation=="extrude_normals" else (midpoint-center).normalized()
		elif operation=="slide_vertex":
			anchor+=Vector3(poly.get_vertex(id).position)
		elif operation=="bevel_vertices":
			# The handle points away from the neighbours, i.e. out of a convex corner.
			var position := Vector3(poly.get_vertex(id).position)
			anchor += position
			var rails := GeometryTools.vertex_rails(poly,id)
			for other in rails: direction += (position-Vector3(poly.get_vertex(other).position)).normalized()
		else:
			var edge := poly.get_edge(id)
			anchor += (Vector3(poly.get_vertex(edge.vertex_a).position)+Vector3(poly.get_vertex(edge.vertex_b).position))*0.5
			for fid in edge.faces: direction += Vector3(poly.get_face(fid).normal)
	anchor /= ids.size()
	direction = direction.normalized()
	active = true
	poly.changed.connect(_external_change)
	preview()

func _external_change() -> void:
	if updating: return
	# Restore a delta only if it still belongs to the current revision.
	cancel()

func preview() -> void:
	updating = true
	# Revert silently; the recomputed preview below emits the change once.
	var reverted := false
	if delta: reverted = poly.apply_delta(delta,false,false)
	delta = null
	poly.select(mode,ids,false)
	if operation=="slide_vertex":
		var rails:=GeometryTools.vertex_rails(poly,ids[0])
		if not rails.is_empty(): direction=(Vector3(poly.get_vertex(rails[posmod(vertex_rail,rails.size())]).position)-Vector3(poly.get_vertex(ids[0]).position)).normalized()
	var clip: Dictionary = plugin.clip_options()
	var options := {"distance":width,"offset_even":offset_even} if operation=="extrude_normals" else {"amount":width,"individual":individual} if operation == "inset" else {"width":width,"segments":count}
	result = GeometryTools.slide_vertices(poly,ids,width,vertex_rail,clip) if operation=="slide_vertex" else GeometryTools.slide(poly,ids,width,clip) if operation=="slide_edge" else poly.execute(operation,ids,options)
	if operation=="slide_edge" and result.ok: result.new_edges=ids
	if operation=="slide_vertex" and result.ok: result.new_vertices=ids
	error = "" if result.ok else result.error
	if result.ok:
		delta = result.delta
		poly.select(mode,result[result_key],false)
	elif reverted: poly.emit_changed()
	poly.clear_history()
	updating = false
	plugin.panel.report(hint(),not error.is_empty())
	node.update_gizmos()
	plugin.update_overlays()

func hint() -> String:
	if not error.is_empty(): return error
	if operation=="extrude_normals": return "Extrude Along Normals: %.3f | Offset Even: %s" % [width,str(offset_even)]
	if operation=="slide_vertex": return "Slide Vertex: %.3f | Tab: next edge | Enter apply | Esc cancel" % width
	if operation=="slide_edge": return "Slide Edge: %.3f | drag handle; Enter apply; Esc cancel" % width
	var limit := " (max %.3f)" % max_width if max_width > 0 else ""
	if operation == "bevel_vertices": return "Vertex Bevel: %.3f%s | %d segments (wheel on handle)" % [width,limit,count]
	return "Inset: %.3f%s | %s (I to toggle)" % [width,limit,"Individual" if individual else "Region"] if operation == "inset" else "Bevel: %.3f%s | %d segments" % [width,limit,count]

func cancel() -> void:
	if not active: return
	updating = true
	if is_instance_valid(poly):
		if poly.changed.is_connected(_external_change): poly.changed.disconnect(_external_change)
		if delta: poly.apply_delta(delta,false)
		poly.select(mode,ids,false)
	delta = null
	active = false
	dragging = false
	updating = false
	if is_instance_valid(node): node.update_gizmos()
	if is_instance_valid(plugin): plugin.update_overlays()

# Size-aware amount: returns the suggested start value and stores the valid maximum.
func suggest(initial: bool) -> float:
	var suggestion: Dictionary = poly.suggest_amount(operation, ids, {"segments": count, "individual": individual})
	max_width = float(suggestion.max)
	return float(suggestion.value) if initial else (minf(width, max_width) if max_width > 0 else width)

func commit() -> void:
	if not delta:
		plugin.panel.report(error if not error.is_empty() else "Choose a valid offset",true)
		return
	var committed := delta
	var after: PackedInt64Array = result[result_key]
	delta = null
	poly.changed.disconnect(_external_change)
	active = false
	dragging = false
	plugin._record_delta(poly,committed,operation.capitalize(),ids,after)

func layout(camera: Camera3D) -> Dictionary:
	var world := node.global_transform * anchor
	if camera.is_position_behind(world): return {}
	var origin := camera.unproject_position(world)
	var depth := maxf(camera.near,-(camera.global_transform.affine_inverse()*world).z)
	var a := camera.project_position(origin,depth)
	var b := camera.project_position(origin+Vector2.RIGHT,depth)
	var unit := maxf(0.000001,(node.global_transform.basis.inverse()*(b-a)).length())
	var screen_direction := camera.unproject_position(world+node.global_transform.basis*direction)-origin
	if screen_direction.length() < 8: screen_direction = Vector2(1,-1)
	screen_direction = screen_direction.normalized()
	if dragging: screen_direction = drag_direction
	return {"origin":origin,"tip":origin+screen_direction*(56+clampf(width*100 if operation in ["slide_edge","slide_vertex"] else width/unit,-30,120)),"direction":screen_direction,"unit":unit}

func draw(control: Control, camera: Camera3D) -> void:
	var geometry := layout(camera)
	if geometry.is_empty(): return
	var scale := control.size / camera.get_viewport().get_visible_rect().size
	var origin: Vector2 = geometry.origin*scale
	var tip: Vector2 = geometry.tip*scale
	var color := Color(1,0.9,0.15)
	control.draw_line(origin,tip,Color(0,0,0,0.7),4,true)
	control.draw_line(origin,tip,color,2,true)
	control.draw_circle(tip,10,Color(0,0,0,0.75))
	control.draw_circle(tip,8,Color.WHITE if dragging else color)

func input(camera: Camera3D, event: InputEvent) -> bool:
	if event is InputEventKey:
		if event.pressed and not event.echo:
			if event.keycode == KEY_ESCAPE: cancel()
			elif event.keycode==KEY_TAB and operation=="slide_vertex": vertex_rail+=1; preview()
			elif event.keycode==KEY_I and operation=="inset":
				individual=not individual
				if auto_amount: width=suggest(false)
				preview()
			elif event.keycode==KEY_S and operation=="extrude_normals": offset_even=not offset_even; preview()
			elif event.keycode in [KEY_ENTER,KEY_KP_ENTER,KEY_SPACE]: commit()
		return true
	if event is InputEventMouseMotion:
		if not dragging: return false
		if not event.button_mask & MOUSE_BUTTON_MASK_LEFT:
			dragging = false
			plugin.update_overlays()
			return true
		var amount: float = initial_width+(event.position-mouse_start).dot(drag_direction)*units_per_pixel
		if event.ctrl_pressed: amount = snappedf(amount,0.1)
		if max_width > 0 and operation in ["bevel","bevel_vertices","inset"]: amount = minf(amount, max_width)
		var next_width := clampf(amount,0,0.999) if operation=="slide_vertex" else clampf(amount,-0.999,0.999) if operation=="slide_edge" else amount if operation=="extrude_normals" else maxf(0.00001,amount)
		if not is_equal_approx(width,next_width):
			width = next_width
			preview()
		return true
	if event is InputEventMouseButton:
		if event.alt_pressed or event.button_index == MOUSE_BUTTON_MIDDLE: return false
		if event.button_index == MOUSE_BUTTON_LEFT:
			if not event.pressed:
				dragging = false
				plugin.update_overlays()
			elif not dragging:
				var geometry := layout(camera)
				if not geometry.is_empty() and event.position.distance_to(geometry.tip) <= 14:
					dragging = true
					mouse_start = event.position
					initial_width = width
					units_per_pixel = 0.005 if operation in ["slide_edge","slide_vertex"] else geometry.unit
					drag_direction = geometry.direction
					plugin.update_overlays()
			return true
		if not event.pressed: return true
		match event.button_index:
			MOUSE_BUTTON_RIGHT:
				if dragging: cancel()
				else: return false
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
				if operation in ["inset","slide_edge","slide_vertex","extrude_normals"]: return dragging
				var geometry := layout(camera)
				if not dragging and (geometry.is_empty() or event.position.distance_to(geometry.tip) > 18): return false
				count = clampi(count+(1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1),1,32)
				preview()
		return true
	return false
