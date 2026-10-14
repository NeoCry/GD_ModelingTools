@tool
extends EditorPlugin
const ModelingPanel = preload("res://addons/modeling_tool/editor/panel.gd")
const Selection = preload("res://addons/modeling_tool/editor/selection.gd")
const PathTools = preload("res://addons/modeling_tool/editor/path_tools.gd")
const Actions = preload("res://addons/modeling_tool/editor/actions.gd")
const SelectionGizmo = preload("res://addons/modeling_tool/editor/gizmo.gd")
const Topology = preload("res://addons/modeling_tool/editor/topology_tools.gd")
const CutTool = preload("res://addons/modeling_tool/editor/cut_tool.gd")
var cut_tool = CutTool.new()
var vertex_paint=preload("res://addons/modeling_tool/editor/vertex_paint.gd").new()
var work_grid=preload("res://addons/modeling_tool/editor/work_grid.gd").new()
# Mirror planes are drawn with a second working grid; centers are kept per
# object (local space) for this editor session.
var symmetry_grid=preload("res://addons/modeling_tool/editor/work_grid.gd").new()
var modifier_window: Window
const OffsetTool = preload("res://addons/modeling_tool/editor/offset_tool.gd")
var offset_tool = OffsetTool.new()
var origin_gizmo_controller: Node
var gizmo_plugin: EditorNode3DGizmoPlugin
var lattice_gizmo: EditorNode3DGizmoPlugin
var decal_gizmo: EditorNode3DGizmoPlugin
var decal_window: Window
# Status messages are shown in the 3D viewport (top left, with the tool hints)
# and the selected object's statistics at its bottom left.
var status_message := ""
var status_error := false
var status_until := 0
var stats_lines := PackedStringArray()
var panel: VBoxContainer
var dock: ScrollContainer
var target: EditableMesh
var overlay: MeshInstance3D
var hover_overlay: MeshInstance3D
var hover_id := -1
var hover_viewport_control: Control
var dialog: EditorFileDialog
var save_export := false
var edit_polygons := true
var edit_button: Button
var transform_mode := "move"
var transform_toolbar: HBoxContainer
var transform_buttons := {}
var top_toolbar: VBoxContainer
const Snapping = preload("res://addons/modeling_tool/editor/snapping.gd")
var snapping = Snapping.new()
var object_snap = preload("res://addons/modeling_tool/editor/object_snap.gd").new()
var selection_menu: Button
var selection_popup: PopupPanel
var selection_commands: Array[Button] = []
var snap_menu: MenuButton
var tool_popups := {}
var snap_preview_time := 0
var grid_division := 1
var uv_busy := false
var uv_window: Window
var optcuts_tool = preload("res://addons/modeling_tool/editor/optcuts_tool.gd").new()
var dock_active_tool := ""
var procedural = preload("res://addons/modeling_tool/editor/procedural_tool.gd").new()
var workflow = preload("res://addons/modeling_tool/editor/modeling_workflow.gd").new()

func _enter_tree() -> void:
	object_snap.plugin = self
	procedural.plugin = self
	workflow.plugin = self
	process_priority = 100
	dock = ScrollContainer.new()
	dock.name = "Modeling"
	dock.custom_minimum_size.x = 350
	dock.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var dock_margin := MarginContainer.new()
	dock_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left","right","top","bottom"]: dock_margin.add_theme_constant_override("margin_"+side,4)
	dock.add_child(dock_margin)
	panel = ModelingPanel.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dock_margin.add_child(panel)
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, dock)
	panel.operation.connect(_operation)
	panel.command.connect(_command)
	panel.reported.connect(_show_status)
	panel.status.visible = false
	panel.brush_radius.value_changed.connect(func(value): workflow.radius=value)
	panel.mode_activated.connect(_activate_selection_editing)
	panel.mode_changed.connect(func(_mode): procedural.cancel(); workflow.cancel(); offset_tool.cancel(); cut_tool.cancel(); _refresh())
	get_editor_interface().get_selection().selection_changed.connect(_selection_changed)
	dialog = EditorFileDialog.new()
	dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	dialog.access = EditorFileDialog.ACCESS_RESOURCES
	dialog.add_filter("*.tres", "Godot resource")
	dialog.file_selected.connect(_save)
	dock.add_child(dialog)
	set_input_event_forwarding_always_enabled()
	set_force_draw_over_forwarding_enabled()
	gizmo_plugin = SelectionGizmo.new()
	gizmo_plugin.editor_plugin = self
	add_node_3d_gizmo_plugin(gizmo_plugin)
	lattice_gizmo = preload("res://addons/modeling_tool/editor/lattice_gizmo.gd").new()
	lattice_gizmo.editor_plugin = self
	add_node_3d_gizmo_plugin(lattice_gizmo)
	decal_gizmo = preload("res://addons/modeling_tool/editor/decal_gizmo.gd").new()
	add_node_3d_gizmo_plugin(decal_gizmo)
	edit_button = Button.new()
	edit_button.text = "Edit Mesh"
	edit_button.theme_type_variation = "FlatButton"
	edit_button.icon = _editor_icon("Edit")
	edit_button.tooltip_text = "Toggle polygon editing (Tab). Turn off to select and move whole objects with standard Godot tools."
	edit_button.toggle_mode = true
	edit_button.button_pressed = edit_polygons
	edit_button.toggled.connect(_set_polygon_editing)
	transform_toolbar = HBoxContainer.new()
	transform_toolbar.add_child(VSeparator.new())
	var group := ButtonGroup.new()
	for tool in ["move", "rotate", "scale"]:
		var button := Button.new()
		button.theme_type_variation = "FlatButton"
		button.icon = _editor_icon({"move": "ToolMove", "rotate": "ToolRotate", "scale": "ToolScale"}[tool])
		if button.icon == null: button.text = tool.capitalize()
		button.tooltip_text = {"move": "Move (W)", "rotate": "Rotate (R)", "scale": "Scale (S)"}[tool] + "\nTransform selected mesh elements around their center in local axes. Ctrl snaps."
		button.focus_mode = Control.FOCUS_NONE
		button.toggle_mode = true
		button.button_group = group
		button.button_pressed = tool == transform_mode
		button.pressed.connect(_set_transform_mode.bind(tool))
		transform_toolbar.add_child(button)
		transform_buttons[tool] = button
	_create_top_toolbar()
	if "--test-modeling-editor" in OS.get_cmdline_user_args():
		_run_integration_test.call_deferred()

func _run_integration_test() -> void:
	var runner = load("res://tests/test_editor.gd").new()
	await runner.run(self)

func _exit_tree() -> void:
	object_snap.clear()
	vertex_paint.stop()
	procedural.cancel()
	if is_instance_valid(uv_window): uv_window.canvas.bind_mesh(null); uv_window.queue_free()
	if is_instance_valid(modifier_window): modifier_window.queue_free()
	if is_instance_valid(decal_window): decal_window.queue_free()
	optcuts_tool.cancel()
	offset_tool.cancel()
	edit_polygons = false
	_sync_origin_gizmo()
	if is_instance_valid(hover_viewport_control) and hover_viewport_control.mouse_exited.is_connected(_clear_hover):
		hover_viewport_control.mouse_exited.disconnect(_clear_hover)
	gizmo_plugin.cancel_drag()
	remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, top_toolbar)
	top_toolbar.queue_free()
	remove_node_3d_gizmo_plugin(gizmo_plugin)
	gizmo_plugin.editor_plugin = null
	remove_node_3d_gizmo_plugin(lattice_gizmo)
	lattice_gizmo.editor_plugin = null
	remove_node_3d_gizmo_plugin(decal_gizmo)
	_disconnect_target()
	if is_instance_valid(overlay): overlay.queue_free()
	if is_instance_valid(hover_overlay): hover_overlay.queue_free()
	get_editor_interface().get_selection().selection_changed.disconnect(_selection_changed)
	remove_control_from_docks(dock)
	dock.queue_free()

