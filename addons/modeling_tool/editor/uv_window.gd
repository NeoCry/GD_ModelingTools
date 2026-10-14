@tool
extends Window
const Seams = preload("res://addons/modeling_tool/editor/uv_seams.gd")
const UVProjection = preload("res://addons/modeling_tool/editor/uv_projection.gd")
const OptCuts = preload("res://addons/modeling_tool/editor/optcuts_tool.gd")
var runner = OptCuts.new()
var busy := false
var mesh_preview = preload("res://addons/modeling_tool/editor/uv_mesh_preview.gd").new()
const EditOps=preload("res://addons/modeling_tool/editor/uv_edit_ops.gd")
var relax_iterations: SpinBox
var material_id: SpinBox
var target_density: SpinBox
var density_label: Label
var atlas_width: SpinBox
var atlas_height: SpinBox
var density_elapsed := 0.0
var density_dirty := true
var density_state: Array = []
const Canvas = preload("res://addons/modeling_tool/editor/uv_canvas.gd")
var editor_plugin: EditorPlugin
var node: EditableMesh
var canvas: Control
var status: Label
var dialog: FileDialog
var loaded_material: Material
var mode_buttons := {}
var selection_method: OptionButton
var brush_radius: SpinBox
var view_popup: PopupMenu
var projection_plane: OptionButton
var hard_angle: SpinBox
var hard_pack: CheckBox
var hard_rotate: CheckBox
var live_toggle: CheckBox
var u: SpinBox
var v: SpinBox
var angle: SpinBox
var factor: SpinBox

func _ready() -> void:
	always_on_top = true
	title = "UV Editor"
	size = Vector2i(1180,760)
	min_size = Vector2i(980,500)
	close_requested.connect(func(): canvas.cancel(); runner.cancel(); hide())
	visibility_changed.connect(func(): if not visible and is_instance_valid(canvas): canvas.cancel())
	window_input.connect(_window_input)
	# Layout follows the built-in editors: contextual toolbar on top, viewport on
	# the left, inspector-style property panel on the right, status bar below.
	var background := PanelContainer.new()
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.add_theme_stylebox_override("panel",editor_style("Background"))
	add_child(background)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation",0)
	background.add_child(root)
	root.add_child(_create_toolbar())
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)
	canvas = Canvas.new()
	canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(canvas)
	split.add_child(_create_sidebar())
	root.add_child(_create_status_bar())
	canvas.edited.connect(commit)
	canvas.preview_changed.connect(func(coordinates): mesh_preview.update(node,coordinates))
	canvas.user_selection_changed.connect(_sync_mesh_selection)
	canvas.selection_changed.connect(func(count): density_dirty=true; status.text="%d selected faces · %d UV islands" % [count,canvas.islands.size()])
	dialog = FileDialog.new()
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.filters = PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp, *.svg; Atlas","*.tres, *.res; Godot texture / material"])
	add_child(dialog)
	dialog.file_selected.connect(load_background)
	set_tool("move")

