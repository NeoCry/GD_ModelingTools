@tool
extends VBoxContainer
## Modeling dock. Laid out like the Inspector: foldable sections with label / field
## rows. Colors, fonts and icons come from the editor theme, with fallbacks for the
## runtime demo where no editor theme exists.

signal operation(name: String, options: Dictionary)
signal mode_changed(mode: String)
signal mode_activated()
signal command(name: String)
# Every status message; the editor plugin shows them in the 3D viewport.
signal reported(message: String, error: bool)
var mode := "face"
var xray := false
var status: Label
var stats: Label
var amount: SpinBox
var amount_auto: CheckBox
var segments: SpinBox
var components: Array[SpinBox] = []
var pick_radius := 20.0
var hover_hint: Label
var selection_rows: Array[Control] = []
var mode_buttons: Array[Button] = []
var mode_icons := {}
var compact_selection := false
var tool_buttons := {}
var sections := {}
var section_buttons := {}
var brush_radius: SpinBox
var extrude_axis: OptionButton
var extrude_even: CheckBox
var inset_individual: CheckBox
var work_grid_step: SpinBox
var work_grid_align: CheckBox

var paint_button: Button
var paint_color: ColorPickerButton
var paint_radius: SpinBox
var paint_strength: SpinBox
var paint_through: CheckBox
var paint_show_colors: CheckBox
var paint_channels: Array[CheckBox]=[]
var convert_mesh_button: Button

# Tools that stay active until applied or cancelled; their buttons show a pressed state.
const MODAL_TOOLS := ["move","rotate","scale","inset","bevel","loop_cut","split_edge","knife","target_weld","slide_edge","slide_vertex","extrude_normals","pivot","brush"]

func _ready() -> void:
	custom_minimum_size.x = 300
	add_theme_constant_override("separation", 2)
	_create_selection_rows()

	var create := section("Create", "", true)
	var primitives := GridContainer.new()
	primitives.name = "Primitives"
	primitives.columns = 3
	create.add_child(primitives)
	for kind in ["box","cylinder","pyramid","plane","sphere"]:
		var action: String = "preview_"+("cube" if kind=="box" else kind) if Engine.is_editor_hint() else "new" if kind=="box" else "new_"+kind
		var primitive_button := button(primitives,kind.capitalize(),func(): command.emit(action))
		primitive_button.name = kind.capitalize()
		primitive_button.icon = load_icon(kind)
		primitive_button.tooltip_text = "Add a %s. Adjust its size in the preview, then press Enter." % kind
		primitive_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		primitive_button.add_theme_constant_override("icon_max_width",16)
	button(create,"Import Selected",func(): command.emit("import"),"Load").tooltip_text = "Convert the selected MeshInstance3D into an editable copy. The original is hidden; Undo restores it."

	var edit := section("Edit", "", true)
	var amount_row := HBoxContainer.new()
	property(edit,"Amount",amount_row)
	amount = spin(amount_row,-1000,1000,0.05,0.25)
	amount.tooltip_text = "Distance for Extrude, Inset and Bevel; ratio for Split Edge."
	amount_auto = CheckBox.new()
	amount_auto.text = "Auto"
	amount_auto.button_pressed = true
	amount_auto.tooltip_text = "Pick the amount from the selected geometry. Bevel and Inset also stop at the largest valid value."
	amount_row.add_child(amount_auto)
	segments = property_spin(edit,"Bevel Segments",1,32,1,1)
	extrude_axis = OptionButton.new()
	for label_text in ["Normal","X","Y","Z"]: extrude_axis.add_item(label_text)
	property(edit,"Extrude Direction",extrude_axis)
	extrude_even = check_box(edit,"Offset Even","Extrude Along Normals keeps the shell thickness constant.")
	inset_individual = check_box(edit,"Inset Individual","Inset each selected polygon separately instead of the region border.")
	brush_radius = property_spin(edit,"Brush Radius",5,500,5,60)
	brush_radius.suffix = "px"
	var clean_distance := property_spin(edit,"Clean Distance",0.000001,10,0.001,0.005)
	clean_distance.tooltip_text = "Clean Up welds vertices closer than this, in local mesh units"
	var tools := GridContainer.new()
	tools.columns = 2
	edit.add_child(tools)
	for item in [["Extrude","extrude","E"],["Extrude Along Normals","extrude_normals",""],["Inset","inset","I"],["Bevel","bevel","B"],["Loop Cut","loop_cut","Ctrl+R"],["Split Edge","split_edge",""],["Knife","knife","K"],["Dissolve","dissolve",""],["Weld","target_weld",""],["Weld All","weld",""],["Collapse","collapse",""],["Bridge","bridge",""],["Fill","fill",""],["Triangulate","triangulate",""],["Untriangulate","untriangulate",""],["Subdivide","subdivide",""],["Circle","circle",""],["Connect","connect","J"],["Extrude Along Path","extrude_path",""],["Edges → Path","edges_to_path",""],["Slide Edge","slide_edge",""],["Slide Vertex","slide_vertex",""],["Delete","delete","Delete"]]:
		var tool_button := button(tools,item[0],func(): run(item[1]))
		if item[2] != "": tool_button.tooltip_text = "%s (%s)" % [item[0],item[2]]
		tool_buttons[item[1]] = tool_button
	tool_buttons.erase("delete")
	button(tools,"Clean Up",func(): clean_distance.apply(); operation.emit("cleanup",{"distance":clean_distance.value})).tooltip_text = "Weld vertices closer than Clean Distance (zero-length edges, open seams), remove broken polygons, wire edges and loose vertices."
	tool_buttons["bevel"].tooltip_text = "Bevel (B)\nEdge mode: chamfer or round the selected edges.\nVertex mode: split each vertex into one point per edge and close the opening (Segments > 1 rounds it; on a flat surface the opening is a circle)."
	tool_buttons["connect"].tooltip_text = "Connect (J)