func _handles(object: Object) -> bool:
	return object is MeshInstance3D

func _set_polygon_editing(enabled: bool) -> void:
	object_snap.clear()
	if not enabled:
		workflow.cancel()
		offset_tool.cancel()
		cut_tool.cancel()
		gizmo_plugin.cancel_drag()
	edit_polygons = enabled
	if is_instance_valid(target):
		target.set_modeling_transform_lock(enabled)
		target.set_modifier_editing(enabled)
	_sync_origin_gizmo()
	edit_button.set_pressed_no_signal(enabled)
	panel.report("Polygon editing: click faces, edges or vertices" if enabled else "Object mode: use standard Godot selection and transform tools")
	_refresh()

func _disconnect_target() -> void:
	object_snap.clear()
	if is_instance_valid(target):
		target.set_modeling_transform_lock(false)
		target.set_modifier_editing(false)
	procedural.cancel()
	workflow.cancel()
	if uv_busy: optcuts_tool.cancel()
	offset_tool.cancel()
	cut_tool.cancel()
	_clear_hover()
	if is_instance_valid(gizmo_plugin): gizmo_plugin.cancel_drag()
	if is_instance_valid(target) and target.modifiers_evaluated.is_connected(_stats_changed): target.modifiers_evaluated.disconnect(_stats_changed)
	if is_instance_valid(target) and target.poly_mesh:
		if target.poly_mesh.changed.is_connected(_refresh): target.poly_mesh.changed.disconnect(_refresh)
		if target.poly_mesh.selection_changed.is_connected(_refresh): target.poly_mesh.selection_changed.disconnect(_refresh)
	target = null
	_sync_origin_gizmo()

func _selection_changed() -> void:
	vertex_paint.sync_visibility(self)
	if vertex_paint.active:
		var paint_selection:=get_editor_interface().get_selection().get_selected_nodes()
		if paint_selection.size()!=1 or paint_selection[0]!=vertex_paint.target: vertex_paint.stop()
	_disconnect_target()
	if is_instance_valid(overlay):
		overlay.queue_free()
		overlay = null
	if is_instance_valid(hover_overlay):
		hover_overlay.queue_free()
		hover_overlay = null
	var nodes := get_editor_interface().get_selection().get_selected_nodes()
	if nodes.size() == 1 and nodes[0] is EditableMesh:
		target = nodes[0]
		target.set_modeling_transform_lock(edit_polygons)
		if not target.modifiers_evaluated.is_connected(_stats_changed): target.modifiers_evaluated.connect(_stats_changed)
		if target.poly_mesh:
			target.poly_mesh.changed.connect(_refresh)
			target.poly_mesh.selection_changed.connect(_refresh)
			overlay = MeshInstance3D.new()
			overlay.name = "_ModelingOverlay"
			overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			target.add_child(overlay, false, Node.INTERNAL_MODE_BACK)
			hover_overlay = MeshInstance3D.new()
			hover_overlay.name = "_ModelingHover"
			hover_overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			hover_overlay.extra_cull_margin = 0.1
			target.add_child(hover_overlay, false, Node.INTERNAL_MODE_BACK)
	if is_instance_valid(target): target.set_modifier_editing(edit_polygons)
	# The stack window always shows the selected object (empty for anything else).
	if is_instance_valid(modifier_window) and modifier_window.visible: modifier_window.bind(target if is_instance_valid(target) else null)
	if is_instance_valid(decal_window) and decal_window.visible: decal_window.bind(_selected_decal())
	_refresh()

# The stack was evaluated again: its triangle count may have changed.
func _stats_changed() -> void:
	_update_stats()
	update_overlays()

func _show_status(message: String, error: bool) -> void:
	status_message = message
	status_error = error
	var seconds := 6.0 if error else 3.5
	status_until = Time.get_ticks_msec() + int(seconds * 1000)
	update_overlays()
	if is_inside_tree(): get_tree().create_timer(seconds + 0.05).timeout.connect(update_overlays)

# Polygons, edges, vertices and triangles of the selected object(s).
func _update_stats() -> void:
	stats_lines = PackedStringArray()
	var nodes := get_editor_interface().get_selection().get_selected_nodes() if is_inside_tree() else []
	if is_instance_valid(target) and target.poly_mesh:
		var counts := target.poly_mesh.get_statistics()
		var line := "%s   %s polygons · %s edges · %s vertices · %s triangles" % [target.name, _count(counts.faces), _count(counts.edges), _count(counts.vertices), _count(_triangles(target.mesh))]
		if target.has_active_modifiers(): line += " (with modifiers)"
		stats_lines.append(line)
		if edit_polygons:
			var selected := Selection.selected_ids(target.poly_mesh, panel.mode).size()
			var names: Array = {"vertex": ["vertex", "vertices"], "edge": ["edge", "edges"], "face": ["polygon", "polygons"]}.get(panel.mode, [panel.mode, panel.mode])
			stats_lines.append("Selected: %s %s" % [_count(selected), names[0] if selected == 1 else names[1]])
		return
	var meshes := nodes.filter(func(node): return node is MeshInstance3D and node.mesh)
	if meshes.size() == 1:
		stats_lines.append("%s   %s triangles · %s vertices" % [meshes[0].name, _count(_triangles(meshes[0].mesh)), _count(_vertices(meshes[0].mesh))])
	elif meshes.size() > 1:
		var triangles := 0
		for node in meshes: triangles += _triangles(node.mesh)
		stats_lines.append("%d objects   %s triangles" % [meshes.size(), _count(triangles)])

func _triangles(mesh: Mesh) -> int:
	if not mesh: return 0
	var array := mesh as ArrayMesh
	if not array: return mesh.get_faces().size() / 3
	var total := 0
	for surface in array.get_surface_count():
		var indices := array.surface_get_array_index_len(surface)
		total += (indices if indices > 0 else array.surface_get_array_len(surface)) / 3
	return total

func _vertices(mesh: Mesh) -> int:
	var array := mesh as ArrayMesh
	if not array: return mesh.get_faces().size()
	var total := 0
	for surface in array.get_surface_count(): total += array.surface_get_array_len(surface)
	return total

func _count(value: int) -> String:
	# 12345 -> "12 345"
	var text := str(value)
	var grouped := ""
	while text.length() > 3:
		grouped = " " + text.substr(text.length() - 3) + grouped
		text = text.substr(0, text.length() - 3)
	return text + grouped

func _tool_hint_lines() -> PackedStringArray:
	if offset_tool.active:
		return PackedStringArray([offset_tool.hint(),"Drag yellow handle: normal offset | S: Offset Even" if offset_tool.operation=="extrude_normals" else "Drag yellow handle: slide along rails" if offset_tool.operation in ["slide_edge","slide_vertex"] else "Drag yellow handle: inset distance" if offset_tool.operation == "inset" else "Drag yellow handle: width | Wheel over handle: segments","Enter: apply | Esc: cancel | Ctrl while dragging: snap"])
	if cut_tool.kind == "split_edge":
		return PackedStringArray(["SPLIT EDGE", "Hover: position | Ctrl: 10% steps | Click / Enter: split | Esc: cancel"])
	if cut_tool.kind == "loop_cut":
		return PackedStringArray(["LOOP CUT - %d cut(s)" % cut_tool.count,
			"Move: slide | Ctrl: snap | Click / Enter: apply" if cut_tool.sliding else "Hover an edge | Wheel: cut count | Click: start slide",
			"RMB: centered cut | Esc: cancel" if cut_tool.sliding else "RMB / Esc: cancel"])
	if cut_tool.kind != "":
		return PackedStringArray(["KNIFE - %d segment(s)" % cut_tool.segments.size(),
			"Click a path: start and finish on an edge or vertex",
			"Enter / Space: apply | RMB: new path | Esc: cancel"])
	return PackedStringArray()