func _create_toolbar() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",editor_style("ContextualToolbar"))
	var bar := HBoxContainer.new()
	panel.add_child(bar)
	var tools := ButtonGroup.new()
	var tool_info := {"move":["ToolMove","Move","W"],"rotate":["ToolRotate","Rotate","E"],"scale":["ToolScale","Scale","R"],"none":["ToolSelect","Select only, no transform handles","Q"]}
	for tool in ["move","rotate","scale","none"]:
		var info: Array = tool_info[tool]
		var button := tool_button(bar,info[0],"%s (%s)" % [info[1],info[2]],func(): set_tool(tool))
		button.toggle_mode = true
		button.button_group = tools
		mode_buttons[tool] = button
	bar.add_child(VSeparator.new())
	var selection_type := OptionButton.new()
	selection_type.flat = true
	selection_type.tooltip_text = "Selection element"
	for label in ["Islands","Points","Edges"]: selection_type.add_item(label)
	selection_type.item_selected.connect(func(index): canvas.set_component_mode(index))
	bar.add_child(selection_type)
	selection_method = OptionButton.new()
	selection_method.flat = true
	selection_method.tooltip_text = "Selection method (Tab)\nShift: add · Ctrl: subtract"
	for label in ["Box Select","Brush Select"]: selection_method.add_item(label)
	selection_method.item_selected.connect(_set_selection_method)
	bar.add_child(selection_method)
	brush_radius = SpinBox.new()
	brush_radius.min_value = 2
	brush_radius.max_value = 300
	brush_radius.value = 40
	brush_radius.suffix = "px"
	brush_radius.tooltip_text = "Brush radius"
	brush_radius.value_changed.connect(func(value): canvas.brush_radius=value; canvas.queue_redraw())
	brush_radius.visible = false
	bar.add_child(brush_radius)
	tool_button(bar,"","Select all (A)",func(): canvas.select_all()).text = "All"
	tool_button(bar,"","Clear selection",func(): canvas.clear_selection()).text = "None"
	bar.add_child(VSeparator.new())
	tool_button(bar,"","Undo (Ctrl+Z)",func(): history(false)).text = "Undo"
	tool_button(bar,"","Redo (Ctrl+Shift+Z)",func(): history(true)).text = "Redo"
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)
	var texture_menu := MenuButton.new()
	texture_menu.text = "Texture"
	texture_menu.flat = true
	texture_menu.switch_on_hover = true
	var texture_popup := texture_menu.get_popup()
	texture_popup.add_icon_item(editor_icon("Load"),"Load Atlas or Material...",0)
	texture_popup.add_icon_item(editor_icon("StandardMaterial3D"),"Use Mesh Material",1)
	texture_popup.add_separator()
	texture_popup.add_item("Apply Background Material to Mesh",2)
	texture_popup.add_icon_item(editor_icon("Clear"),"Clear Background",3)
	texture_popup.id_pressed.connect(_texture_menu)
	bar.add_child(texture_menu)
	var view_menu := MenuButton.new()
	view_menu.text = "View"
	view_menu.flat = true
	view_menu.switch_on_hover = true
	view_popup = view_menu.get_popup()
	view_popup.add_check_item("Tile Atlas",0)
	view_popup.set_item_checked(0,true)
	view_popup.set_item_tooltip(0,"Repeat the atlas across the UV plane; disable to show only UV 0–1.")
	view_popup.add_check_item("Highlight Flipped Islands",1)
	view_popup.set_item_checked(1,true)
	view_popup.set_item_tooltip(1,"Mark islands with mirrored UV winding in purple.")
	view_popup.add_separator()
	view_popup.add_icon_item(editor_icon("CenterView"),"Frame UVs",2)
	view_popup.set_item_accelerator(view_popup.get_item_index(2),KEY_F)
	view_popup.id_pressed.connect(_view_menu)
	bar.add_child(view_menu)
	tool_button(bar,"CenterView","Frame UVs (F)",func(): canvas.fit())
	return panel

func _texture_menu(id: int) -> void:
	match id:
		0: dialog.popup_centered(Vector2i(850,600))
		1: _use_material()
		2: _apply_material()
		3:
			canvas.texture = null
			loaded_material = null
			canvas.queue_redraw()

func _view_menu(id: int) -> void:
	if id == 2:
		canvas.fit()
		return
	var index := view_popup.get_item_index(id)
	view_popup.set_item_checked(index,not view_popup.is_item_checked(index))
	if id == 0: canvas.tile_atlas = view_popup.is_item_checked(index)
	else: canvas.highlight_flipped = view_popup.is_item_checked(index)
	canvas.queue_redraw()

