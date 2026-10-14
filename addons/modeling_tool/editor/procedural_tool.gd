@tool
extends RefCounted
var plugin: EditorPlugin
var kind := ""
var primitive := false
var node: EditableMesh
var original: PolyMesh
var preview: PolyMesh
var controls: VBoxContainer
var fields := {}
var valid := false
var queued := false
# Extrude Along Path preview.
const PathTools = preload("res://addons/modeling_tool/editor/path_tools.gd")
var path_node: Path3D
var sweep_mode := "face"
var sweep_ids := PackedInt64Array()
var align_check: CheckBox
var path_label: Label
# Active size handle drag (see shape_handles()).
var size_key := ""
var size_initial := 0.0
var size_factor := 1.0
var size_anchor := Vector3.ZERO
var size_axis_world := Vector3.ZERO
var size_start := 0.0
const RADIUS_COLOR := Color("ff9f43")
const AXIS_COLORS := [Color("ff6557"),Color("76df69"),Color("65aaff")]

func cancel() -> void:
	if kind=="": return
	kind=""
	size_key=""
	if plugin: plugin.update_overlays()
	if is_instance_valid(node):
		if primitive: node.queue_free()
		elif original: plugin.workflow.assign_poly(node,original)
	if is_instance_valid(controls): controls.queue_free()
	controls=null; fields.clear(); node=null; original=null; preview=null; path_node=null

func start(value: String,is_primitive: bool) -> void:
	cancel()
	plugin.workflow.cancel(); plugin.offset_tool.cancel(); plugin.cut_tool.cancel(); plugin.gizmo_plugin.cancel_drag()
	var root: Node=plugin.get_editor_interface().get_edited_scene_root()
	if not root: return
	primitive=is_primitive
	if primitive:
		node=EditableMesh.new()
		node.name="PrimitivePreview"
		root.add_child(node,false,Node.INTERNAL_MODE_BACK)
	else: return
	kind=value
	controls=VBoxContainer.new()
	plugin.panel.sections["Create"].add_child(controls)
	plugin.panel.section_buttons["Create"].button_pressed = true
	plugin.panel.hint(controls,kind.capitalize()+" preview — Enter: apply / Esc: cancel")
	if primitive:
		# Each shape exposes its own parameters; the viewport handles match them.
		if kind in ["cylinder","sphere"]: field("Sides",24,3,128,1)
		if kind=="sphere": field("Rings",12,3,64,1)
		field("Subdivisions",0,0,3,1)
		if kind in ["cylinder","sphere"]: field("Radius",1,0.001,10000,0.1)
		else:
			field("Width",2,0.001,10000,0.1)
			field("Depth",2,0.001,10000,0.1)
		if kind not in ["plane","sphere"]: field("Height",2,0.001,10000,0.1)
	var row:=HBoxContainer.new(); controls.add_child(row)
	plugin.panel.button(row,"Apply",apply).tooltip_text="Apply (Enter)"
	plugin.panel.button(row,"Cancel",cancel).tooltip_text="Cancel (Esc)"
	rebuild()