# Tool hints (top left), the latest status message with them, and statistics (bottom left).
func _draw_info(control: Control) -> void:
	var font := control.get_theme_default_font()
	var hints := _tool_hint_lines()
	var y := 48.0
	if not hints.is_empty():
		var width := 0.0
		for line in hints: width = maxf(width,font.get_string_size(line,HORIZONTAL_ALIGNMENT_LEFT,-1,15).x)
		control.draw_rect(Rect2(16,y,width+24,78),Color(0.04,0.05,0.07,0.9))
		for i in hints.size(): control.draw_string(font,Vector2(28,y+22+i*22),hints[i],HORIZONTAL_ALIGNMENT_LEFT,-1,15,Color.YELLOW if i == 0 else Color.WHITE)
		y += 84
	if status_message != "" and Time.get_ticks_msec() < status_until and not hints.has(status_message):
		var size := font.get_string_size(status_message,HORIZONTAL_ALIGNMENT_LEFT,-1,14)
		var width := minf(size.x, control.size.x - 64)
		control.draw_rect(Rect2(16,y,width+24,28),Color(0.04,0.05,0.07,0.85))
		control.draw_string(font,Vector2(28,y+19),status_message,HORIZONTAL_ALIGNMENT_LEFT,width,14,Color("ff8f85") if status_error else Color("b7e4c7"))
	if not stats_lines.is_empty():
		var width := 0.0
		for line in stats_lines: width = maxf(width,font.get_string_size(line,HORIZONTAL_ALIGNMENT_LEFT,-1,13).x)
		var height := 10.0 + stats_lines.size() * 18.0
		var top := control.size.y - height - 12
		control.draw_rect(Rect2(12,top,width+20,height),Color(0.04,0.05,0.07,0.7))
		for i in stats_lines.size(): control.draw_string(font,Vector2(22,top+19+i*18),stats_lines[i],HORIZONTAL_ALIGNMENT_LEFT,-1,13,Color(0.86,0.88,0.92))

func _refresh() -> void:
	_clear_hover()
	if not is_instance_valid(panel): return
	_update_stats()
	var poly: PolyMesh = target.poly_mesh if is_instance_valid(target) else null
	panel.convert_mesh_button.disabled=poly==null
	panel.update_stats(poly)
	_sync_button_styles(poly)
	if is_instance_valid(transform_toolbar): transform_toolbar.visible = edit_polygons and poly != null
	if poly and is_instance_valid(overlay):
		overlay.visible = edit_polygons
		overlay.mesh = Selection.overlay(target, panel.mode, panel.xray)
	if is_instance_valid(target): target.update_gizmos()
	update_overlays()

func _operation(name: String, options: Dictionary) -> void:
	procedural.cancel()
	if name == "edges_to_path":
		_edges_to_path(Input.is_key_pressed(KEY_SHIFT))
		return
	if name == "extrude_path":
		_pick_extrude_path()
		return
	if name in ["target_weld","brush","pivot"]:
		workflow.start("weld" if name=="target_weld" else name)
		return
	workflow.cancel()
	if not is_instance_valid(target) or not target.poly_mesh:
		panel.report("Select an EditableMesh or import a MeshInstance3D", true)
		return
	if name in ["bevel", "inset", "slide_edge", "slide_vertex", "extrude_normals"]:
		if not edit_polygons: _set_polygon_editing(true)
		offset_tool.start(self,options,name)
		return
	offset_tool.cancel()
	if name in ["loop_cut", "knife", "split_edge"]:
		if not edit_polygons: _set_polygon_editing(true)
		cut_tool.start(self,name)
		return
	cut_tool.cancel()
	if name in ["move", "rotate", "scale"]:
		_set_transform_mode(name)
		if Vector3(options.get("vector", Vector3.ZERO)).is_zero_approx(): return
	var poly := target.poly_mesh
	var before := Selection.selected_ids(poly, panel.mode)
	options.merge(clip_options())
	var result: Dictionary = Actions.run(poly, panel.mode, name, options)
	if not result.ok:
		panel.report(result.error, true)
		return
	if name == "extrude" and options.get("auto", false): panel.show_amount(options.get("distance", panel.amount.value))
	var after := Selection.selected_ids(poly, panel.mode)
	var delta: MeshDelta = result.delta
	_record_delta(poly, delta, name, before, after)

# Extrude Along Path: pick the Path3D, then adjust the sweep in a live preview.
func _pick_extrude_path() -> void:
	workflow.cancel(); offset_tool.cancel(); cut_tool.cancel()
	if not is_instance_valid(target) or not target.poly_mesh:
		panel.report("Select an EditableMesh first", true)
		return
	if panel.mode == "vertex" or Selection.selected_ids(target.poly_mesh, panel.mode).is_empty():
		panel.report("Select polygons (or open border edges) to extrude along a path", true)
		return
	var types: Array[StringName] = [&"Path3D"]
	get_editor_interface().popup_node_selector(func(path: NodePath):
		if path.is_empty() or not is_instance_valid(target): return
		var scene := get_editor_interface().get_edited_scene_root()
		var picked := scene.get_node_or_null(path) if scene else null
		if picked is Path3D: procedural.start_path(picked), types)

func _pick_extrude_path_again() -> void:
	var types: Array[StringName] = [&"Path3D"]
	get_editor_interface().popup_node_selector(func(path: NodePath):
		var scene := get_editor_interface().get_edited_scene_root()
		var picked := scene.get_node_or_null(path) if scene and not path.is_empty() else null
		if picked is Path3D: procedural.set_path(picked), types)

# Edges → Path: one Path3D per selected chain or loop, placed like the mesh so the
# curve points are the mesh's vertex positions.
func _edges_to_path(smooth: bool) -> void:
	if not is_instance_valid(target) or not target.poly_mesh:
		panel.report("Select an EditableMesh first", true)
		return
	var poly := target.poly_mesh
	if panel.mode != "edge" or poly.get_selected_edges().is_empty():
		panel.report("Select edges in Edge mode to turn them into a path", true)
		return
	var found: Variant = PathTools.chains(poly, poly.get_selected_edges())
	if found is Dictionary:
		panel.report(found.error, true)
		return
	var scene := get_editor_interface().get_edited_scene_root()
	var parent: Node = target.get_parent() if target != scene else target
	var undo := get_undo_redo()
	undo.create_action("Edges to path", UndoRedo.MERGE_DISABLE, scene)
	var created: Array[Path3D] = []
	for chain in found:
		if chain.vertices.size() < 2: continue
		var path := Path3D.new()
		path.name = "%sPath" % target.name
		path.curve = PathTools.make_curve(poly, chain, smooth)
		path.transform = target.transform if parent != target else Transform3D.IDENTITY
		undo.add_do_method(parent, "add_child", path, true)
		undo.add_do_method(path, "set_owner", scene)
		undo.add_do_reference(path)
		undo.add_undo_method(parent, "remove_child", path)
		created.append(path)
	undo.commit_action()
	panel.report("%d path(s) created from the edges%s. Use them with Extrude Along Path, the Curve modifier or Array." % [created.size(), " (smooth)" if smooth else ""])