func _create_sidebar() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = 320
	panel.add_theme_stylebox_override("panel",editor_style("PanelForeground"))
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	var sidebar := VBoxContainer.new()
	sidebar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(sidebar)

	var transforms := section(sidebar,"Transform")
	u = spin(transforms,"Offset U",0,-100,100)
	v = spin(transforms,"Offset V",0,-100,100)
	angle = spin(transforms,"Rotation",0,-360,360)
	angle.suffix = "°"
	factor = spin(transforms,"Scale",1,0.01,100)
	wide_button(transforms,"Apply Transform",_numeric,"Transform selected islands or points around their center.")

	var islands_group := section(sidebar,"Islands")
	var stitching := button_row(islands_group)
	wide_button(stitching,"Stitch",func(): stitch_split(false),"Weld selected UV points or edges.")
	wide_button(stitching,"Split",func(): stitch_split(true),"Separate selected UV points or edges.")
	var aligning := button_row(islands_group)
	wide_button(aligning,"Align Horizontal",func(): align_islands(false))
	wide_button(aligning,"Align Vertical",func(): align_islands(true))
	wide_button(islands_group,"Unwrap Islands",reunwrap_islands,"Unwrap the selected islands again (LSCM) along their current cut, e.g. after Stitch or Split tangled them. Each island keeps its place, size and orientation; other islands are not touched. Selected islands, or all when none selected.").icon = editor_icon("Uv")
	wide_button(islands_group,"Straighten",straighten_islands,"Lay quad islands out on a straight grid: every quad becomes a rectangle and each row or column takes the average length of its edges. Unrolls cones and bent strips for trim sheets; keeps texel density. Selected islands, or all when none selected.").icon = editor_icon("GridContainer")
	wide_button(islands_group,"Flip Mirrored Islands",flip_islands,"Mirror flipped islands along U around each island center. Selected islands, or all when none selected.").icon = editor_icon("MirrorX")
	relax_iterations = spin(islands_group,"Relax Iterations",50,1,500)
	relax_iterations.step = 1
	wide_button(islands_group,"Relax",relax_islands,"Relax interior UV points with fixed borders. Selected islands, or all when none selected.")

	var unwrap_group := section(sidebar,"Projection")
	live_toggle = CheckBox.new()
	live_toggle.text = "On"
	live_toggle.tooltip_text = "Correct UVs while moving, rotating or scaling geometry to preserve texture scale. Automatically map new Extrude, Fill and Bridge faces. Saved per mesh."
	live_toggle.toggled.connect(_set_live_unwrap)
	property(unwrap_group,"Live Unwrap",live_toggle)
	projection_plane = OptionButton.new()
	for label in ["Auto","XY","XZ","YZ"]: projection_plane.add_item(label)
	projection_plane.tooltip_text = "Planar projection in mesh local space. Auto follows the selected surface orientation."
	property(unwrap_group,"Plane",projection_plane)
	wide_button(unwrap_group,"Planar Projection",func(): project("planar"),"Project selected faces (or all if none selected) onto one plane, preserving proportions.")
	hard_angle = spin(unwrap_group,"Hard Edge Angle",30,1,89)
	hard_angle.step = 1
	hard_angle.suffix = "°"
	hard_angle.tooltip_text = "Edges sharper than this split charts; a chart also stops when its polygons turn further than this from its first polygon."
	hard_pack = CheckBox.new()
	hard_pack.text = "On"
	hard_pack.button_pressed = true
	hard_pack.tooltip_text = "On: pack charts into UV 0–1 at one texel density. Off: keep world units (1 unit = 1 UV) for tiling textures."
	property(unwrap_group,"Pack to 0–1",hard_pack)
	hard_rotate = CheckBox.new()
	hard_rotate.text = "On"
	hard_rotate.button_pressed = true
	hard_rotate.tooltip_text = "Allow quarter turns for a tighter pack. Off keeps walls upright (world up = up in UV)."
	property(unwrap_group,"Rotate Charts",hard_rotate)
	wide_button(unwrap_group,"Hard Edge Unwrap",func(): project("hard_edges"),"Split selected faces (or all) into flat charts at hard edges, straighten them (world up = up in UV) and pack them.")
	var projections := GridContainer.new()
	projections.columns = 2
	unwrap_group.add_child(projections)
	var projection_names := {"cube":"Cube","cylinder":"Cylinder","sphere":"Sphere","xz":"Top (XZ)"}
	for kind in ["cube","cylinder","sphere","xz"]:
		wide_button(projections,projection_names[kind],func(): project(kind),"%s projection of selected faces, or all when none selected." % projection_names[kind])
	var optcuts := button_row(unwrap_group)
	wide_button(optcuts,"OptCuts",func(): project("optcuts"),"Automatic seams and unwrap for the whole mesh (triangulates the result).")
	wide_button(optcuts,"Cancel",func(): runner.cancel(),"Cancel a running OptCuts unwrap.")

	var seams_group := section(sidebar,"Seams")
	var seam_buttons := button_row(seams_group)
	wide_button(seam_buttons,"Mark",func(): mark_seams(true),"Mark the edges selected in the 3D viewport as UV seams.")
	wide_button(seam_buttons,"Clear",func(): mark_seams(false),"Clear seams on the edges selected in the 3D viewport.")
	wide_button(seams_group,"Unwrap Seams",func(): project("seams"))
	var hint := Label.new()
	hint.text = "Select edges in 3D, mark them as seams, then unwrap."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color",editor_color("font_readonly_color"))
	seams_group.add_child(hint)

	var density_group := section(sidebar,"Texel Density")
	atlas_width = spin(density_group,"Atlas Width",1024,1,32768)
	atlas_height = spin(density_group,"Atlas Height",1024,1,32768)
	atlas_width.step = 1
	atlas_height.step = 1
	atlas_width.suffix = "px"
	atlas_height.suffix = "px"
	target_density = spin(density_group,"Target",256,0.001,1000000)
	target_density.suffix = "px/u"
	density_label = Label.new()
	density_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	density_label.add_theme_color_override("font_color",editor_color("font_readonly_color"))
	density_group.add_child(density_label)
	var density_buttons := button_row(density_group)
	wide_button(density_buttons,"Get",capture_density,"Measure the selection (or all faces) and use it as the target.")
	wide_button(density_buttons,"Apply",apply_density,"Scale selected islands to the target density.")

	var material_group := section(sidebar,"Material")
	material_id = spin(material_group,"Material ID",0,0,255)
	material_id.step = 1
	wide_button(material_group,"Assign Material ID",assign_material_id,"Assign material ID to selected UV faces, or the selected faces in 3D.")
	return panel