func start_path(path: Path3D) -> void:
	cancel()
	plugin.workflow.cancel(); plugin.offset_tool.cancel(); plugin.cut_tool.cancel(); plugin.gizmo_plugin.cancel_drag()
	var target: EditableMesh=plugin.target
	if not is_instance_valid(target) or not target.poly_mesh: return
	sweep_mode=plugin.panel.mode
	sweep_ids=target.poly_mesh.get_selected_edges() if sweep_mode=="edge" else target.poly_mesh.get_selected_faces()
	if sweep_ids.is_empty(): return
	primitive=false
	node=target
	original=target.poly_mesh
	path_node=path
	kind="extrude_path"
	controls=VBoxContainer.new()
	var edit: Control=plugin.panel.sections["Edit"]
	edit.add_child(controls)
	edit.move_child(controls,0)
	plugin.panel.section_buttons["Edit"].button_pressed = true
	plugin.panel.hint(controls,"Extrude Along Path — Enter: apply / Esc: cancel")
	var row:=HBoxContainer.new(); controls.add_child(row)
	path_label=Label.new(); path_label.size_flags_horizontal=Control.SIZE_EXPAND_FILL; path_label.clip_text=true
	path_label.text="Path: "+str(path.name)
	row.add_child(path_label)
	plugin.panel.button(row,"Pick Path…",func(): plugin._pick_extrude_path_again()).tooltip_text="Use another Path3D"
	field("Segments",16,1,1024,1)
	fields.Segments.tooltip_text="Even steps along the path; the path's own points are always added, so polyline corners stay sharp."
	field("Twist",0,-36000,36000,1)
	fields.Twist.suffix="°"
	field("Taper",1,0,100,0.01)
	fields.Taper.tooltip_text="Scale of the end section (1 keeps the size)."
	align_check=CheckBox.new(); align_check.text="On"; align_check.button_pressed=true
	align_check.tooltip_text="Start the path at the selection and turn it to the selection's normal. Off: the section travels the path where it lies in the scene."
	align_check.toggled.connect(func(_on): schedule())
	plugin.panel.property(controls,"Align to Selection",align_check)
	var buttons:=HBoxContainer.new(); controls.add_child(buttons)
	plugin.panel.button(buttons,"Apply",apply).tooltip_text="Apply (Enter)"
	plugin.panel.button(buttons,"Cancel",cancel).tooltip_text="Cancel (Esc)"
	rebuild()

func set_path(path: Path3D) -> void:
	if kind!="extrude_path": return
	path_node=path
	path_label.text="Path: "+str(path.name)
	schedule()

func rebuild_path() -> void:
	if not is_instance_valid(path_node) or not is_instance_valid(original):
		plugin.panel.report("The path is gone",true); return
	var points:=PathTools.sample(path_node,node,int(fields.Segments.value))
	var candidate:=original.clone()
	var result:=candidate.execute("extrude_path",sweep_ids,{"points":points,"edges":sweep_mode=="edge","align":align_check.button_pressed,"twist":fields.Twist.value,"taper":fields.Taper.value})
	if not result.ok:
		plugin.workflow.assign_poly(node,original)
		plugin.panel.report(result.error,true)
		return
	candidate.select("edge" if sweep_mode=="edge" else "face",result.new_edges if sweep_mode=="edge" else result.new_faces)
	preview=candidate
	plugin.workflow.assign_poly(node,preview)
	valid=true
	plugin.panel.report("Extrude Along Path preview: %d rings. Enter applies; Esc cancels." % maxi(points.size()-1,0))

func field(label: String,value: float,low: float,high: float,step: float) -> void:
	var spin: SpinBox=plugin.panel.property_spin(controls,label,low,high,step,value)
	fields[label]=spin
	spin.value_changed.connect(func(_value): schedule())

func schedule() -> void:
	if queued: return
	queued=true
	rebuild.call_deferred()

func rebuild() -> void:
	queued=false
	if kind=="" or not is_instance_valid(node): return
	valid=false
	if kind=="extrude_path":
		rebuild_path()
		return
	if primitive:
		preview=make_primitive(kind,int(fields.get("Sides").value) if fields.has("Sides") else 24,int(fields.get("Rings").value) if fields.has("Rings") else 12,int(fields.Subdivisions.value))
		if not preview: return
		if kind=="sphere":
			preview.transform_vertices(preview.get_vertex_ids(),Transform3D(Basis.from_scale(Vector3.ONE*fields.Radius.value),Vector3.ZERO))
			preview.clear_history()
		elif kind=="cylinder":
			# The base cylinder has radius 1 and height 2.
			preview.transform_vertices(preview.get_vertex_ids(),Transform3D(Basis.from_scale(Vector3(fields.Radius.value,fields.Height.value*0.5,fields.Radius.value)),Vector3.ZERO))
			preview.clear_history()
		else: resize_primitive(preview,Vector3(fields.Width.value,fields.Height.value if fields.has("Height") else 0,fields.Depth.value))
		node.poly_mesh=preview
	valid=true
	plugin.update_overlays()
	plugin.panel.report("%s preview: %d polygons. Enter applies; Esc cancels." % [kind.capitalize(),preview.get_face_ids().size()])

