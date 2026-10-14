@tool
extends RefCounted
var plugin: EditorPlugin
var active:=false
var painting:=false
var target: MeshInstance3D
var camera: Camera3D
var mouse:=Vector2.ZERO
var original: Dictionary={}
var work: Dictionary={}
var points:=PackedVector3Array()
var colors:=PackedColorArray()
var weights:=PackedFloat32Array()
var triangles:=PackedVector3Array()
var surface_arrays: Array=[]
var surface_ranges: Array=[]
var changed:=false
var stroke_color:=Color.WHITE
var channel_mask: Array[bool]=[true,true,true,true]
const VISIBILITY_META := "modeling_show_vertex_colors"
var show_colors := true

static func paint_material(value: Material, visible_colors: bool=true) -> Material:
	if value is BaseMaterial3D:
		var copy: BaseMaterial3D=value.duplicate()
		copy.vertex_color_use_as_albedo=visible_colors
		if copy.next_pass: copy.next_pass=paint_material(copy.next_pass,visible_colors)
		return copy
	if value: return value # Custom shaders must consume COLOR themselves.
	var material:=StandardMaterial3D.new()
	material.vertex_color_use_as_albedo=visible_colors
	return material

static func state(node: MeshInstance3D) -> Dictionary:
	var overrides: Array=[]
	for i in node.get_surface_override_material_count(): overrides.append(node.get_surface_override_material(i))
	return {"resource":node.poly_mesh if node is EditableMesh else node.mesh,"override":node.material_override,"surfaces":overrides,"show_colors":node.get_meta(VISIBILITY_META) if node.has_meta(VISIBILITY_META) else null}

func sync_visibility(owner_plugin: EditorPlugin) -> void:
	var selected := owner_plugin.get_editor_interface().get_selection().get_selected_nodes()
	var valid := selected.size()==1 and selected[0] is MeshInstance3D and selected[0].mesh!=null
	owner_plugin.panel.paint_show_colors.disabled=not valid
	owner_plugin.panel.paint_show_colors.set_pressed_no_signal(bool(selected[0].get_meta(VISIBILITY_META,true)) if valid else true)

func set_visibility(owner_plugin: EditorPlugin, enabled: bool) -> void:
	plugin=owner_plugin
	var selected := plugin.get_editor_interface().get_selection().get_selected_nodes()
	if selected.size()!=1 or not selected[0] is MeshInstance3D or not selected[0].mesh:
		sync_visibility(plugin)
		return
	cancel_stroke()
	var node: MeshInstance3D=selected[0]
	for i in node.mesh.get_surface_count():
		var material := node.get_active_material(i)
		while material:
			if not material is BaseMaterial3D:
				plugin.panel.report("Vertex color visibility for custom shaders must be controlled by the shader.",true)
				sync_visibility(plugin)
				return
			material=material.next_pass
	var before := state(node)
	var after := before.duplicate()
	after.show_colors=enabled
	if node.material_override:
		after.override=paint_material(node.material_override,enabled)
	else:
		after.surfaces=[]
		for i in node.mesh.get_surface_count(): after.surfaces.append(paint_material(node.get_active_material(i),enabled))
	var undo := plugin.get_undo_redo()
	undo.create_action("Show vertex colors" if enabled else "Hide vertex colors",UndoRedo.MERGE_DISABLE,node)
	undo.add_do_method(self,"assign",node,after)
	undo.add_undo_method(self,"assign",node,before)
	undo.commit_action()

func assign(node: MeshInstance3D,value: Dictionary) -> void:
	if not is_instance_valid(node): return
	if node is EditableMesh:
		var tracked: bool=is_instance_valid(plugin) and plugin.target==node
		if tracked and node.poly_mesh:
			if node.poly_mesh.changed.is_connected(plugin._refresh): node.poly_mesh.changed.disconnect(plugin._refresh)
			if node.poly_mesh.selection_changed.is_connected(plugin._refresh): node.poly_mesh.selection_changed.disconnect(plugin._refresh)
		node.poly_mesh=value.resource
		if tracked:
			if not node.poly_mesh.changed.is_connected(plugin._refresh): node.poly_mesh.changed.connect(plugin._refresh)
			if not node.poly_mesh.selection_changed.is_connected(plugin._refresh): node.poly_mesh.selection_changed.connect(plugin._refresh)
	else: node.mesh=value.resource
	node.material_override=value.override
	for i in node.get_surface_override_material_count(): node.set_surface_override_material(i,value.surfaces[i] if i<value.surfaces.size() else null)
	if value.get("show_colors")!=null: node.set_meta(VISIBILITY_META,value.show_colors)
	elif node.has_meta(VISIBILITY_META): node.remove_meta(VISIBILITY_META)
	if is_instance_valid(plugin): sync_visibility(plugin)

func stop() -> void:
	cancel_stroke(); active=false
	if plugin:
		plugin.panel.paint_button.set_pressed_no_signal(false)
		plugin.update_overlays()

func start(owner_plugin: EditorPlugin) -> void:
	plugin=owner_plugin
	if active: stop(); return
	plugin.panel.paint_button.set_pressed_no_signal(false)
	var selected:=plugin.get_editor_interface().get_selection().get_selected_nodes()
	if selected.size()!=1 or not selected[0] is MeshInstance3D or not selected[0].mesh:
		plugin.panel.report("Select one MeshInstance3D or EditableMesh to paint",true); return
	target=selected[0]
	if target.skin or (target.mesh is ArrayMesh and target.mesh.get_blend_shape_count()>0):
		plugin.panel.report("Vertex Paint currently supports static meshes without skin or blend shapes",true); return
	plugin._set_polygon_editing(false)
	active=true; plugin.panel.paint_button.set_pressed_no_signal(true)
	plugin.panel.report("Vertex Paint: LMB paints, Shift paints white; Esc exits. Custom shaders must use COLOR.")