Join selected vertices with a new edge across the polygon they share. With more than two vertices on one polygon, neighbours along its border are joined in turn."
	tool_buttons["circle"].tooltip_text = "Arrange a closed loop evenly on a best-fit circle (LoopTools Circle).\nSelect a vertex or edge loop, or polygons: their border becomes the circle. Subdivide first for a rounder result."
	tool_buttons["extrude_path"].tooltip_text = "Sweep the selected polygons (or open border edges) along a Path3D you pick.\nThe path starts at the selection and turns to its normal (Align); Segments, Twist and Taper are adjusted in the preview. Enter applies, Esc cancels."
	tool_buttons["edges_to_path"].tooltip_text = "Edge mode: turn the selected edge chains or loops into Path3D nodes (straight segments through the vertices).\nShift+click: a smooth curve through the vertices.\nUse them for Extrude Along Path, the Curve modifier or an Array along a path."
	tool_buttons["bridge"].tooltip_text = "Edge mode: bridge two closed edge loops.\nPolygon mode: replace two selected polygons or regions with a connecting tube."
	var selecting := GridContainer.new()
	selecting.columns = 2
	edit.add_child(selecting)
	tool_buttons["brush"] = button(selecting,"Polygon Brush",func(): run("brush"))
	tool_buttons["brush"].tooltip_text = "Paint a polygon selection in the viewport."
	button(selecting,"Select Connected",func(): command.emit("connected")).tooltip_text = "Extend the selection to every connected part of the mesh"
	button(selecting,"Select All",func(): command.emit("all")).tooltip_text = "Select all elements of the current mode (A)"
	button(selecting,"Invert",func(): command.emit("invert")).tooltip_text = "Invert the selection in the current mode"
	var history := HBoxContainer.new()
	edit.add_child(history)
	button(history,"Undo",func(): command.emit("undo")).tooltip_text = "Undo (Ctrl+Z)"
	button(history,"Redo",func(): command.emit("redo")).tooltip_text = "Redo (Ctrl+Shift+Z)"

	var transform_section := section("Transform", "", true)
	var vector := HBoxContainer.new()
	vector.tooltip_text = "Vector for Move / Rotate / Scale buttons"
	transform_section.add_child(vector)
	for axis in ["x","y","z"]:
		var field := spin(vector,-10000,10000,0.1,0)
		field.prefix = axis
		field.custom_minimum_size.x = 0
		components.append(field)
	var transform_buttons := HBoxContainer.new()
	transform_section.add_child(transform_buttons)
	tool_buttons["move"] = button(transform_buttons,"Move",func(): run("move"),"ToolMove")
	tool_buttons["move"].tooltip_text = "Move by Vector, or switch the gizmo to Move (W)."
	tool_buttons["rotate"] = button(transform_buttons,"Rotate",func(): run("rotate"),"ToolRotate")
	tool_buttons["rotate"].tooltip_text = "Rotate by Vector in degrees, or switch the gizmo to Rotate (R)."
	tool_buttons["scale"] = button(transform_buttons,"Scale",func(): run("scale"),"ToolScale")
	tool_buttons["scale"].tooltip_text = "Scale by 1 + Vector, or switch the gizmo to Scale (S)."
	var mirror_row := HBoxContainer.new()
	transform_section.add_child(mirror_row)
	for axis in 3:
		button(mirror_row,"Mirror "+["X","Y","Z"][axis],func(): command.emit("mirror_"+str(axis))).tooltip_text = "Mirror the whole mesh across its local pivot."

	var normal_section := section("Normals")
	var normals := GridContainer.new()
	normals.columns = 2
	normal_section.add_child(normals)
	button(normals, "Flat", func(): operation.emit("shade", {"smooth": false}))
	button(normals, "Smooth", func(): operation.emit("shade", {"smooth": true}))
	button(normals, "Recalculate", func(): operation.emit("normals", {}))
	button(normals, "Mark Sharp", func(): operation.emit("edge_attributes", {"sharp": true}))
	button(normals, "Clear Sharp", func(): operation.emit("edge_attributes", {"sharp": false}))
	tool_buttons["flip"] = button(normals,"Flip Faces",func(): run("flip"))

	var uv_section := section("UV")
	uv_section.get_parent().visible = Engine.is_editor_hint()
	button(uv_section,"Open UV Editor",func(): command.emit("uv_editor"))
	button(uv_section,"Hard Edge Unwrap",func(): command.emit("uv_hard_edges")).tooltip_text = "Split the selected polygons (or the whole mesh) into flat charts at hard edges, straighten and pack them into UV 0–1."

	var paint_section := section("Vertex Paint")
	paint_show_colors = check_box(paint_section,"Show Colors","Show or hide vertex colors on the selected mesh without changing painted data. Standard/ORM materials.")
	paint_show_colors.button_pressed = true
	paint_show_colors.toggled.connect(func(_enabled): command.emit("vertex_paint_visibility"))
	paint_color = ColorPickerButton.new()
	paint_color.color = Color.WHITE
	paint_color.custom_minimum_size.y = 24
	property(paint_section,"Color",paint_color)
	var channel_row := HBoxContainer.new()
	property(paint_section,"Channels",channel_row)
	for channel_name in ["R","G","B","A"]:
		var channel := CheckBox.new()
		channel.text = channel_name
		channel.button_pressed = true
		channel_row.add_child(channel)
		paint_channels.append(channel)
	paint_radius = property_spin(paint_section,"Radius",2,500,1,60)
	paint_radius.suffix = "px"
	paint_strength = property_spin(paint_section,"Strength",0.01,1,0.01,1)
	paint_through = check_box(paint_section,"Paint Through","Also paint vertices hidden behind other polygons.")
	var paint_actions := HBoxContainer.new()
	paint_section.add_child(paint_actions)
	paint_button = button(paint_actions,"Paint",func(): command.emit("vertex_paint"),"Edit")
	paint_button.toggle_mode = true
	paint_button.tooltip_text = "Paint vertex colors in the 3D viewport."
	button(paint_actions,"Fill",func(): command.emit("vertex_paint_fill")).tooltip_text = "Fill the selection, or the whole mesh, with Color."

	var modifier_section := section("Modifiers")
	var stack_button := button(modifier_section,"Open Modifier Stack",func(): command.emit("modifier_stack"),"Modifiers")
	stack_button.tooltip_text = "Non-destructive modifiers of the selected EditableMesh in a separate window: Subdivide, Deform (bend, taper, twist), Curve, Lattice, Array, Boolean (with n-gons), Mirror (model one half) and Normals."
	var decal_button := button(modifier_section,"Mesh Decals",func(): command.emit("decals"),"Decal")
	decal_button.tooltip_text = "Place mesh decals on surfaces and edit their projection and material in a separate window. Mesh decals follow the surface, work in every renderer and export as geometry."

	# Moved into the 3D toolbar dropdowns by the editor plugin.
	var work_section := section("Working Grid")
	button(work_section,"Grid from Selected Face",func(): command.emit("grid_face"))
	button(work_section,"Place Selected on Grid",func(): command.emit("grid_place"))
	button(work_section,"Hide Grid",func(): command.emit("grid_clear"))
	work_grid_step = property_spin(work_section,"Step",0.001,1000,0.1,1.0)
	work_grid_step.value_changed.connect(func(_value): command.emit("grid_settings"))
	work_grid_align = check_box(work_section,"Align to Normal","")
	work_grid_align.toggled.connect(func(_value): command.emit("grid_settings"))
	var pivot_section := section("Pivot Modifications","Pivot")
	var pivots := HBoxContainer.new()
	pivot_section.add_child(pivots)
	button(pivots,"Mass Center",func(): command.emit("pivot_mass")).tooltip_text = "Move the pivot to the center of mass."
	button(pivots,"World Origin",func(): command.emit("pivot_origin"))
	var pivot_kind := OptionButton.new()
	for kind_label in ["Vertex","Edge","Polygon"]: pivot_kind.add_item(kind_label)
	property(pivot_section,"Snap Target",pivot_kind)
	pivot_kind.item_selected.connect(func(index): command.emit("pivot_kind_"+["vertex","edge","face"][index]))
	tool_buttons["pivot"] = button(pivot_section,"Place Pivot",func(): run("pivot"))

	var object_section := section("Object", "", true)
	var object_actions := HBoxContainer.new()
	object_section.add_child(object_actions)
	button(object_actions,"Separate Polygons",func(): command.emit("separate")).tooltip_text = "Move the selected polygons into a new EditableMesh."
	button(object_actions,"Merge Objects",func(): command.emit("merge_objects")).tooltip_text = "Merge the selected EditableMesh nodes into one."
	var save_row := HBoxContainer.new()
	object_section.add_child(save_row)
	button(save_row,"Save PolyMesh",func(): command.emit("save"),"Save").tooltip_text = "Save the editable PolyMesh resource (.tres)."
	button(save_row,"Export Mesh",func(): command.emit("export"),"ArrayMesh").tooltip_text = "Export the generated ArrayMesh."

	for title in MODAL_TOOLS:
		if tool_buttons.has(title): tool_buttons[title].toggle_mode = Engine.is_editor_hint()
	var separator := HSeparator.new()
	add_child(separator)
	convert_mesh_button = button(self,"Convert to MeshInstance3D",func(): command.emit("convert_mesh"),"MeshInstance3D")
	convert_mesh_button.tooltip_text = "Bake the selected EditableMesh into a regular MeshInstance3D in this scene. Undo restores polygon editing."
	convert_mesh_button.disabled = true
	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.text = "Click selects · Shift adds/removes\nTransforms use local axes and selection center."
	status.add_theme_color_override("font_color", theme_color("font_readonly_color", Color("91a7bf")))
	add_child(status)