func apply() -> void:
	if kind=="": return
	for spin in fields.values():
		if spin.get_line_edit().has_focus(): spin.apply()
	rebuild()
	if not valid: return
	if kind=="extrude_path":
		var target:=node; var before:=original; var after:=preview
		original=null
		cancel()
		var undo:=plugin.get_undo_redo()
		undo.create_action("Modeling: Extrude Along Path",UndoRedo.MERGE_DISABLE,target)
		undo.add_do_method(plugin.workflow,"assign_poly",target,after)
		undo.add_undo_method(plugin.workflow,"assign_poly",target,before)
		undo.commit_action()
		plugin.panel.report("Extrude Along Path applied")
		return
	var output:=preview
	var label:=kind.capitalize()
	cancel()
	plugin._add_mesh(output,null,label)
	plugin.panel.report(label+" applied")

static func make_primitive(value: String,sides: int,rings: int,subdivisions: int) -> PolyMesh:
	var poly: PolyMesh
	if value=="cylinder": poly=EditableMesh.make_cylinder(1,2,sides)
	elif value=="sphere": poly=EditableMesh.make_sphere(1,sides,rings)
	else: poly=EditableMesh.make_primitive(value)
	if not poly: return null
	for iteration in subdivisions:
		var result:=poly.execute("subdivide",poly.get_face_ids(),{})
		if not result.ok: return null
	poly.clear_history()
	return poly

static func deform(source: PolyMesh,kind: String,axis: int,amount: float,low: float=0,high: float=1) -> Dictionary:
	var poly:=source.clone()
	var result:=poly.execute("deform",PackedInt64Array(),{"kind":kind,"axis":axis,"amount":amount,"low":low,"high":high})
	if not result.ok: return result
	poly.clear_history()
	return {"ok":true,"poly":poly}

static func resize_primitive(poly: PolyMesh, dimensions: Vector3) -> void:
	var low:=Vector3(INF,INF,INF); var high:=-low
	for id in poly.get_vertex_ids():
		var p: Vector3=poly.get_vertex(id).position
		low=low.min(p); high=high.max(p)
	var scale:=Vector3.ONE
	for axis_index in 3:
		if high[axis_index]-low[axis_index]>0.000001: scale[axis_index]=dimensions[axis_index]/(high[axis_index]-low[axis_index])
	poly.transform_vertices(poly.get_vertex_ids(),Transform3D(Basis.from_scale(scale),Vector3.ZERO))
	poly.clear_history()

func shape_handles() -> Array:
	# Handles in mesh space: value = factor × distance from anchor along axis.
	# The mesh is sized around its center, so "drag" converts cursor travel to value.
	if kind=="sphere": return [{"key":"Radius","axis":0,"anchor":Vector3.ZERO,"factor":1.0}]
	if kind=="cylinder": return [{"key":"Radius","axis":0,"anchor":Vector3.ZERO,"factor":1.0},{"key":"Height","axis":1,"anchor":Vector3.ZERO,"factor":2.0}]
	if kind=="pyramid":
		# Base size from the base center; height up to the apex.
		var base := Vector3(0,-fields.Height.value*0.5,0)
		return [{"key":"Width","axis":0,"anchor":base,"factor":2.0},{"key":"Height","axis":1,"anchor":base,"factor":1.0,"drag":2.0},{"key":"Depth","axis":2,"anchor":base,"factor":2.0}]
	var result: Array=[]
	for index in 3:
		var key: String=["Width","Height","Depth"][index]
		if fields.has(key): result.append({"key":key,"axis":index,"anchor":Vector3.ZERO,"factor":2.0})
	return result