func _record_delta(poly: PolyMesh, delta: MeshDelta, name: String, before: PackedInt64Array, after: PackedInt64Array) -> void:
	# commit_action() reapplies the delta immediately and notifies listeners once.
	poly.apply_delta(delta, false, false)
	poly.clear_history()
	var undo := get_undo_redo()
	undo.create_action("Modeling: " + name, UndoRedo.MERGE_DISABLE, target)
	undo.add_do_method(self, "_apply_history", poly, delta, true)
	undo.add_do_method(poly, "select", panel.mode, after, false)
	undo.add_undo_method(self, "_apply_history", poly, delta, false)
	undo.add_undo_method(poly, "select", panel.mode, before, false)
	undo.commit_action()
	panel.report(name.capitalize() + " complete")
	_refresh()

# Undo/Redo step of a modeling action; a step that no longer fits the mesh is
# reported instead of being skipped silently.
func _apply_history(poly: PolyMesh, delta: MeshDelta, forward: bool) -> void:
	if not is_instance_valid(poly): return
	if not poly.apply_delta(delta, forward):
		panel.report("%s skipped: the mesh was changed outside the editor history" % ("Redo" if forward else "Undo"), true)

func _cancel_previews() -> bool:
	var active: bool = offset_tool.active or cut_tool.kind != "" or procedural.kind != ""
	offset_tool.cancel()
	cut_tool.cancel()
	procedural.cancel()
	return active

# Mirror planes of the edited object (its stack's first Mirror modifier).
func symmetry_axes() -> Array:
	return Array(target.get_symmetry().axes) if is_instance_valid(target) else []

func symmetry_center() -> Vector3:
	return Vector3(target.get_symmetry().center) if is_instance_valid(target) else Vector3.ZERO

# Mirror clipping for transforms and slides: vertices on a plane stay on it.
func clip_options() -> Dictionary:
	if not is_instance_valid(target): return {}
	var mirror: Dictionary = target.get_symmetry()
	if Array(mirror.axes).is_empty() or not mirror.clipping: return {}
	return {"clip_axes": Array(mirror.axes), "clip_center": Vector3(mirror.center), "clip_distance": float(mirror.distance)}

func _draw_symmetry(control: Control, camera: Camera3D) -> void:
	if not camera or not edit_polygons or not is_instance_valid(target) or not target.poly_mesh: return
	var axes := symmetry_axes()
	if axes.is_empty(): return
	var bounds := target.get_base_mesh().get_aabb()
	var center: Vector3 = symmetry_center()
	var colors := [Color(0.96,0.33,0.38),Color(0.53,0.86,0.25),Color(0.33,0.6,1.0)]
	for axis in axes:
		var u := (int(axis)+1)%3
		var w := (int(axis)+2)%3
		var basis := Basis()
		basis.x = Vector3.ZERO; basis.x[u] = 1
		basis.y = Vector3.ZERO; basis.y[int(axis)] = 1
		basis.z = Vector3.ZERO; basis.z[w] = 1
		symmetry_grid.frame = target.global_transform*Transform3D(basis,center)
		symmetry_grid.extent = 6
		symmetry_grid.step = maxf(maxf(bounds.size[u],bounds.size[w]),0.001)*0.75/6.0
		symmetry_grid.color = colors[int(axis)]
		symmetry_grid.enabled = true
		symmetry_grid.draw(control,camera)

func _command(name: String) -> void:
	if name=="vertex_paint_visibility":
		vertex_paint.set_visibility(self,panel.paint_show_colors.button_pressed)
		return
	if name in ["vertex_paint","vertex_paint_fill"]:
		if name=="vertex_paint": vertex_paint.start(self)
		else:
			if not vertex_paint.active: vertex_paint.start(self)
			if vertex_paint.active: vertex_paint.begin_stroke(); vertex_paint.dab(false,true); vertex_paint.finish()
		return
	if vertex_paint.active: vertex_paint.stop()
	if name.begins_with("grid_"):
		_work_grid_command(name)
		return
	if name.begins_with("preview_"):
		procedural.start(name.trim_prefix("preview_"),true)
		return
	procedural.cancel()
	if name.begins_with("pivot_kind_"):
		workflow.pivot_mode=name.trim_prefix("pivot_kind_")
		return
	offset_tool.cancel()
	cut_tool.cancel()
	workflow.cancel()
	if name.begins_with("mirror_"):
		workflow.mirror_geometry(int(name.trim_prefix("mirror_")))
		return
	match name:
		"convert_mesh": _convert_to_mesh_instance()
		"separate": workflow.separate_faces()
		"merge_objects": workflow.merge_objects()
		"pivot_mass", "pivot_origin":
			if is_instance_valid(target): workflow.set_pivot(target,workflow.mass_center(target) if name=="pivot_mass" else Vector3.ZERO)
		"uv_editor": _open_uv_editor()
		"modifier_stack": _open_modifier_stack()
		"decals": _open_decals()
		"uv_cube", "uv_cylinder", "uv_sphere", "uv_optcuts", "uv_hard_edges":
			_uv_operation(name.trim_prefix("uv_"))
		"uv_cancel": optcuts_tool.cancel()
		"new": _add_mesh(EditableMesh.make_cube())
		"new_cylinder", "new_pyramid", "new_sphere", "new_plane":
			var kind := name.trim_prefix("new_")
			_add_mesh(EditableMesh.make_primitive(kind), null, kind.capitalize())
		"import": _import_selected()
		"undo", "redo":
			if _cancel_previews(): panel.report("Preview cancelled"); return
			var root := get_editor_interface().get_edited_scene_root()
			if not root: return
			var history := get_undo_redo().get_history_undo_redo(get_undo_redo().get_object_history_id(root))
			if history:
				if name == "undo": history.undo()
				else: history.redo()
			_refresh()
		"all", "none", "invert", "connected":
			if name != "none": _activate_selection_editing()
			if is_instance_valid(target) and target.poly_mesh:
				var poly := target.poly_mesh
				if name == "connected" and Selection.selected_ids(poly, panel.mode).is_empty():
					panel.report("Select an element first; Select Connected extends to its whole part", true)
					return
				var ids := Selection.all_ids(poly, panel.mode) if name == "all" else Selection.inverted_ids(poly, panel.mode) if name == "invert" else poly.get_connected(panel.mode) if name == "connected" else PackedInt64Array()
				poly.select(panel.mode, ids)
		"save", "export":
			if not is_instance_valid(target) or not target.poly_mesh: return
			save_export = name == "export"
			dialog.current_file = "mesh.tres" if save_export else "editable_mesh.tres"
			dialog.popup_centered_ratio(0.6)

func _add_mesh(poly: PolyMesh, source: MeshInstance3D = null, primitive_name: String = "EditableMesh") -> void:
	var root := get_editor_interface().get_edited_scene_root()
	if not root:
		panel.report("Create a 3D scene first", true)
		return
	var node := EditableMesh.new()
	node.name = primitive_name
	node.poly_mesh = poly
	var parent: Node = source.get_parent() if source and source != root else root
	if source:
		node.transform = source.transform if source != root else Transform3D.IDENTITY
		node.material_override = source.material_override
	var undo := get_undo_redo()
	undo.create_action("Create EditableMesh", UndoRedo.MERGE_DISABLE, root)
	undo.add_do_method(parent, "add_child", node, true)
	undo.add_do_method(node, "set_owner", root)
	undo.add_do_reference(node)
	undo.add_undo_method(parent, "remove_child", node)
	if source:
		undo.add_do_property(source, "visible", false)
		undo.add_undo_property(source, "visible", source.visible)
	undo.commit_action()
	var selection := get_editor_interface().get_selection()
	selection.clear()
	selection.add_node(node)
	get_editor_interface().edit_node(node)
	panel.report("Editable mesh ready. Click a polygon in the 3D viewport.")