func _create_selection_rows() -> void:
	# In the editor these controls move into the 3D toolbar Selection menu.
	var row := HBoxContainer.new()
	selection_rows.append(row)
	add_child(row)
	var group := ButtonGroup.new()
	for item in [["Vertex · 1", "vertex"], ["Edge · 2", "edge"], ["Polygons · 3", "face"]]:
		var b := button(row, item[0], func(): set_mode(item[1]))
		var icon_name: String = "polygon" if item[1] == "face" else item[1]
		b.icon = load_icon(icon_name)
		mode_icons[item[1]] = b.icon
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = item[1] == mode
		b.set_meta("selection_mode", item[1])
		mode_buttons.append(b)
	var selection_row := HBoxContainer.new()
	selection_rows.append(selection_row)
	add_child(selection_row)
	button(selection_row, "All · A", func(): command.emit("all"))
	button(selection_row, "None", func(): command.emit("none"))
	button(selection_row, "Invert", func(): command.emit("invert"))
	button(selection_row, "Connected", func(): command.emit("connected"))
	var check := CheckButton.new()
	check.text = "X-ray"
	check.toggled.connect(func(value): xray = value; mode_changed.emit(mode))
	selection_row.add_child(check)
	var picking_row := HBoxContainer.new()
	selection_rows.append(picking_row)
	add_child(picking_row)
	var picking_label := Label.new()
	picking_label.text = "Pick radius (px)"
	picking_row.add_child(picking_label)
	var picking_spin := spin(picking_row, 4, 48, 1, pick_radius)
	picking_spin.value_changed.connect(func(value): pick_radius = value; mode_changed.emit(mode))
	hover_hint = Label.new()
	hover_hint.text = "Hover a vertex or edge to preview selection"
	add_child(hover_hint)
	stats = Label.new()
	stats.text = "Select an EditableMesh or create a cube"
	stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(stats)