func size_handles(camera: Camera3D) -> Array:
	var handles: Array=[]
	if kind=="" or not primitive or not is_instance_valid(node) or not camera: return handles
	var world := node.global_transform
	for definition in shape_handles():
		var direction := Vector3.ZERO
		direction[definition.axis]=1
		var anchor: Vector3=world*Vector3(definition.anchor)
		var end: Vector3=world*(Vector3(definition.anchor)+direction*fields[definition.key].value/definition.factor)
		if camera.is_position_behind(anchor) or camera.is_position_behind(end): continue
		var origin:=camera.unproject_position(anchor)
		var projection:=camera.unproject_position(end)-origin
		if projection.length()<5: continue
		# Keep tiny shapes grabbable; dragging uses the 3D axis, not this offset.
		var tip:=origin+projection.normalized()*maxf(40,projection.length())
		handles.append({"key":definition.key,"axis":definition.axis,"origin":origin,"tip":tip,"direction":projection.normalized(),
			"anchor":anchor,"axis_world":world.basis*direction,"factor":definition.get("drag",definition.factor)})
	return handles

func axis_parameter(camera: Camera3D,mouse: Vector2,anchor: Vector3,axis_world: Vector3) -> float:
	var ray_origin:=camera.project_ray_origin(mouse)
	var ray_end:=ray_origin+camera.project_ray_normal(mouse)*10000
	var closest:=Geometry3D.get_closest_points_between_segments(anchor-axis_world*10000,anchor+axis_world*10000,ray_origin,ray_end)
	return (closest[0]-anchor).dot(axis_world)/axis_world.length_squared()

func draw(control: Control,camera: Camera3D) -> void:
	if not camera or kind=="" or not primitive or not is_instance_valid(node): return
	var ratio:=control.size/camera.get_viewport().get_visible_rect().size
	# Radius guides: cylinder caps and the sphere equator.
	if fields.has("Radius"):
		var levels: Array=[0.0] if kind=="sphere" else [-fields.Height.value*0.5,fields.Height.value*0.5]
		for level in levels: draw_circle_3d(control,camera,ratio,fields.Radius.value,level,RADIUS_COLOR*Color(1,1,1,0.8))
	for handle in size_handles(camera):
		var color: Color=RADIUS_COLOR if handle.key=="Radius" else AXIS_COLORS[handle.axis]
		control.draw_line(handle.origin*ratio,handle.tip*ratio,color,2,true)
		control.draw_circle(handle.tip*ratio,7,Color.WHITE if size_key==handle.key else color)

func draw_circle_3d(control: Control,camera: Camera3D,ratio: Vector2,radius: float,height: float,color: Color) -> void:
	var points:=PackedVector2Array()
	for segment in 65:
		var angle:=TAU*segment/64.0
		var point:=node.global_transform*Vector3(cos(angle)*radius,height,sin(angle)*radius)
		if camera.is_position_behind(point): return
		points.append(camera.unproject_position(point)*ratio)
	control.draw_polyline(points,color,1.5,true)

func input(camera: Camera3D,event: InputEvent) -> bool:
	if kind=="" or not primitive: return false
	if event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_LEFT and not event.alt_pressed:
		if not event.pressed: size_key=""; return true
		var closest:=14.0
		for handle in size_handles(camera):
			var distance: float=event.position.distance_to(handle.tip)
			if distance<closest:
				closest=distance; size_key=handle.key; size_factor=handle.factor
				size_anchor=handle.anchor; size_axis_world=handle.axis_world
				size_initial=fields[size_key].value
				size_start=axis_parameter(camera,event.position,size_anchor,size_axis_world)
		return true
	if event is InputEventMouseMotion and size_key!="":
		if not event.button_mask & MOUSE_BUTTON_MASK_LEFT: size_key=""; return true
		var value:=maxf(0.001,size_initial+size_factor*(axis_parameter(camera,event.position,size_anchor,size_axis_world)-size_start))
		if event.ctrl_pressed: value=maxf(0.001,snappedf(value,0.1))
		fields[size_key].value=value
		return true
	return false