func _convert_to_mesh_instance() -> void:
	var selected := get_editor_interface().get_selection().get_selected_nodes()
	if selected.size()!=1 or not selected[0] is EditableMesh or not selected[0].poly_mesh:
		panel.report("Select one EditableMesh to convert",true)
		return
	var source: EditableMesh=selected[0]
	_set_polygon_editing(false)
	if is_instance_valid(uv_window): uv_window.canvas.cancel()
	# A plain MeshInstance3D with the baked mesh and every stored MeshInstance3D setting.
	var converted := MeshInstance3D.new()
	# The baked mesh includes the modifier stack.
	converted.mesh = source.mesh.duplicate() if source.mesh else source.poly_mesh.to_array_mesh()
	for property in source.get_property_list():
		var property_name: String = property.name
		if not property.usage & PROPERTY_USAGE_STORAGE or property_name in ["poly_mesh","mesh","script"]: continue
		if property_name in converted: converted.set(property_name, source.get(property_name))
	var undo := get_undo_redo()
	undo.create_action("Convert to MeshInstance3D",UndoRedo.MERGE_DISABLE,source)
	undo.add_do_method(self,"_swap_mesh_node",source,converted)
	undo.add_undo_method(self,"_swap_mesh_node",converted,source)
	undo.add_do_reference(converted)
	undo.add_undo_reference(source)
	undo.commit_action()
	panel.report("Converted to MeshInstance3D. Undo restores EditableMesh.")

func _swap_mesh_node(from: MeshInstance3D, to: MeshInstance3D) -> void:
	if not is_instance_valid(from) or not from.is_inside_tree(): return
	if vertex_paint.active: vertex_paint.stop()
	_set_polygon_editing(false)
	if is_instance_valid(uv_window) and uv_window.node==from:
		uv_window.canvas.bind_mesh(null)
		uv_window.node=null
		uv_window.hide()
	var selection := get_editor_interface().get_selection()
	selection.clear()
	_disconnect_target()
	# replace_by keeps the name slot, parent index, owner, children and groups.
	to.name = from.name
	from.replace_by(to, true)
	to.update_gizmos()
	selection.add_node(to)
	_selection_changed()
	get_editor_interface().edit_node(to)

func _import_selected() -> void:
	var nodes := get_editor_interface().get_selection().get_selected_nodes()
	if nodes.size() != 1 or not nodes[0] is MeshInstance3D or not nodes[0].mesh:
		panel.report("Select one MeshInstance3D with a mesh", true)
		return
	var source: MeshInstance3D = nodes[0]
	if source == get_editor_interface().get_edited_scene_root():
		panel.report("Place the mesh below a Node3D root before importing", true)
		return
	var arrays := ArrayMesh.new()
	if source.mesh is ArrayMesh: arrays = source.mesh
	else:
		for i in source.mesh.get_surface_count():
			arrays.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, source.mesh.surface_get_arrays(i))
			arrays.surface_set_material(i, source.mesh.surface_get_material(i))
	var poly := PolyMesh.new()
	# Importers triangulate; restore quads so loop tools work on the result.
	var result := poly.from_array_mesh(arrays, true, true)
	if not result.ok:
		panel.report(result.error, true)
		return
	var mats := poly.materials
	for i in source.get_surface_override_material_count():
		if source.get_surface_override_material(i) and i < mats.size(): mats[i] = source.get_surface_override_material(i)
	poly.materials = mats
	poly.clear_history()
	_add_mesh(poly, source)

func _save(path: String) -> void:
	if not is_instance_valid(target): return
	var resource: Resource = (target.mesh.duplicate() if target.mesh else target.poly_mesh.to_array_mesh()) if save_export else target.poly_mesh
	var error := ResourceSaver.save(resource, path)
	panel.report("Saved " + path if error == OK else "Save failed: " + error_string(error), error != OK)
	get_editor_interface().get_resource_filesystem().scan()

func _input(event: InputEvent) -> void:
	if procedural.kind!="" and event is InputEventKey and event.pressed and not event.echo:
		if event.keycode in [KEY_ENTER,KEY_KP_ENTER,KEY_ESCAPE]:
			if event.keycode==KEY_ESCAPE: procedural.cancel()
			else: procedural.apply()
			get_viewport().set_input_as_handled()
			return
	if _selection_shortcut(event,get_viewport().gui_get_focus_owner()):
		get_viewport().set_input_as_handled()

func _selection_shortcut(event: InputEvent, focus: Control) -> bool:
	if vertex_paint.active: return false
	if not event is InputEventKey or not event.pressed: return false
	if event.ctrl_pressed or event.alt_pressed or event.shift_pressed or event.meta_pressed: return false
	if event.keycode not in [KEY_1,KEY_2,KEY_3,KEY_4,KEY_A]: return false
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT): return false
	if event.keycode!=KEY_4 and (gizmo_plugin.dragging or offset_tool.active or cut_tool.kind != ""): return false
	if event.keycode==KEY_4 and not edit_polygons: return false
	if focus is LineEdit or focus is TextEdit: return false
	var context := selection_popup.visible
	if not context and is_instance_valid(focus):
		context = top_toolbar.is_ancestor_of(focus)
		for i in 4:
			var viewport := get_editor_interface().get_editor_viewport_3d(i)
			if viewport:
				var surface := viewport.get_parent().get_parent()
				if focus == surface or surface.is_ancestor_of(focus): context = true
	if not context: return false
	var nodes := get_editor_interface().get_selection().get_selected_nodes()
	if nodes.size() != 1 or not nodes[0] is EditableMesh or not nodes[0].poly_mesh: return false
	if event.echo: return true
	if event.keycode == KEY_4: _set_polygon_editing(false)
	elif event.keycode == KEY_A: _command("all")
	else: panel.set_mode({KEY_1:"vertex",KEY_2:"edge",KEY_3:"face"}[event.keycode])
	selection_popup.hide()
	return true