func section(title: String, caption: String = "", open: bool = false) -> VBoxContainer:
	# Foldable header drawn like an Inspector section. `title` is the lookup key;
	# the body stays a direct child of the group so the plugin can move it.
	var group := VBoxContainer.new()
	group.name = title.replace(" ", "")
	group.add_theme_constant_override("separation", 4)
	add_child(group)
	var header := Button.new()
	header.text = caption if caption != "" else title
	header.toggle_mode = true
	header.flat = true
	header.focus_mode = Control.FOCUS_NONE
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	header.tooltip_text = "Expand / collapse " + header.text
	if has_theme_font("bold","EditorFonts"): header.add_theme_font_override("font",get_theme_font("bold","EditorFonts"))
	var background := StyleBoxFlat.new()
	background.bg_color = theme_color("prop_subsection", Color(1,1,1,0.06))
	background.set_content_margin_all(4)
	for state in ["normal","hover","pressed","hover_pressed"]: header.add_theme_stylebox_override(state,background)
	group.add_child(header)
	var body := VBoxContainer.new()
	body.visible = open
	group.add_child(body)
	header.button_pressed = open
	_update_header(header, open)
	header.toggled.connect(func(expanded):
		body.visible = expanded
		_update_header(header, expanded))
	sections[title] = body
	section_buttons[title] = header
	return body