func _create_status_bar() -> Control:
	var margin := MarginContainer.new()
	for side in ["left","right"]: margin.add_theme_constant_override("margin_"+side,8)
	for side in ["top","bottom"]: margin.add_theme_constant_override("margin_"+side,2)
	var bar := HBoxContainer.new()
	margin.add_child(bar)
	status = Label.new()
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	bar.add_child(status)
	var help := Label.new()
	help.text = "W/E/R/Q: Tools · Tab: Box/Brush · F: Frame · Ctrl+Z: Undo"
	help.add_theme_color_override("font_color",editor_color("font_readonly_color"))
	bar.add_child(help)
	return margin

func editor_style(name: String) -> StyleBox:
	var base := editor_plugin.get_editor_interface().get_base_control()
	return base.get_theme_stylebox(name,"EditorStyles") if base.has_theme_stylebox(name,"EditorStyles") else StyleBoxEmpty.new()

func editor_icon(name: String) -> Texture2D:
	var base := editor_plugin.get_editor_interface().get_base_control()
	return base.get_theme_icon(name,"EditorIcons") if base.has_theme_icon(name,"EditorIcons") else null

func editor_color(name: String) -> Color:
	return editor_plugin.get_editor_interface().get_base_control().get_theme_color(name,"Editor")

func section(parent: Control, caption: String) -> VBoxContainer:
	# Foldable header drawn like an inspector section.
	var header := Button.new()
	header.text = caption
	header.toggle_mode = true
	header.button_pressed = true
	header.flat = true
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	header.focus_mode = Control.FOCUS_NONE
	header.icon = editor_icon("GuiTreeArrowDown")
	header.add_theme_font_override("font",editor_plugin.get_editor_interface().get_base_control().get_theme_font("bold","EditorFonts"))
	var background := StyleBoxFlat.new()
	background.bg_color = editor_color("prop_subsection")
	background.set_content_margin_all(4)
	for state in ["normal","hover","pressed","hover_pressed"]: header.add_theme_stylebox_override(state,background)
	parent.add_child(header)
	var margin := MarginContainer.new()
	for side in ["left","right"]: margin.add_theme_constant_override("margin_"+side,6)
	for side in ["top","bottom"]: margin.add_theme_constant_override("margin_"+side,4)
	parent.add_child(margin)
	var contents := VBoxContainer.new()
	margin.add_child(contents)
	header.toggled.connect(func(open: bool):
		margin.visible = open
		header.icon = editor_icon("GuiTreeArrowDown" if open else "GuiTreeArrowRight"))
	return contents