func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if is_instance_valid(decal_window) and decal_window.visible and decal_window.placing and decal_window.viewport_input(camera,event): return AFTER_GUI_INPUT_STOP
	if not edit_polygons and not vertex_paint.active and not work_grid.placing and procedural.kind == "": object_snap.input(camera,event)
	if vertex_paint.active: return AFTER_GUI_INPUT_STOP if vertex_paint.input(camera,event) else AFTER_GUI_INPUT_PASS
	if work_grid.enabled and work_grid.scene!=get_editor_interface().get_edited_scene_root(): work_grid.enabled=false; work_grid.placing=false
	if work_grid.enabled and work_grid.input(self,camera,event): return AFTER_GUI_INPUT_STOP
	if procedural.input(camera,event): return AFTER_GUI_INPUT_STOP
	if not is_instance_valid(target) or not target.poly_mesh: return AFTER_GUI_INPUT_PASS
	if edit_polygons and event is InputEventKey and event.pressed and event.keycode==KEY_4 and not event.ctrl_pressed and not event.alt_pressed and not event.shift_pressed and not event.meta_pressed and not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_set_polygon_editing(false)
		return AFTER_GUI_INPUT_STOP
	# Fly-camera keys must never activate modeling (notably RMB + A).
	if event is InputEventKey and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT): return AFTER_GUI_INPUT_PASS
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_TAB and not event.ctrl_pressed and not event.alt_pressed:
		_set_polygon_editing(not edit_polygons)
		return AFTER_GUI_INPUT_STOP
	if not edit_polygons and event is InputEventKey and event.pressed and not event.echo and not event.ctrl_pressed and not event.alt_pressed:
		match event.keycode:
			KEY_1: panel.set_mode("vertex"); return AFTER_GUI_INPUT_STOP
			KEY_2: panel.set_mode("edge"); return AFTER_GUI_INPUT_STOP
			KEY_3: panel.set_mode("face"); return AFTER_GUI_INPUT_STOP
			KEY_A: _command("all"); return AFTER_GUI_INPUT_STOP
	if not edit_polygons: return AFTER_GUI_INPUT_PASS
	# Ctrl+Z (or redo) during a tool preview drops the preview instead of being
	# swallowed by the tool; the next press reaches the editor history.
	if event is InputEventKey and event.pressed and not event.echo and event.ctrl_pressed and event.keycode in [KEY_Z, KEY_Y]:
		if _cancel_previews():
			panel.report("Preview cancelled")
			return AFTER_GUI_INPUT_STOP
		return AFTER_GUI_INPUT_PASS
	if workflow.mode!="":
		return AFTER_GUI_INPUT_STOP if workflow.input(camera,event) else AFTER_GUI_INPUT_PASS
	if offset_tool.active:
		return AFTER_GUI_INPUT_STOP if offset_tool.input(camera,event) else AFTER_GUI_INPUT_PASS
	if cut_tool.kind != "":
		return AFTER_GUI_INPUT_STOP if cut_tool.input(camera,event) else AFTER_GUI_INPUT_PASS
	if event is InputEventKey and event.pressed and not event.echo and not event.alt_pressed:
		if event.keycode == KEY_K or (event.keycode == KEY_R and event.ctrl_pressed):
			_operation("knife" if event.keycode == KEY_K else "loop_cut",{})
			return AFTER_GUI_INPUT_STOP
	if event is InputEventMouseMotion:
		if event.button_mask != 0 or event.alt_pressed or gizmo_plugin.dragging:
			_clear_hover()
		else:
			if panel.mode in ["vertex", "edge"]: _update_hover(camera, event.position)
			if transform_mode == "move" and snapping.has_geometry_targets():
				if Time.get_ticks_msec()-snap_preview_time > 150 or snapping.meshes.is_empty():
					snapping.begin(get_editor_interface().get_edited_scene_root(),target)
					snap_preview_time = Time.get_ticks_msec()
				snapping.pick(camera,event.position,panel.pick_radius,Vector3.ZERO,Vector3.ZERO,panel.xray)
				update_overlays()
		return AFTER_GUI_INPUT_PASS
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed and not event.alt_pressed:
		if event.double_click and _select_loop(camera,event.position,event.shift_pressed): return AFTER_GUI_INPUT_STOP
		if gizmo_plugin.hit_handle(target, camera, event.position): return AFTER_GUI_INPUT_PASS
		var hit := _update_hover(camera, event.position)
		target.poly_mesh.select(panel.mode, PackedInt64Array([hit]) if hit >= 0 else PackedInt64Array(), event.shift_pressed)
		_update_hover(camera, event.position)
		return AFTER_GUI_INPUT_STOP
	if event is InputEventKey and event.pressed and not event.echo and not event.ctrl_pressed and not event.alt_pressed and not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		match event.keycode:
			KEY_W: _set_transform_mode("move")
			KEY_R: _set_transform_mode("rotate")
			KEY_S: _set_transform_mode("scale")
			KEY_1: panel.set_mode("vertex")
			KEY_2: panel.set_mode("edge")
			KEY_3: panel.set_mode("face")
			KEY_A: _command("all")
			KEY_E: panel.run("extrude")
			KEY_I: panel.run("inset")
			KEY_B: panel.run("bevel")
			KEY_J: panel.run("connect")
			KEY_DELETE: panel.run("delete")
			_: return AFTER_GUI_INPUT_PASS
		return AFTER_GUI_INPUT_STOP
	return AFTER_GUI_INPUT_PASS

func _set_transform_mode(tool: String) -> void:
	procedural.cancel()
	workflow.cancel()
	if tool not in ["move", "rotate", "scale"]: return
	offset_tool.cancel()
	cut_tool.cancel()
	gizmo_plugin.cancel_drag()
	transform_mode = tool
	for name in transform_buttons: transform_buttons[name].set_pressed_no_signal(name == tool)
	panel.report({"move": "Move: axis handles constrain movement; center handle moves freely. Ctrl snaps to the Godot grid.", "rotate": "Rotate: drag a ring handle. Ctrl snaps to 15 degrees.", "scale": "Scale: drag an axis or the white handle for uniform scale. Ctrl snaps to 0.1."}[tool])
	_refresh()

func _clear_hover() -> void:
	if is_instance_valid(gizmo_plugin) and not gizmo_plugin.dragging:
		snapping.candidate = {}
		update_overlays()
	hover_id = -1
	if is_instance_valid(hover_overlay): hover_overlay.mesh = null
	if is_instance_valid(panel): panel.show_hover("", -1)

func _update_hover(camera: Camera3D, position: Vector2) -> int:
	if gizmo_plugin.hit_handle(target, camera, position):
		_clear_hover()
		return -1
	var control := camera.get_viewport().get_parent() as Control
	if control and control != hover_viewport_control:
		if is_instance_valid(hover_viewport_control) and hover_viewport_control.mouse_exited.is_connected(_clear_hover):
			hover_viewport_control.mouse_exited.disconnect(_clear_hover)
		hover_viewport_control = control
		control.mouse_exited.connect(_clear_hover)
	var hit := Selection.pick(target, camera, position, panel.mode, panel.xray, panel.pick_radius)
	if panel.mode in ["vertex", "edge"] and hit != hover_id:
		hover_id = hit
		if is_instance_valid(hover_overlay): hover_overlay.mesh = Selection.hover_overlay(target, panel.mode, hit, panel.xray)
		panel.show_hover(panel.mode, hit)
	return hit

func _select_loop(camera: Camera3D, mouse: Vector2, append: bool) -> bool:
	var poly := target.poly_mesh
	var seed := Selection.pick(target,camera,mouse,"edge",panel.xray,panel.pick_radius)
	if seed < 0: return false
	var ids := {}
	if append:
		for id in Selection.selected_ids(poly,panel.mode): ids[id] = true
	if panel.mode == "face":
		var strip := Topology.ring(poly,seed)
		if strip.is_empty(): return false
		for fid in strip.cuts: ids[fid] = true
	else:
		for eid in Topology.edge_loop(poly,seed):
			if panel.mode == "edge": ids[eid] = true
			else:
				var edge := poly.get_edge(eid)
				ids[edge.vertex_a] = true
				ids[edge.vertex_b] = true
	poly.select(panel.mode,PackedInt64Array(ids.keys()),false)
	panel.report("Loop selected; Shift-double-click adds a loop")
	return true

func _forward_3d_draw_over_viewport(control: Control) -> void:
	if offset_tool.active:
		var camera := _camera_for_overlay(control)
		if camera: offset_tool.draw(control,camera)

func _forward_3d_force_draw_over_viewport(control: Control) -> void:
	_draw_info(control)
	procedural.draw(control,_camera_for_overlay(control))
	vertex_paint.draw(control,_camera_for_overlay(control))
	work_grid.draw(control,_camera_for_overlay(control))
	_draw_symmetry(control,_camera_for_overlay(control))
	if workflow.mode!="" and edit_polygons:
		workflow.camera=_camera_for_overlay(control)
		workflow.draw(control)
	if snapping.candidate.is_empty(): return
	var camera := _camera_for_overlay(control)
	if camera: snapping.draw(control,camera)

func _toggle_snap(id: int) -> void:
	if id in [10,11,12]:
		grid_division=[1,5,10][id-10]
		for i in 3: snap_menu.get_popup().set_item_checked(snap_menu.get_popup().get_item_index(10+i),i==id-10)
		return
	var settings := {0:"grid",1:"vertices",2:"edges",20:"edge_centers",21:"face_centers"}
	if not settings.has(id): return
	object_snap.clear()
	gizmo_plugin.cancel_drag()
	var setting: String = settings[id]
	snapping.set(setting,not snapping.get(setting))
	snap_menu.get_popup().set_item_checked(snap_menu.get_popup().get_item_index(id),snapping.get(setting))
	_mark_active(snap_menu,snapping.grid or snapping.has_geometry_targets())