func _update_header(header: Button, expanded: bool) -> void:
	var arrow := theme_icon("GuiTreeArrowDown" if expanded else "GuiTreeArrowRight")
	header.icon = arrow
	if arrow == null: header.text = ("▾ " if expanded else "▸ ") + header.text.trim_prefix("▾ ").trim_prefix("▸ ")

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

func property_spin(parent: Control, text: String, low: float, high: float, step: float, initial: float) -> SpinBox:
	var field := SpinBox.new()
	field.min_value = low
	field.max_value = high
	set_step(field, low, step)
	field.value = initial
	field.select_all_on_focus = true
	property(parent, text, field)
	return field

func check_box(parent: Control, text: String, tooltip: String) -> CheckBox:
	var box := CheckBox.new()
	box.text = "On"
	box.tooltip_text = tooltip
	property(parent, text, box)
	return box

func hint(parent: Control, text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", theme_color("font_readonly_color", Color("91a7bf")))
	parent.add_child(label)
	return label

func button(parent: Control, text: String, callback: Callable, icon_name: String = "") -> Button:
	var result := Button.new()
	result.text = text
	result.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if icon_name != "": result.icon = theme_icon(icon_name)
	result.pressed.connect(callback)
	parent.add_child(result)
	return result

func spin(parent: Control, low: float, high: float, step: float, initial: float) -> SpinBox:
	var result := SpinBox.new()
	result.min_value = low
	result.max_value = high
	set_step(result, low, step)
	result.value = initial
	result.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(result)
	return result

static func set_step(field: Range, low: float, step: float) -> void:
	# Range snaps to min_value + k × step, so min 0.001 / step 0.1 would turn 2 into 2.001.
	# Keep the arrow increment, but snap values to the minimum's precision instead.
	field.step = step
	if step > 0 and not is_equal_approx(snappedf(low, step), low):
		field.step = absf(low)
		if field is SpinBox: field.custom_arrow_step = step

func theme_color(name: String, fallback: Color) -> Color:
	return get_theme_color(name, "Editor") if has_theme_color(name, "Editor") else fallback

func theme_icon(name: String) -> Texture2D:
	return get_theme_icon(name, "EditorIcons") if has_theme_icon(name, "EditorIcons") else null

func set_active_tool(active: String) -> void:
	# Modal tools show the editor's pressed state while they run.
	for name in tool_buttons:
		var tool_button: Button = tool_buttons[name]
		if tool_button.toggle_mode and tool_button.button_pressed != (name == active):
			tool_button.set_pressed_no_signal(name == active)

func set_mode(value: String) -> void:
	mode = value
	for child in mode_buttons:
		child.set_pressed_no_signal(child.get_meta("selection_mode") == value)
	mode_activated.emit()
	mode_changed.emit(value)

func run(name: String) -> void:
	var vector := Vector3(components[0].value, components[1].value, components[2].value)
	operation.emit(name, {"amount": amount.value, "width": amount.value, "distance": amount.value,
		"individual":inset_individual.button_pressed if name=="inset" else false, "offset_even":extrude_even.button_pressed, "axis": extrude_axis.selected-1, "segments": int(segments.value), "ratio": clampf(amount.value, 0.01, 0.99), "vector": vector, "auto": amount_auto.button_pressed})

func show_amount(value: float) -> void:
	# Display the amount picked by Auto without triggering edits.
	amount.set_value_no_signal(value)

func report(message: String, error: bool = false) -> void:
	status.text = message
	reported.emit(message, error)
	status.add_theme_color_override("font_color", theme_color("error_color", Color("ff8f85")) if error else theme_color("font_readonly_color", Color("91c9b2")))

func show_hover(selection_mode: String, id: int) -> void:
	if not is_instance_valid(hover_hint): return
	hover_hint.text = "%s #%d · click to select / Shift to toggle" % [selection_mode.capitalize(), id] if id >= 0 else ("Hover to select" if compact_selection else "Hover a vertex or edge to preview selection")

func update_stats(poly: PolyMesh) -> void:
	if not is_instance_valid(stats): return
	if not poly:
		stats.text = "Select an EditableMesh or import a MeshInstance3D"
		return
	var counts := poly.get_statistics()
	var selection = poly.call("get_selected_" + ("vertices" if mode == "vertex" else "edges" if mode == "edge" else "faces"))
	if compact_selection:
		stats.text = "%dv / %de / %df | %d selected" % [counts.vertices,counts.edges,counts.faces,selection.size()]
		return
	stats.text = "%d vertices  ·  %d edges  ·  %d faces\n%d selected / %s mode" % [counts.vertices, counts.edges, counts.faces, selection.size(), mode]

func move_selection_to_toolbar(toolbar: VBoxContainer) -> void:
	compact_selection = true
	var controls := HBoxContainer.new()
	toolbar.add_child(controls)
	for row in selection_rows: row.reparent(controls)
	var info := HBoxContainer.new()
	toolbar.add_child(info)
	stats.reparent(info)
	stats.autowrap_mode = TextServer.AUTOWRAP_OFF
	stats.add_theme_font_size_override("font_size",12)
	hover_hint.reparent(info)
	hover_hint.custom_minimum_size.x = 160
	hover_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hover_hint.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	stats.text = "Select an EditableMesh"

func load_icon(icon_name: String) -> Texture2D:
	var image := Image.new()
	if image.load_svg_from_string(FileAccess.get_file_as_string("res://addons/modeling_tool/icons/"+icon_name+".svg")) != OK: return null
	return ImageTexture.create_from_image(image)