func property(parent: Control, text: String, control: Control) -> Control:
	# Inspector-style row: label on the left half, editor on the right half.
	var row := HBoxContainer.new()
	parent.add_child(row)
	var label := Label.new()
	label.text = text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return control

func button_row(parent: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	parent.add_child(row)
	return row

func wide_button(parent: Control, text: String, callback: Callable, tooltip: String = "") -> Button:
	var button := add_button(parent,text,callback)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.tooltip_text = tooltip
	return button

func tool_button(parent: Control, icon_name: String, tooltip: String, callback: Callable) -> Button:
	var button := Button.new()
	button.theme_type_variation = "FlatButton"
	button.icon = editor_icon(icon_name) if not icon_name.is_empty() else null
	button.tooltip_text = tooltip
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(callback)
	parent.add_child(button)
	return button

func add_button(parent: Control, text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(callback)
	parent.add_child(button)
	return button

func spin(parent: Control, text: String, value: float, low: float, high: float) -> SpinBox:
	var field := SpinBox.new()
	field.min_value = low
	field.max_value = high
	preload("res://addons/modeling_tool/editor/panel.gd").set_step(field,low,0.01)
	field.value = value
	field.select_all_on_focus = true
	property(parent,text,field)
	return field

func _set_selection_method(index: int) -> void:
	selection_method.select(index)
	brush_radius.visible = index == 1
	canvas.set_selection_tool(["box","brush"][index])

func open_mesh(value: EditableMesh) -> void:
	canvas.cancel()
	if busy: runner.cancel()
	node = value
	canvas.bind_mesh(node.poly_mesh)
	live_toggle.set_pressed_no_signal(node.poly_mesh.live_unwrap)
	title = "UV Editor - "+str(node.name)
	_use_material()
	# popup_centered() forces transient mode, which conflicts with always_on_top on Windows.
	var parent_window := editor_plugin.get_editor_interface().get_base_control().get_window()
	position=parent_window.position+(parent_window.size-size)/2
	show()
	grab_focus()
	canvas.grab_focus()

func set_tool(value: String) -> void:
	canvas.cancel()
	canvas.mode = value
	for key in mode_buttons: mode_buttons[key].set_pressed_no_signal(key==value)

func commit(coordinates: Dictionary, before: Dictionary) -> void:
	if not is_instance_valid(node) or not node.is_inside_tree() or node.poly_mesh != canvas.poly:
		status.text = "Mesh is no longer available. Reopen UV Editor."
		return
	var poly := node.poly_mesh
	for id in before:
		var face := poly.get_face(id)
		if face.is_empty() or face.corners.size()!=before[id].size(): return
		for i in face.corners.size():
			if face.corners[i].uv != before[id][i]:
				status.text = "UV changed elsewhere; drag cancelled."
				canvas.rebuild()
				return
	var result := poly.execute("uv_coordinates",PackedInt64Array(coordinates.keys()),{"coordinates":coordinates})
	if not result.ok: status.text=result.error; return
	record_result(result,"UV point transform" if canvas.point_mode else "UV island transform")

func record_result(result: Dictionary, label: String) -> void:
	if not result.ok: status.text=result.error; return
	var poly := node.poly_mesh
	poly.apply_delta(result.delta,false)
	poly.clear_history()
	var undo := editor_plugin.get_undo_redo()
	undo.create_action(label,UndoRedo.MERGE_DISABLE,node)
	undo.add_do_method(poly,"apply_delta",result.delta,true)
	undo.add_undo_method(poly,"apply_delta",result.delta,false)
	undo.commit_action()
	status.text = "UV updated · Ctrl+Z to undo"

func _numeric() -> void:
	canvas.cancel()
	var source := {}
	var center := Vector2.ZERO
	var count := 0
	for id in canvas.selected:
		source[id] = canvas.faces[id]
		for i in source[id].size():
			if not canvas.point_mode or canvas.selected_points.has(Vector2i(id,i)): center+=source[id][i]; count+=1
	if count==0: status.text="Select UV islands or points first"; return
	commit(canvas.mask_transform(Canvas.transformed(source,center/count,Vector2(u.value,v.value),deg_to_rad(angle.value),factor.value),source),source)

func history(redo: bool) -> void:
	canvas.cancel()
	if not is_instance_valid(node) or not node.is_inside_tree(): return
	var manager := editor_plugin.get_undo_redo()
	var stack := manager.get_history_undo_redo(manager.get_object_history_id(node))
	if stack:
		if redo: stack.redo()
		else: stack.undo()

func _window_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed: return
	var focus := gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit or dialog.visible: return
	if event.alt_pressed or event.meta_pressed: return
	if event.ctrl_pressed:
		if event.keycode not in [KEY_Z,KEY_Y]: return
		if not event.echo: history(event.keycode==KEY_Y or event.shift_pressed)
	else:
		if event.keycode not in [KEY_W,KEY_E,KEY_R,KEY_Q,KEY_TAB]: return
		if not event.echo:
			if event.keycode==KEY_TAB: _set_selection_method(1 if canvas.selection_tool=="box" else 0)
			else: set_tool({KEY_W:"move",KEY_E:"rotate",KEY_R:"scale",KEY_Q:"none"}[event.keycode])
	set_input_as_handled()

func load_background(path: String) -> void:
	var resource: Resource
	if path.get_extension().to_lower() in ["tres","res"]:
		resource = load(ProjectSettings.localize_path(path))
	else:
		var image := Image.load_from_file(path)
		if image: resource = ImageTexture.create_from_image(image)
	if resource is Texture2D:
		loaded_material = StandardMaterial3D.new()
		loaded_material.albedo_texture = resource
		canvas.texture = resource
	elif resource is BaseMaterial3D:
		loaded_material = resource
		canvas.texture = resource.albedo_texture
	else:
		status.text = "Choose an image, Texture2D or Standard/ORM material with an albedo texture."
		return
	canvas.fit()
	status.text = "Background loaded. Apply material assigns it to the mesh."

func _use_material() -> void:
	loaded_material = null
	canvas.texture = null
	if is_instance_valid(node) and node.mesh and node.mesh.get_surface_count()>0:
		var material := node.get_active_material(0)
		if material is BaseMaterial3D:
			loaded_material = material
			canvas.texture = material.albedo_texture
	canvas.queue_redraw()

func _apply_material() -> void:
	if not is_instance_valid(node) or not node.is_inside_tree() or not loaded_material:
		status.text = "Load an atlas or material first"
		return
	var material := loaded_material.duplicate() as BaseMaterial3D
	material.uv1_triplanar = false
	material.uv1_world_triplanar = false
	# Embed externally loaded images so scene saving does not depend on their disk path.
	if material.albedo_texture is ImageTexture: material.albedo_texture = ImageTexture.create_from_image(material.albedo_texture.get_image())
	var undo := editor_plugin.get_undo_redo()
	undo.create_action("UV apply material",UndoRedo.MERGE_DISABLE,node)
	undo.add_do_property(node,"material_override",material)
	undo.add_undo_property(node,"material_override",node.material_override)
	undo.commit_action()
	status.text = "Material applied to mesh; triplanar disabled. Ctrl+S in the editor saves the scene."


func _exit_tree() -> void:
	mesh_preview.clear()
	runner.cancel()

func valid_mesh() -> bool:
	return is_instance_valid(node) and node.is_inside_tree() and node.poly_mesh == canvas.poly

func _set_live_unwrap(enabled: bool) -> void:
	if not valid_mesh(): return
	canvas.cancel()
	var undo := editor_plugin.get_undo_redo()
	undo.create_action("Live Unwrap",UndoRedo.MERGE_DISABLE,node)
	undo.add_do_property(node.poly_mesh,"live_unwrap",enabled)
	undo.add_undo_property(node.poly_mesh,"live_unwrap",node.poly_mesh.live_unwrap)
	undo.commit_action()
	status.text="Live Unwrap: correct UVs during 3D transforms and map new faces" if enabled else "Live Unwrap disabled"

func mark_seams(enabled: bool) -> void:
	if busy or not valid_mesh(): return
	var ids := node.poly_mesh.get_selected_edges()
	if ids.is_empty(): status.text="Select edges on this mesh in the 3D editor first"; return
	canvas.cancel()
	record_result(node.poly_mesh.execute("edge_attributes",ids,{"seam":enabled}),"Mark UV seams" if enabled else "Clear UV seams")
	status.text="Seams marked in purple" if enabled else "Selected seams cleared"

func project(kind: String) -> void:
	if busy or not valid_mesh(): return
	canvas.cancel()
	var poly := node.poly_mesh
	var ids := PackedInt64Array(canvas.selected.keys())
	if ids.is_empty(): ids=poly.get_face_ids()
	var result: Dictionary
	if kind == "optcuts":
		var original_node := node
		var snapshot := poly.get_data().duplicate(true)
		busy=true
		status.text="OptCuts is running on the whole mesh…"
		result=await runner.unwrap(get_tree(),poly.to_array_mesh())
		busy=false
		if node != original_node or not valid_mesh() or poly.get_data()!=snapshot:
			status.text="Mesh changed; OptCuts result discarded"
			return
		if not result.ok: status.text=result.error; return
		result=poly.from_array_mesh(result.mesh)
	elif kind == "seams": result=Seams.unwrap(poly)
	elif kind == "xz": result=poly.execute("uv",ids,{"project":true})
	elif kind == "hard_edges":
		hard_angle.apply()
		result=poly.execute("hard_edge_unwrap",PackedInt64Array(canvas.selected.keys()),{"angle":hard_angle.value,"pack":hard_pack.button_pressed,"rotate":hard_rotate.button_pressed})
	else: result=UVProjection.project(poly,ids,kind,["auto","xy","xz","yz"][projection_plane.selected])
	record_result(result,"UV "+kind.capitalize())

func _process(delta: float) -> void:
	if not visible or not is_instance_valid(canvas): return
	density_elapsed += delta
	if density_elapsed<0.2: return
	density_elapsed=0
	if not valid_mesh(): density_label.text="Texel Density: —"; return
	live_toggle.set_pressed_no_signal(node.poly_mesh.live_unwrap)
	var state := [node.global_transform,canvas.texture,atlas_width.value,atlas_height.value,canvas.selected,canvas.preview]
	if density_dirty or state!=density_state:
		update_density()
		density_state=state.duplicate(true)
		density_dirty=false

func update_density() -> void:
	if not valid_mesh(): density_label.text="Texel Density: —"; return
	var resolution := Vector2(atlas_width.value,atlas_height.value)
	atlas_width.editable=canvas.texture==null; atlas_height.editable=canvas.texture==null
	if canvas.texture:
		resolution=canvas.texture.get_size()
		atlas_width.value=resolution.x; atlas_height.value=resolution.y
	var ids: Array = canvas.selected.keys() if not canvas.selected.is_empty() else canvas.faces.keys()
	var measured := Seams.density(node.poly_mesh,ids,node.global_transform,resolution,canvas.preview)
	density_label.text="Texel Density: %.2f px/unit · %s" % [measured.density,"Selected" if not canvas.selected.is_empty() else "All faces"]

func _sync_mesh_selection() -> void:
	if not valid_mesh(): return
	if editor_plugin.target!=node:
		var selection:=editor_plugin.get_editor_interface().get_selection()
		selection.clear(); selection.add_node(node)
	if editor_plugin.panel.mode!="face": editor_plugin.panel.set_mode("face")
	if not editor_plugin.edit_polygons: editor_plugin._set_polygon_editing(true)
	node.poly_mesh.select("face",PackedInt64Array(canvas.selected.keys()),false)
	editor_plugin._refresh()

func capture_density() -> void:
	if not valid_mesh(): return
	canvas.cancel()
	update_density()
	var ids: Array=canvas.selected.keys() if not canvas.selected.is_empty() else canvas.faces.keys()
	var measured:=Seams.density(node.poly_mesh,ids,node.global_transform,Vector2(atlas_width.value,atlas_height.value))
	if measured.density<=0: status.text="Source has zero UV or surface area"; return
	target_density.value=measured.density
	status.text="Captured %.2f px/unit. Select destination islands, then Apply TD." % measured.density

func apply_density() -> void:
	if busy or not valid_mesh(): return
	canvas.cancel(); target_density.apply(); update_density()
	record_result(EditOps.apply_density(node.poly_mesh,canvas.islands,canvas.selected,node.global_transform,Vector2(atlas_width.value,atlas_height.value),target_density.value),"Apply Texel Density")

func stitch_split(split: bool) -> void:
	if busy or not valid_mesh(): return
	canvas.cancel()
	record_result(EditOps.stitch_split(node.poly_mesh,canvas.selected_points,canvas.selected_uv_edges,split),"UV Split" if split else "UV Stitch")

func align_islands(vertical: bool) -> void:
	if busy or not valid_mesh(): return
	canvas.cancel(); update_density()
	record_result(EditOps.align_islands(node.poly_mesh,canvas.islands,canvas.selected,node.global_transform,Vector2(atlas_width.value,atlas_height.value),vertical),"Align UV Vertical" if vertical else "Align UV Horizontal")

func reunwrap_islands() -> void:
	if busy or not valid_mesh(): return
	canvas.cancel()
	record_result(EditOps.reunwrap_islands(node.poly_mesh,canvas.selected,node.global_transform),"Unwrap UV islands")

func straighten_islands() -> void:
	if busy or not valid_mesh(): return
	canvas.cancel()
	record_result(EditOps.straighten_islands(node.poly_mesh,canvas.selected,node.global_transform),"Straighten UV islands")

func relax_islands() -> void:
	if busy or not valid_mesh(): return
	canvas.cancel(); relax_iterations.apply()
	var result: Dictionary=preload("res://addons/modeling_tool/editor/uv_relax.gd").apply(node.poly_mesh,canvas.islands,canvas.selected,node.global_transform,int(relax_iterations.value))
	record_result(result,"Relax UV islands")

func flip_islands() -> void:
	if busy or not valid_mesh(): return
	canvas.cancel()
	record_result(EditOps.flip_islands(node.poly_mesh,canvas.islands,canvas.selected),"Flip UV islands")

func assign_material_id() -> void:
	if busy or not valid_mesh(): return
	canvas.cancel(); material_id.apply()
	var ids:=PackedInt64Array(canvas.selected.keys())
	if ids.is_empty(): ids=node.poly_mesh.get_selected_faces()
	if ids.is_empty(): status.text="Select UV islands or polygons to assign a material ID"; return
	record_result(node.poly_mesh.execute("material",ids,{"material":int(material_id.value)}),"Assign Material ID")