func _apply_changes() -> void:
	procedural.cancel()
	if is_instance_valid(uv_window): uv_window.canvas.cancel()
	offset_tool.cancel()
	cut_tool.cancel()
	if is_instance_valid(gizmo_plugin): gizmo_plugin.cancel_drag()

func _process(_delta: float) -> void:
	var active: String = procedural.kind if procedural.kind!="" else ("target_weld" if workflow.mode=="weld" else workflow.mode) if workflow.mode!="" else offset_tool.operation if offset_tool.active else cut_tool.kind if cut_tool.kind != "" else transform_mode if edit_polygons and is_instance_valid(target) else ""
	dock_active_tool = active
	panel.set_active_tool(active)
	if edit_polygons and is_instance_valid(target): _sync_origin_gizmo()

func _sync_origin_gizmo() -> void:
	if not is_instance_valid(origin_gizmo_controller):
		var viewport := get_editor_interface().get_editor_viewport_3d(0)
		var current: Node = viewport
		while current:
			if current.has_method("update_transform_gizmo"):
				origin_gizmo_controller = current
				break
			current = current.get_parent()
	if not is_instance_valid(origin_gizmo_controller): return
	# Godot has no public per-node visibility API for its transform manipulator.
	# Use the editor's lock filter only during this synchronous recalculation.
	# The metadata is removed immediately: it is never saved and custom handles remain usable.
	var temporary_lock := edit_polygons and is_instance_valid(target) and not target.has_meta("_edit_lock_")
	if temporary_lock: target.set_meta("_edit_lock_",true)
	origin_gizmo_controller.call("update_transform_gizmo")
	if temporary_lock: target.remove_meta("_edit_lock_")

func _camera_for_overlay(control: Control) -> Camera3D:
	var ancestor := control.get_parent()
	while ancestor:
		for i in 4:
			var viewport := get_editor_interface().get_editor_viewport_3d(i)
			if viewport and ancestor.is_ancestor_of(viewport): return viewport.get_camera_3d()
		ancestor = ancestor.get_parent()
	return null

func _create_top_toolbar() -> void:
	top_toolbar = VBoxContainer.new()
	top_toolbar.name = "ModelingToolbar"
	var row := HBoxContainer.new()
	top_toolbar.add_child(row)
	row.add_child(VSeparator.new())
	row.add_child(edit_button)
	row.add_child(transform_toolbar)
	row.add_child(VSeparator.new())
	_create_selection_dropdown(row)
	snap_menu = MenuButton.new()
	snap_menu.flat = true
	snap_menu.text = "Snap"
	snap_menu.icon = _editor_icon("Snap")
	snap_menu.switch_on_hover = true
	snap_menu.tooltip_text = "Snapping for Move: grid, neighboring vertices, edges and centers"
	row.add_child(snap_menu)
	var popup := snap_menu.get_popup()
	popup.hide_on_checkable_item_selection = false
	for title in ["Grid", "Vertices", "Edges"]: popup.add_check_item(title)
	popup.add_check_item("Edge Centers",20)
	popup.add_check_item("Face Centers",21)
	popup.add_separator()
	popup.add_item("Godot grid step",4)
	popup.set_item_disabled(popup.get_item_index(4),true)
	popup.add_separator()
	for divisor in [1,5,10]: popup.add_radio_check_item("Grid 1:"+str(divisor),10+[1,5,10].find(divisor))
	popup.set_item_checked(popup.get_item_index(10),true)
	popup.id_pressed.connect(_toggle_snap)
	popup.about_to_popup.connect(func():
		for i in 3: popup.set_item_checked(i,snapping.get(["grid","vertices","edges"][i]))
		popup.set_item_checked(popup.get_item_index(20),snapping.edge_centers)
		popup.set_item_checked(popup.get_item_index(21),snapping.face_centers)
		popup.set_item_text(popup.get_item_index(4),"Godot grid step: " + str(grid_step())))
	row.add_child(VSeparator.new())
	_create_tool_dropdown(row,"Working Grid")
	_create_tool_dropdown(row,"Pivot Modifications")
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, top_toolbar)

func _create_tool_dropdown(row: HBoxContainer, title: String) -> void:
	var button := Button.new()
	button.theme_type_variation = "FlatButton"
	button.text = {"Pivot Modifications":"Pivot"}.get(title,title)
	button.icon = _editor_icon({"Working Grid":"Grid","Pivot Modifications":"EditorPivot"}[title])
	button.tooltip_text = title
	row.add_child(button)
	var popup := PopupPanel.new()
	button.add_child(popup)
	tool_popups[title]=popup
	var margin := MarginContainer.new()
	for side in ["left","top","right","bottom"]: margin.add_theme_constant_override("margin_"+side,8)
	popup.add_child(margin)
	var contents: VBoxContainer=panel.sections[title]
	var old_group := contents.get_parent()
	contents.reparent(margin)
	contents.custom_minimum_size.x = 280 # Inspector-style rows need room for their labels.
	contents.show()
	panel.sections.erase(title)
	panel.section_buttons.erase(title)
	old_group.hide()
	old_group.queue_free()
	_close_dropdown_on_actions(contents,popup)
	button.pressed.connect(func():
		selection_popup.hide()
		for other in tool_popups.values():
			if other!=popup: other.hide()
		popup.reset_size()
		popup.popup(Rect2i(Vector2i(button.get_screen_position()+Vector2(0,button.size.y)),Vector2i(popup.get_contents_minimum_size()))))

func _close_dropdown_on_actions(control: Node, popup: PopupPanel) -> void:
	if control is Button and not (control is CheckBox or control is CheckButton or control is OptionButton):
		control.pressed.connect(func(): popup.hide())
	for child in control.get_children(): _close_dropdown_on_actions(child,popup)

func _activate_selection_editing() -> void:
	var nodes := get_editor_interface().get_selection().get_selected_nodes()
	if nodes.size() != 1 or not nodes[0] is MeshInstance3D: return
	if nodes[0] is EditableMesh:
		if target != nodes[0]: _selection_changed()
	elif nodes[0].mesh:
		_import_selected()
		_selection_changed()
	if is_instance_valid(target) and target.poly_mesh and not edit_polygons:
		_set_polygon_editing(true)

func _create_selection_dropdown(row: HBoxContainer) -> void:
	selection_menu = Button.new()
	selection_menu.theme_type_variation = "FlatButton"
	selection_menu.text = "Selection"
	selection_menu.tooltip_text = "Selection mode (1 / 2 / 3), All (A), None, X-ray and pick radius"
	row.add_child(selection_menu)
	selection_popup = PopupPanel.new()
	selection_menu.add_child(selection_popup)
	selection_popup.window_input.connect(func(event):
		if _selection_shortcut(event,selection_popup.gui_get_focus_owner()): selection_popup.set_input_as_handled())
	var items := VBoxContainer.new()
	selection_popup.add_child(items)
	# Menu-like list: flat, left-aligned entries; the active mode shows the pressed state.
	for button in panel.mode_buttons:
		button.reparent(items)
		button.theme_type_variation = "FlatButton"
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	items.add_child(HSeparator.new())
	for control in panel.selection_rows[1].get_children():
		control.reparent(items)
		if control is Button and not control is CheckButton:
			control.toggle_mode = false
			control.theme_type_variation = "FlatButton"
			control.alignment = HORIZONTAL_ALIGNMENT_LEFT
			selection_commands.append(control)
	items.add_child(HSeparator.new())
	panel.selection_rows[2].reparent(items)
	for old_row in panel.selection_rows:
		if old_row.get_parent() == panel: old_row.hide()
	panel.stats.hide()
	panel.hover_hint.hide()
	selection_menu.pressed.connect(func():
		selection_popup.reset_size()
		selection_popup.popup(Rect2i(Vector2i(selection_menu.get_screen_position()+Vector2(0,selection_menu.size.y)),Vector2i(selection_popup.get_contents_minimum_size()))))
	for button in panel.mode_buttons + selection_commands:
		button.pressed.connect(func(): selection_popup.hide(); _refresh())