func begin_stroke(erase: bool=false) -> void:
	show_colors=bool(target.get_meta(VISIBILITY_META,true))
	stroke_color=Color.WHITE if erase else plugin.panel.paint_color.color
	for channel in 4: channel_mask[channel]=plugin.panel.paint_channels[channel].button_pressed
	original=state(target); work=original.duplicate()
	work.surfaces=[]
	for material in original.surfaces: work.surfaces.append(paint_material(material,show_colors) if material else null)
	work.override=paint_material(original.override,show_colors) if original.override else null
	points.clear(); colors.clear(); weights.clear(); surface_arrays.clear(); surface_ranges.clear()
	triangles=(target.get_base_mesh() if target is EditableMesh else target.mesh).get_faces()
	if target is EditableMesh:
		# Corners in face order; the stroke paints a private copy of the PolyMesh.
		points=target.poly_mesh.get_corner_positions()
		colors=target.poly_mesh.get_corner_colors()
		var poly: PolyMesh=target.poly_mesh.clone()
		var materials: Array=[]
		for material in target.poly_mesh.materials: materials.append(paint_material(material,show_colors))
		if materials.is_empty(): materials.append(paint_material(null,show_colors))
		poly.materials=materials; work.resource=poly
	else:
		for surface in target.mesh.get_surface_count():
			var arrays:=target.mesh.surface_get_arrays(surface).duplicate(true)
			var vertices: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
			var existing: PackedColorArray=arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR]!=null else PackedColorArray()
			if existing.size()!=vertices.size(): existing.resize(vertices.size()); existing.fill(Color.WHITE)
			arrays[Mesh.ARRAY_COLOR]=existing
			surface_ranges.append(Vector2i(points.size(),vertices.size()))
			for i in vertices.size(): points.append(vertices[i]); colors.append(existing[i])
			surface_arrays.append(arrays)
	weights.resize(points.size()); weights.fill(0.0)
	painting=true; changed=false

func dab(erase: bool,fill: bool=false) -> void:
	if not true in channel_mask: return
	# Accumulated coverage is independent of mouse-event frequency.
	weights=ModelingKernels.paint_weights(points,target.global_transform,camera,mouse,plugin.panel.paint_radius.value,plugin.panel.paint_strength.value,fill,plugin.panel.paint_through.button_pressed,triangles,weights)
	for weight in weights:
		if weight>0: changed=true; break
	if not changed: return
	var output:=ModelingKernels.blend_colors(colors,stroke_color,weights,channel_mask)
	if target is EditableMesh:
		work.resource.set_corner_colors(output)
	else:
		var mesh:=ArrayMesh.new()
		for surface in surface_arrays.size():
			var arrays: Array=surface_arrays[surface].duplicate(true)
			var span: Vector2i=surface_ranges[surface]
			arrays[Mesh.ARRAY_COLOR]=output.slice(span.x,span.x+span.y)
			mesh.add_surface_from_arrays(original.resource.surface_get_primitive_type(surface) if original.resource is ArrayMesh else Mesh.PRIMITIVE_TRIANGLES,arrays)
			mesh.surface_set_material(surface,paint_material(original.resource.surface_get_material(surface),show_colors))
			if original.resource is ArrayMesh: mesh.surface_set_name(surface,original.resource.surface_get_name(surface))
		work.resource=mesh
	assign(target,work)

func finish() -> void:
	if not painting: return
	painting=false
	if changed:
		var undo:=plugin.get_undo_redo()
		undo.create_action("Vertex Paint",UndoRedo.MERGE_DISABLE,target)
		undo.add_do_method(self,"assign",target,work.duplicate())
		undo.add_undo_method(self,"assign",target,original.duplicate())
		undo.commit_action(false)
	original={}; work={}
	plugin._selection_changed()

func cancel_stroke() -> void:
	if painting and is_instance_valid(target): assign(target,original)
	painting=false; original={}; work={}

func input(view: Camera3D,event: InputEvent) -> bool:
	if not active: return false
	if not is_instance_valid(target) or not target.is_inside_tree(): stop(); return false
	camera=view
	if event is InputEventKey and event.pressed and event.keycode==KEY_ESCAPE: stop(); return true
	if event is InputEventMouse:
		mouse=event.position; plugin.update_overlays()
		if event.alt_pressed: return false
		if event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_LEFT:
			if event.pressed: begin_stroke(event.shift_pressed); dab(event.shift_pressed)
			else: finish()
			return true
		if event is InputEventMouseMotion and painting:
			if not event.button_mask & MOUSE_BUTTON_MASK_LEFT: finish()
			else: dab(event.shift_pressed)
			return true
	return false

func draw(control: Control,view: Camera3D) -> void:
	if active and view and camera==view:
		var ratio:=control.size/view.get_viewport().get_visible_rect().size
		control.draw_arc(mouse*ratio,plugin.panel.paint_radius.value*ratio.x,0,TAU,64,plugin.panel.paint_color.color,2,true)

static func blend_channels(before: Color, after: Color, weight: float, mask: Array) -> Color:
	var result:=before
	for channel in 4:
		if mask[channel]: result[channel]=lerpf(before[channel],after[channel],weight)
	return result