func _mark_active(button: Button, active: bool) -> void:
	# Toggles use the theme's pressed state; menu buttons get the accent tint,
	# like the active options in Godot's own toolbars.
	if button.toggle_mode and not button is MenuButton: # MenuButton toggles only while open.
		button.set_pressed_no_signal(active)
		return
	var accent := get_editor_interface().get_base_control().get_theme_color("accent_color","Editor")
	for color_name in ["font_color","font_hover_color","icon_normal_color","icon_hover_color"]:
		if active: button.add_theme_color_override(color_name,accent)
		else: button.remove_theme_color_override(color_name)

func _editor_icon(icon_name: String) -> Texture2D:
	var base := get_editor_interface().get_base_control()
	return base.get_theme_icon(icon_name,"EditorIcons") if base.has_theme_icon(icon_name,"EditorIcons") else null

func _sync_button_styles(poly: PolyMesh) -> void:
	if not is_instance_valid(selection_menu): return
	var active := edit_polygons and poly != null
	selection_menu.text = {"vertex":"Vertex","edge":"Edge","face":"Polygons"}[panel.mode] if active else "Selection"
	selection_menu.icon = panel.mode_icons.get(panel.mode) if active else null
	_mark_active(selection_menu,active)
	_mark_active(edit_button,active)
	for button in panel.mode_buttons:
		_mark_active(button,active and button.get_meta("selection_mode") == panel.mode)
	for tool in transform_buttons:
		_mark_active(transform_buttons[tool],active and transform_mode == tool)
	for i in selection_commands.size():
		var on := false # All/None are commands, not persistent selection modes.
		selection_commands[i].set_pressed_no_signal(on)
		_mark_active(selection_commands[i],on)

func grid_step() -> float:
	return maxf(0,float(get_editor_interface().get_editor_settings().get_project_metadata("3d_editor","snap_translate_value",1.0)))/grid_division

func snap_move(node: EditableMesh, camera: Camera3D, mouse: Vector2, center: Vector3, offset: Vector3, axis: Vector3, ctrl: bool) -> Vector3:
	var origin := node.global_transform*center
	var world_axis := (node.global_transform.basis*axis).normalized()
	var candidate: Dictionary = snapping.pick(camera,mouse,panel.pick_radius,origin,world_axis,panel.xray)
	if not candidate.is_empty():
		update_overlays()
		return node.global_transform.affine_inverse()*Vector3(candidate.snapped_position)-center
	var position := node.global_transform*(center+offset)
	if snapping.grid or ctrl:
		var step := grid_step() * (0.1 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
		position = Snapping.grid_position(position,origin,world_axis,step)
	update_overlays()
	return node.global_transform.affine_inverse()*position-center

func _uv_operation(kind: String) -> void:
	if uv_busy:
		panel.report("OptCuts is running. Cancel it before starting another UV operation.",true)
		return
	_activate_selection_editing()
	if not is_instance_valid(target) or not target.poly_mesh:
		panel.report("Select a mesh for UV mapping",true)
		return
	offset_tool.cancel()
	cut_tool.cancel()
	gizmo_plugin.cancel_drag()
	var node := target
	var poly := node.poly_mesh
	var before := Selection.selected_ids(poly,panel.mode)
	var result: Dictionary
	if kind == "optcuts":
		var snapshot := poly.get_data()
		var source := poly.to_array_mesh()
		uv_busy = true
		panel.report("OptCuts: optimizing UVs in background… Cancel OptCuts stops the operation.")
		result = await optcuts_tool.unwrap(get_tree(),source)
		uv_busy = false
		if not is_instance_valid(node) or target != node or node.poly_mesh != poly: return
		if not result.ok:
			panel.report(result.error,true)
			return
		if poly.get_data() != snapshot:
			panel.report("Mesh changed during OptCuts. Result discarded; current edits preserved.",true)
			return
		before = Selection.selected_ids(poly,panel.mode)
		result = poly.from_array_mesh(result.mesh)
	else:
		var faces := poly.get_selected_faces() if panel.mode == "face" else PackedInt64Array()
		if kind == "hard_edges": result = poly.execute("hard_edge_unwrap",faces,{"angle":30.0,"pack":true})
		else: result = preload("res://addons/modeling_tool/editor/uv_projection.gd").project(poly,faces,kind)
	if not result.ok:
		panel.report(result.error,true)
		return
	var after := before if kind != "optcuts" else poly.get_face_ids() if panel.mode == "face" else PackedInt64Array()
	_record_delta(poly,result.delta,"UV "+kind.capitalize(),before,after)
	panel.report("UV "+kind.capitalize()+" complete"+" (triangulated mesh)" if kind == "optcuts" else "UV "+kind.capitalize()+" complete")

func _open_modifier_stack() -> void:
	_activate_selection_editing()
	if not is_instance_valid(target) or not target.poly_mesh:
		panel.report("Select an EditableMesh first",true)
		return
	if not is_instance_valid(modifier_window):
		modifier_window = preload("res://addons/modeling_tool/editor/modifier_window.gd").new()
		modifier_window.editor_plugin = self
		modifier_window.visible = false
		get_editor_interface().get_base_control().add_child(modifier_window)
	modifier_window.open_mesh(target)

func _selected_decal() -> MeshDecal3D:
	var nodes := get_editor_interface().get_selection().get_selected_nodes()
	return nodes[0] if nodes.size() == 1 and nodes[0] is MeshDecal3D else null

func _open_decals() -> void:
	if not is_instance_valid(decal_window):
		decal_window = preload("res://addons/modeling_tool/editor/decal_window.gd").new()
		decal_window.editor_plugin = self
		decal_window.visible = false
		get_editor_interface().get_base_control().add_child(decal_window)
	decal_window.open(_selected_decal())

func _open_uv_editor() -> void:
	_activate_selection_editing()
	if not is_instance_valid(target) or not target.poly_mesh:
		panel.report("Select a mesh first",true)
		return
	if not is_instance_valid(uv_window):
		uv_window = preload("res://addons/modeling_tool/editor/uv_window.gd").new()
		uv_window.editor_plugin = self
		get_editor_interface().get_base_control().add_child(uv_window)
	uv_window.open_mesh(target)

func _work_grid_command(action: String) -> void:
	work_grid.step=panel.work_grid_step.value
	work_grid.align_objects=panel.work_grid_align.button_pressed
	match action:
		"grid_clear": work_grid.enabled=false; work_grid.placing=false; work_grid.hit=null
		"grid_face":
			if not is_instance_valid(target) or not target.poly_mesh or target.poly_mesh.get_selected_faces().size()!=1:
				panel.report("Select exactly one polygon for the working grid",true); return
			if absf(target.global_transform.basis.determinant())<1e-10: panel.report("Mesh has zero scale",true); return
			work_grid.frame=work_grid.face_frame(target,target.poly_mesh.get_selected_faces()[0])
			work_grid.scene=get_editor_interface().get_edited_scene_root()
			work_grid.enabled=true; work_grid.placing=false; work_grid.hit=null
			panel.report("Working grid ready. Select another object, then Place selected on grid.")
		"grid_place":
			if not work_grid.enabled: panel.report("Create a working grid from a polygon first",true); return
			offset_tool.cancel(); cut_tool.cancel(); workflow.cancel(); gizmo_plugin.cancel_drag()
			_set_polygon_editing(false)
			work_grid.placing=true
			panel.report("Click the working grid to place the selected object's pivot. Esc cancels.")
	update_overlays()
