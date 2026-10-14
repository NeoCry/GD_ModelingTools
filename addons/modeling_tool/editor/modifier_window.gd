@tool
extends Window
## Modifier stack of the selected EditableMesh: Subdivide, Deform, Curve, Lattice,
## Array, Boolean and Mirror. It follows the editor selection and empties when the
## object is deselected or deleted. Every change is an editor undo step.

var editor_plugin: EditorPlugin
var node: EditableMesh
var list: VBoxContainer
var status: Label
var object_label: Label
var add_menu: MenuButton
var structure: Array = []
var updaters: Array[Callable] = []
var folded := {}

const KINDS := ["Subdivide", "Deform", "Curve", "Lattice", "Array", "Boolean", "Mirror", "Normals", "Weighted Normal"]
const ICONS := {"Subdivide": "MeshInstance3D", "Deform": "CurveTexture", "Curve": "Path3D", "Lattice": "GridMap", "Array": "GridContainer", "Boolean": "CSGCombiner3D", "Mirror": "MirrorX", "Normals": "StandardMaterial3D", "Weighted Normal": "StandardMaterial3D"}

func _ready() -> void:
	# A Window is visible by default and would appear at (0, 0) as soon as it enters
	# the tree, with its title bar above the screen edge; it opens via open_mesh().
	visible = false
	always_on_top = true
	title = "Modifier Stack"
	size = Vector2i(440, 680)
	min_size = Vector2i(380, 320)
	close_requested.connect(hide)
	var background := PanelContainer.new()
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.add_theme_stylebox_override("panel", editor_style("Background"))
	add_child(background)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 0)
	background.add_child(root)
	var toolbar := PanelContainer.new()
	toolbar.add_theme_stylebox_override("panel", editor_style("ContextualToolbar"))
	root.add_child(toolbar)
	var bar := HBoxContainer.new()
	toolbar.add_child(bar)
	add_menu = MenuButton.new()
	add_menu.text = "Add Modifier"
	add_menu.icon = editor_icon("Add")
	add_menu.flat = false
	for index in KINDS.size(): add_menu.get_popup().add_icon_item(editor_icon(ICONS[KINDS[index]]), KINDS[index], index)
	add_menu.get_popup().id_pressed.connect(func(id): add_modifier(KINDS[id]))
	bar.add_child(add_menu)
	var apply_all := Button.new()
	apply_all.text = "Apply All"
	apply_all.tooltip_text = "Bake every enabled modifier into the mesh, top to bottom, and remove them."
	apply_all.pressed.connect(apply_all_modifiers)
	bar.add_child(apply_all)
	object_label = Label.new()
	object_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	object_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	object_label.clip_text = true
	bar.add_child(object_label)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]: margin.add_theme_constant_override("margin_" + side, 6)
	scroll.add_child(margin)
	list = VBoxContainer.new()
	list.add_theme_constant_override("separation", 6)
	margin.add_child(list)
	var status_bar := PanelContainer.new()
	status_bar.add_theme_stylebox_override("panel", editor_style("ContextualToolbar"))
	root.add_child(status_bar)
	status = Label.new()
	status.clip_text = true
	status_bar.add_child(status)

# ---- Binding ------------------------------------------------------------------

func open_mesh(target: EditableMesh) -> void:
	bind(target)
	# popup_centered() forces transient mode, which conflicts with always_on_top on
	# Windows: the window lost its frame and stuck to the screen corner. Center it
	# over the editor by hand, as the UV Editor does.
	if not visible:
		var parent_window := editor_plugin.get_editor_interface().get_base_control().get_window()
		var at := parent_window.position + (parent_window.size - size) / 2
		# Keep the whole window, title bar included, on the usable screen area.
		if not parent_window.gui_embed_subwindows:
			var screen := DisplayServer.screen_get_usable_rect(parent_window.current_screen)
			var title_bar := 40
			at.x = clampi(at.x, screen.position.x, maxi(screen.position.x, screen.end.x - size.x))
			at.y = clampi(at.y, screen.position.y + title_bar, maxi(screen.position.y + title_bar, screen.end.y - size.y))
		position = at
		show()
	grab_focus()

func bind(target: EditableMesh) -> void:
	if node == target:
		refresh()
		return
	if is_instance_valid(node):
		if node.modifiers_evaluated.is_connected(refresh): node.modifiers_evaluated.disconnect(refresh)
		if node.tree_exited.is_connected(_node_left): node.tree_exited.disconnect(_node_left)
	node = target
	if is_instance_valid(node):
		node.modifiers_evaluated.connect(refresh)
		node.tree_exited.connect(_node_left)
	structure = []
	refresh()

# The object was deleted (or its scene closed): show an empty stack.
func _node_left() -> void:
	bind(null)

func modifiers() -> Array:
	return node.modifiers if is_instance_valid(node) else []

func refresh() -> void:
	if not is_instance_valid(list): return
	if not is_instance_valid(node) or not node.is_inside_tree():
		object_label.text = "No EditableMesh selected"
		title = "Modifier Stack"
		rebuild_cards()
		return
	object_label.text = node.name
	title = "Modifier Stack — %s" % node.name
	var current: Array = modifiers().map(func(m): return m.get_instance_id() if m else 0)
	if current != structure: rebuild_cards()
	else:
		for updater in updaters: updater.call()

func rebuild_cards() -> void:
	for child in list.get_children():
		list.remove_child(child)
		child.queue_free()
	updaters.clear()
	structure = modifiers().map(func(m): return m.get_instance_id() if m else 0)
	if not is_instance_valid(node) or not node.is_inside_tree():
		hint(list, "Select an EditableMesh to see and edit its modifiers.")
		return
	if modifiers().is_empty():
		hint(list, "No modifiers. Add Modifier: Subdivide (whole mesh, smooth or simple), Deform (bend, taper, twist), Curve (follow a Path3D), Lattice (deform with a cage), Array (line, circle, grid, path), Boolean (union, difference, intersection with another object), Mirror (model one half, the other is mirrored) or Normals (fix the shading at the end of the stack). The mesh itself stays editable; Apply bakes a modifier into it.")
	for index in modifiers().size():
		var modifier: MeshModifier = modifiers()[index]
		if modifier: card(index, modifier)
	for updater in updaters: updater.call()

# ---- Cards --------------------------------------------------------------------

func card(index: int, modifier: MeshModifier) -> void:
	var kind: String = modifier.get_kind()
	var frame := PanelContainer.new()
	frame.add_theme_stylebox_override("panel", editor_style("PanelForeground"))
	list.add_child(frame)
	var box := VBoxContainer.new()
	frame.add_child(box)
	var header := HBoxContainer.new()
	var header_panel := PanelContainer.new()
	var header_style := StyleBoxFlat.new()
	header_style.bg_color = editor_color("prop_subsection")
	header_style.set_content_margin_all(3)
	header_panel.add_theme_stylebox_override("panel", header_style)
	header_panel.add_child(header)
	box.add_child(header_panel)
	var id := modifier.get_instance_id()
	var fold := icon_button(header, "GuiTreeArrowRight" if folded.get(id, false) else "GuiTreeArrowDown", "Collapse or expand")
	var enabled := CheckBox.new()
	enabled.tooltip_text = "Enabled"
	enabled.toggled.connect(func(on): set_property(modifier, "enabled", on))
	header.add_child(enabled)
	var label := Label.new()
	label.text = kind
	label.add_theme_font_override("font", editor_plugin.get_editor_interface().get_base_control().get_theme_font("bold", "EditorFonts"))
	var icon := TextureRect.new()
	icon.texture = editor_icon(ICONS.get(kind, "Node"))
	icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	header.add_child(icon)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(label)
	var in_edit: Button = null
	if modifier.affects_geometry():
		in_edit = icon_button(header, "EditPivot" if has_icon("EditPivot") else "Edit", "Show in Edit Mode: also display this modifier while polygons are edited (the selection cage stays on the base mesh).")
		in_edit.toggle_mode = true
		in_edit.toggled.connect(func(on): set_property(modifier, "show_in_edit", on))
	icon_button(header, "MoveUp", "Move up").pressed.connect(func(): move(index, -1))
	icon_button(header, "MoveDown", "Move down").pressed.connect(func(): move(index, 1))
	if modifier.affects_geometry():
		var apply := Button.new()
		apply.text = "Apply"
		apply.tooltip_text = "Bake this modifier into the mesh and remove it from the stack."
		apply.pressed.connect(func(): apply_modifier(index))
		header.add_child(apply)
	icon_button(header, "Remove", "Remove modifier").pressed.connect(func(): remove(index))
	var error := Label.new()
	error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	error.add_theme_color_override("font_color", editor_color("error_color"))
	box.add_child(error)
	var body := VBoxContainer.new()
	var body_margin := MarginContainer.new()
	for side in ["left", "right"]: body_margin.add_theme_constant_override("margin_" + side, 6)
	body_margin.add_theme_constant_override("margin_bottom", 4)
	body_margin.add_child(body)
	box.add_child(body_margin)
	body_margin.visible = not folded.get(id, false)
	fold.pressed.connect(func():
		folded[id] = not folded.get(id, false)
		body_margin.visible = not folded[id]
		fold.icon = editor_icon("GuiTreeArrowRight" if folded[id] else "GuiTreeArrowDown"))
	updaters.append(func():
		enabled.set_pressed_no_signal(modifier.enabled)
		if in_edit: in_edit.set_pressed_no_signal(modifier.show_in_edit)
		error.text = modifier.get_error()
		error.visible = not modifier.get_error().is_empty())
	match kind:
		"Subdivide": subdivide_body(body, modifier)
		"Curve": curve_body(body, modifier)
		"Lattice": lattice_body(body, modifier)
		"Deform": deform_body(body, modifier)
		"Array": array_body(body, modifier)
		"Boolean": boolean_body(body, modifier)
		"Mirror": mirror_body(body, modifier)
		"Normals": normals_body(body, modifier)
		"Weighted Normal": weighted_body(body, modifier)

func subdivide_body(body: VBoxContainer, modifier: SubdivideModifier) -> void:
	var method := option(body, "Method", ["Catmull-Clark", "Simple"], modifier, "method")
	method.tooltip_text = "Catmull-Clark smooths the shape; Simple only splits every polygon (more geometry for deformers)."
	number(body, "Levels", 1, 6, 1, modifier, "levels").tooltip_text = "Each level splits every polygon into quads (×4)."
	var corners := toggle(body, "Keep Corners", modifier, "keep_corners")
	corners.tooltip_text = "Corners of open borders (a vertex with a single polygon) stay in place."
	var creases := toggle(body, "Use Edge Creases", modifier, "use_creases")
	creases.tooltip_text = "Edge crease values (Edge Attributes) keep edges sharp: 1 is fully sharp."
	var angle := number(body, "Sharp Angle", 0, 180, 0.5, modifier, "crease_angle")
	angle.suffix = "°"
	angle.tooltip_text = "Edges whose polygons meet at more than this angle keep their shape, so corners stay where they are instead of melting into a blob. 0 turns it off."
	var sharpness := number(body, "Sharpness", 0, 1, 0.01, modifier, "sharpness")
	sharpness.tooltip_text = "How sharp those edges stay: 1 keeps them crisp; lower values round them slightly while the overall form is kept (like semi-sharp creases)."
	hint(body, "Subdivides the whole mesh, no selection needed. Put it above Deform, Curve or Lattice to give them geometry to bend.")
	updaters.append(func():
		var smooth: bool = modifier.method == SubdivideModifier.CATMULL_CLARK
		for control in [corners, creases, angle]: control.get_parent().visible = smooth
		sharpness.get_parent().visible = smooth and modifier.crease_angle > 0)

func curve_body(body: VBoxContainer, modifier: CurveModifier) -> void:
	picker(body, "Path", modifier, "path", ["Path3D"], false)
	option(body, "Deform Axis", ["X", "Y", "Z", "-X", "-Y", "-Z"], modifier, "axis").tooltip_text = "Mesh axis that runs along the path."
	number(body, "Offset", -100000, 100000, 0.01, modifier, "offset").tooltip_text = "Slide the mesh along the path."
	toggle(body, "Stretch", modifier, "stretch").tooltip_text = "Stretch the mesh to the whole path length."
	hint(body, "The mesh's lowest point along the axis starts at the path start; its center line follows the path, turning with the path's up vector and tilt. Add Subdivide above for a smooth bend. Edge selection → Edges → Path makes a path from the mesh.")

func lattice_body(body: VBoxContainer, modifier: LatticeModifier) -> void:
	var row := picker(body, "Lattice", modifier, "lattice", ["Lattice3D"], false)
	var buttons := HBoxContainer.new()
	body.add_child(buttons)
	wide_button(buttons, "Create Lattice", func(): create_lattice(modifier), "Create a Lattice3D fitted around the mesh (a child of it) and use it.")
	var edit := wide_button(buttons, "Edit Points", func(): edit_lattice(modifier), "Select the lattice: click or box-select its points (Shift adds) and move them with W / E / R.")
	var reset := wide_button(buttons, "Reset", func(): reset_lattice(modifier), "Put every lattice point back on its regular grid.")
	var resolution := HBoxContainer.new()
	property(body, "Resolution", resolution)
	var fields: Array[SpinBox] = []
	for axis in 3:
		var field := SpinBox.new()
		field.min_value = 2
		field.max_value = 16
		field.prefix = ["x", "y", "z"][axis]
		field.custom_minimum_size.x = 0
		field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		field.select_all_on_focus = true
		resolution.add_child(field)
		fields.append(field)
		field.value_changed.connect(func(value):
			var cage := referenced(modifier, "lattice") as Lattice3D
			if not cage: return
			var size: Vector3i = cage.resolution
			size[axis] = int(value)
			set_node_property(cage, "resolution", size, "Lattice resolution"))
	var smooth := OptionButton.new()
	for item in ["Linear", "Smooth"]: smooth.add_item(item)
	property(body, "Interpolation", smooth)
	smooth.tooltip_text = "Smooth bends the mesh with a Bézier volume through all points; Linear moves it cell by cell."
	smooth.item_selected.connect(func(index):
		var cage := referenced(modifier, "lattice") as Lattice3D
		if cage: set_node_property(cage, "interpolation", index, "Lattice interpolation"))
	number(body, "Strength", 0, 1, 0.01, modifier, "strength")
	hint(body, "Changing the resolution resets the points. The lattice moves, rotates and scales like any node; the mesh follows it live.")
	updaters.append(func():
		var cage := referenced(modifier, "lattice") as Lattice3D
		for control in [edit, reset, smooth]: control.disabled = cage == null
		for axis in 3:
			fields[axis].editable = cage != null
			if cage and not fields[axis].get_line_edit().has_focus(): fields[axis].set_value_no_signal(cage.resolution[axis])
		if cage: smooth.select(cage.interpolation))

func create_lattice(modifier: LatticeModifier) -> void:
	if not is_instance_valid(node): return
	var bounds := node.get_base_mesh().get_aabb() if node.get_base_mesh() else AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))
	var cage := Lattice3D.new()
	var name := "Lattice"
	var suffix := 2
	while node.has_node(NodePath(name)):
		name = "Lattice%d" % suffix
		suffix += 1
	cage.name = name
	# A thin mesh still gets a usable box.
	var largest := maxf(bounds.size.x, maxf(bounds.size.y, bounds.size.z))
	cage.size = Vector3(maxf(bounds.size.x, largest * 0.05), maxf(bounds.size.y, largest * 0.05), maxf(bounds.size.z, largest * 0.05)) * 1.02
	cage.position = bounds.get_center()
	var scene := editor_plugin.get_editor_interface().get_edited_scene_root()
	var undo := editor_plugin.get_undo_redo()
	undo.create_action("Create lattice", UndoRedo.MERGE_DISABLE, node)
	undo.add_do_method(node, "add_child", cage, true)
	undo.add_do_method(cage, "set_owner", scene)
	undo.add_do_reference(cage)
	undo.add_undo_method(node, "remove_child", cage)
	undo.add_do_property(modifier, "lattice", NodePath(cage.name))
	undo.add_undo_property(modifier, "lattice", modifier.lattice)
	undo.commit_action()
	status.text = "Lattice created. Edit Points selects it; move its points with W / E / R."
	refresh()

func edit_lattice(modifier: LatticeModifier) -> void:
	var cage := referenced(modifier, "lattice")
	if not cage: return
	var selection := editor_plugin.get_editor_interface().get_selection()
	selection.clear()
	selection.add_node(cage)
	editor_plugin.get_editor_interface().edit_node(cage)
	status.text = "Click or box-select lattice points (Shift adds), then W / E / R. Select the mesh again to return."

func reset_lattice(modifier: LatticeModifier) -> void:
	var cage := referenced(modifier, "lattice") as Lattice3D
	if not cage: return
	var rest := PackedVector3Array()
	for index in cage.get_point_count(): rest.append(cage.get_rest_point(index))
	set_node_property(cage, "points", rest, "Reset lattice")

func set_node_property(target: Object, property_name: String, value: Variant, label: String) -> void:
	var old: Variant = target.get(property_name)
	if old == value: return
	var undo := editor_plugin.get_undo_redo()
	undo.create_action(label, UndoRedo.MERGE_DISABLE, target)
	undo.add_do_property(target, property_name, value)
	undo.add_undo_property(target, property_name, old)
	if property_name == "resolution":
		# Resolution resets the points; undo brings the old ones back.
		undo.add_undo_property(target, "points", target.get("points"))
	undo.commit_action()
	refresh()

func deform_body(body: VBoxContainer, modifier: DeformModifier) -> void:
	var type := option(body, "Type", ["Bend", "Taper", "Twist"], modifier, "deform")
	option(body, "Axis", ["X", "Y", "Z"], modifier, "axis")
	var amount := number(body, "Angle", -3600, 3600, 0.1, modifier, "amount")
	number(body, "Low Bound", 0, 1, 0.01, modifier, "low")
	number(body, "High Bound", 0, 1, 0.01, modifier, "high")
	type.tooltip_text = "Bend and Twist rotate by Angle along the axis; Taper scales the cross-section by Factor at the high bound."
	updaters.append(func():
		var taper: bool = modifier.deform == DeformModifier.TAPER
		amount.get_parent().get_child(0).text = "Factor" if taper else "Angle"
		amount.suffix = "" if taper else "°")

func array_body(body: VBoxContainer, modifier: ArrayModifier) -> void:
	option(body, "Pattern", ["Line", "Circle", "Rectangle", "Path3D"], modifier, "pattern")
	var count := number(body, "Count", 1, 500, 1, modifier, "count")
	var rows := number(body, "Rows", 1, 100, 1, modifier, "rows")
	var offset := vector(body, "Offset", modifier, "offset")
	var row_offset := vector(body, "Row Offset", modifier, "row_offset")
	var radius := number(body, "Radius", 0.001, 100000, 0.01, modifier, "radius")
	var axis := option(body, "Circle Axis", ["X", "Y", "Z"], modifier, "circle_axis")
	var orient := toggle(body, "Orient Copies", modifier, "orient_copies")
	var path := picker(body, "Path", modifier, "path", ["Path3D"], false)
	count.tooltip_text = "Copies (columns for Rectangle). The mesh itself is the first copy."
	updaters.append(func():
		var pattern: int = modifier.pattern
		rows.get_parent().visible = pattern == ArrayModifier.PATTERN_RECTANGLE
		row_offset.get_parent().visible = pattern == ArrayModifier.PATTERN_RECTANGLE
		offset.get_parent().visible = pattern in [ArrayModifier.PATTERN_LINE, ArrayModifier.PATTERN_RECTANGLE]
		radius.get_parent().visible = pattern == ArrayModifier.PATTERN_CIRCLE
		axis.get_parent().visible = pattern == ArrayModifier.PATTERN_CIRCLE
		orient.get_parent().visible = pattern in [ArrayModifier.PATTERN_CIRCLE, ArrayModifier.PATTERN_PATH]
		path.get_parent().visible = pattern == ArrayModifier.PATTERN_PATH)

func boolean_body(body: VBoxContainer, modifier: BooleanModifier) -> void:
	option(body, "Operation", ["Union", "Difference", "Intersection"], modifier, "operation")
	picker(body, "Object", modifier, "object", ["MeshInstance3D"], true)
	var ngons := toggle(body, "N-gons", modifier, "ngons")
	ngons.tooltip_text = "Merge the coplanar triangles of the result back into polygons (n-gons). Off keeps the raw triangles."
	hint(body, "Both meshes must be closed solids. The result follows the object while it moves or is edited.")

func normals_body(body: VBoxContainer, modifier: NormalsModifier) -> void:
	option(body, "Mode", ["Smooth by Angle", "Smooth", "Flat"], modifier, "mode").tooltip_text = "Smooth by Angle smooths only where polygons meet at less than Angle (Blender's auto smooth); Smooth smooths everything; Flat shades each polygon with its own normal."
	var angle := number(body, "Angle", 0, 180, 0.5, modifier, "angle")
	angle.suffix = "°"
	toggle(body, "Weighted by Area", modifier, "area_weighted").tooltip_text = "Large polygons dominate the normals they share (Weighted Normal): flat panels stay flat next to small bevels."
	toggle(body, "Keep Sharp Edges", modifier, "keep_sharp").tooltip_text = "Edges marked sharp always split the shading."
	toggle(body, "Recalculate Outside", modifier, "outside").tooltip_text = "Turn every closed part so its polygons face outward (fixes inside-out results)."
	hint(body, "Put it at the bottom of the stack: it fixes the shading that Mirror, Boolean, Array and other modifiers leave behind.")
	updaters.append(func(): angle.get_parent().visible = modifier.mode == NormalsModifier.SMOOTH_BY_ANGLE)

func weighted_body(body: VBoxContainer, modifier: WeightedNormalModifier) -> void:
	option(body, "Weighting Mode", ["Face Area", "Corner Angle", "Face Area & Angle"], modifier, "mode").tooltip_text = "What makes a polygon count more for the normals it shares: its area, its corner angle at the vertex, or both."
	number(body, "Weight", 1, 100, 1, modifier, "weight").tooltip_text = "50 weights each polygon by its value alone; higher makes the largest polygons dominate more, lower evens them out."
	number(body, "Threshold", 0, 10, 0.001, modifier, "threshold").tooltip_text = "Polygons whose values differ by less than this (relative to the largest around the vertex) count as equal."
	toggle(body, "Keep Sharp", modifier, "keep_sharp").tooltip_text = "Edges marked sharp split the normals."
	var angle := number(body, "Smooth Angle", 0, 180, 0.5, modifier, "angle")
	angle.suffix = "°"
	angle.tooltip_text = "Limit: polygons meeting at more than this angle do not share normals (180 = no limit)."
	hint(body, "Large flat panels keep flat shading next to small bevels and rounded edges. Put it at the end of the stack.")

func mirror_body(body: VBoxContainer, modifier: MirrorModifier) -> void:
	var axes := HBoxContainer.new()
	property(body, "Axes", axes)
	for axis in ["x", "y", "z"]:
		var check := CheckBox.new()
		check.text = axis.to_upper()
		check.toggled.connect(func(on): set_property(modifier, "axis_" + axis, on))
		axes.add_child(check)
		updaters.append(func(): check.set_pressed_no_signal(modifier.get("axis_" + axis)))
	vector(body, "Center", modifier, "center")
	var buttons := HBoxContainer.new()
	body.add_child(buttons)
	wide_button(buttons, "Origin", func(): set_property(modifier, "center", Vector3.ZERO), "Mirror across the object's origin.")
	wide_button(buttons, "Center of Mass", func(): set_property(modifier, "center", node.poly_mesh.get_center_of_mass()), "Put the mirror planes through the object's center of mass.")
	wide_button(buttons, "From Selection", func(): center_from_selection(modifier), "Put the mirror planes through the center of the selected vertices, edges or polygons.")
	toggle(body, "Bisect", modifier, "bisect").tooltip_text = "Cut the mesh at the plane and mirror only the kept half, so a whole (already symmetric) mesh is not doubled."
	toggle(body, "Flip", modifier, "flip").tooltip_text = "Keep the negative side instead of the positive one."
	toggle(body, "Merge", modifier, "merge").tooltip_text = "Weld the vertices on the plane so both halves form one surface."
	number(body, "Merge Distance", 0, 1, 0.0001, modifier, "merge_distance").tooltip_text = "Vertices this close to the plane are welded (and count as on it for Clipping)."
	toggle(body, "Clipping", modifier, "clipping").tooltip_text = "While editing, vertices on the plane stay on it and no vertex crosses it (Move / Rotate / Scale, gizmo, Slide)."
	hint(body, "Model one half: the other half is built live and also shown while polygons are edited (selection works on the modeled half). The planes are drawn in the viewport. Apply bakes the whole mirrored mesh.")

func center_from_selection(modifier: MirrorModifier) -> void:
	var poly: PolyMesh = node.poly_mesh
	var points := poly.get_vertex_positions(poly.get_selection_vertices(editor_plugin.panel.mode))
	if points.is_empty():
		status.text = "Select elements to place the mirror center on"
		return
	var center := Vector3.ZERO
	for point in points: center += point
	set_property(modifier, "center", center / points.size())

# ---- Controls -----------------------------------------------------------------

func number(body: Control, text: String, low: float, high: float, step: float, modifier: MeshModifier, property_name: String) -> SpinBox:
	var field := SpinBox.new()
	field.min_value = low
	field.max_value = high
	field.step = step
	field.allow_greater = true
	field.allow_lesser = low < 0
	field.select_all_on_focus = true
	property(body, text, field)
	field.value_changed.connect(func(value): set_property(modifier, property_name, int(value) if step >= 1 else value, true))
	updaters.append(func(): if not field.get_line_edit().has_focus(): field.set_value_no_signal(modifier.get(property_name)))
	return field

func vector(body: Control, text: String, modifier: MeshModifier, property_name: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	property(body, text, row)
	for axis in 3:
		var field := SpinBox.new()
		field.min_value = -100000
		field.max_value = 100000
		field.step = 0.001
		field.prefix = ["x", "y", "z"][axis]
		field.custom_minimum_size.x = 0
		field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		field.select_all_on_focus = true
		row.add_child(field)
		field.value_changed.connect(func(value):
			var current: Vector3 = modifier.get(property_name)
			current[axis] = value
			set_property(modifier, property_name, current, true))
		updaters.append(func(): if not field.get_line_edit().has_focus(): field.set_value_no_signal(Vector3(modifier.get(property_name))[axis]))
	return row

func option(body: Control, text: String, items: Array, modifier: MeshModifier, property_name: String) -> OptionButton:
	var button := OptionButton.new()
	for item in items: button.add_item(item)
	property(body, text, button)
	button.item_selected.connect(func(index): set_property(modifier, property_name, index))
	updaters.append(func(): button.select(int(modifier.get(property_name))))
	return button

func toggle(body: Control, text: String, modifier: MeshModifier, property_name: String) -> CheckBox:
	var check := CheckBox.new()
	check.text = "On"
	property(body, text, check)
	check.toggled.connect(func(on): set_property(modifier, property_name, on))
	updaters.append(func(): check.set_pressed_no_signal(modifier.get(property_name)))
	return check

func picker(body: Control, text: String, modifier: MeshModifier, property_name: String, types: Array, can_hide: bool) -> HBoxContainer:
	# Node reference stored as a path relative to the EditableMesh.
	var row := HBoxContainer.new()
	property(body, text, row)
	var name_label := Label.new()
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.clip_text = true
	row.add_child(name_label)
	var pick := Button.new()
	pick.text = "Pick…"
	pick.tooltip_text = "Choose the %s in the scene" % " / ".join(types)
	pick.pressed.connect(func(): pick_node(modifier, property_name, types, can_hide))
	row.add_child(pick)
	var visibility: Button = null
	if can_hide:
		visibility = Button.new()
		visibility.toggle_mode = true
		visibility.tooltip_text = "Show or hide the object in the viewport"
		visibility.icon = editor_icon("GuiVisibilityVisible")
		visibility.toggled.connect(func(on):
			var other := referenced(modifier, property_name)
			if other: set_visible_undoable(other, on))
		row.add_child(visibility)
	updaters.append(func():
		var other := referenced(modifier, property_name)
		name_label.text = String(other.name) if other else "(none)"
		if visibility:
			visibility.disabled = other == null
			visibility.set_pressed_no_signal(other != null and other.visible)
			visibility.icon = editor_icon("GuiVisibilityVisible" if other != null and other.visible else "GuiVisibilityHidden"))
	return row

func referenced(modifier: MeshModifier, property_name: String) -> Node3D:
	var path: NodePath = modifier.get(property_name)
	if path.is_empty() or not is_instance_valid(node): return null
	return node.get_node_or_null(path) as Node3D

func pick_node(modifier: MeshModifier, property_name: String, types: Array, hide_object: bool) -> void:
	var valid: Array[StringName] = []
	for type in types: valid.append(StringName(type))
	editor_plugin.get_editor_interface().popup_node_selector(func(path: NodePath):
		if path.is_empty() or not is_instance_valid(node): return
		var scene := editor_plugin.get_editor_interface().get_edited_scene_root()
		var picked := scene.get_node_or_null(path) if scene else null
		if not picked: return
		if picked == node:
			status.text = "A mesh cannot use itself"
			return
		var undo := editor_plugin.get_undo_redo()
		undo.create_action("Modifier: pick %s" % picked.name, UndoRedo.MERGE_DISABLE, node)
		undo.add_do_property(modifier, property_name, node.get_path_to(picked))
		undo.add_undo_property(modifier, property_name, modifier.get(property_name))
		if hide_object and picked is Node3D and picked.visible:
			# Boolean objects are hidden like cutters; the eye button shows them again.
			undo.add_do_property(picked, "visible", false)
			undo.add_undo_property(picked, "visible", true)
		undo.commit_action(), valid)

func set_visible_undoable(other: Node3D, on: bool) -> void:
	var undo := editor_plugin.get_undo_redo()
	undo.create_action("Show object" if on else "Hide object", UndoRedo.MERGE_DISABLE, other)
	undo.add_do_property(other, "visible", on)
	undo.add_undo_property(other, "visible", other.visible)
	undo.commit_action()
	refresh()

# ---- Stack edits --------------------------------------------------------------

func set_property(modifier: MeshModifier, property_name: String, value: Variant, merge: bool = false) -> void:
	var old: Variant = modifier.get(property_name)
	if old == value: return
	var undo := editor_plugin.get_undo_redo()
	undo.create_action("Modifier %s: %s" % [modifier.get_kind(), property_name.capitalize()], UndoRedo.MERGE_ENDS if merge else UndoRedo.MERGE_DISABLE, node)
	undo.add_do_property(modifier, property_name, value)
	undo.add_undo_property(modifier, property_name, old)
	undo.commit_action()
	editor_plugin.update_overlays()

func set_stack(stack: Array, label: String, poly: PolyMesh = null) -> void:
	var undo := editor_plugin.get_undo_redo()
	undo.create_action(label, UndoRedo.MERGE_DISABLE, node)
	if poly:
		undo.add_do_method(editor_plugin.workflow, "assign_poly", node, poly)
		undo.add_undo_method(editor_plugin.workflow, "assign_poly", node, node.poly_mesh)
	undo.add_do_property(node, "modifiers", stack)
	undo.add_undo_property(node, "modifiers", modifiers().duplicate())
	undo.commit_action()
	editor_plugin.update_overlays()
	refresh()

func add_modifier(kind: String, pick: bool = true) -> void:
	if not is_instance_valid(node):
		status.text = "Select an EditableMesh first"
		return
	var modifier: MeshModifier
	var bounds := node.get_base_mesh().get_aabb() if node.get_base_mesh() else AABB()
	match kind:
		"Subdivide": modifier = SubdivideModifier.new()
		"Curve": modifier = CurveModifier.new()
		"Lattice": modifier = LatticeModifier.new()
		"Deform": modifier = DeformModifier.new()
		"Array":
			modifier = ArrayModifier.new()
			modifier.offset = Vector3(maxf(bounds.size.x, 0.1) * 1.25, 0, 0)
			modifier.row_offset = Vector3(0, 0, maxf(bounds.size.z, 0.1) * 1.25)
			modifier.radius = maxf(maxf(bounds.size.x, bounds.size.z), 0.1) * 1.5
		"Boolean": modifier = BooleanModifier.new()
		"Normals": modifier = NormalsModifier.new()
		"Weighted Normal": modifier = WeightedNormalModifier.new()
		"Mirror":
			modifier = MirrorModifier.new()
			modifier.center = node.poly_mesh.get_center_of_mass()
	var stack := modifiers().duplicate()
	stack.append(modifier)
	set_stack(stack, "Add %s modifier" % kind)
	status.text = "%s added" % kind
	if kind == "Boolean" and pick: pick_node(modifier, "object", ["MeshInstance3D"], true)
	if kind == "Curve" and pick: pick_node(modifier, "path", ["Path3D"], false)
	if kind == "Lattice" and pick: create_lattice(modifier)

func move(index: int, step: int) -> void:
	var target := index + step
	var stack := modifiers().duplicate()
	if target < 0 or target >= stack.size(): return
	var item = stack[index]
	stack.remove_at(index)
	stack.insert(target, item)
	set_stack(stack, "Move modifier")

func remove(index: int) -> void:
	var stack := modifiers().duplicate()
	var removed: MeshModifier = stack[index]
	stack.remove_at(index)
	set_stack(stack, "Remove %s modifier" % removed.get_kind())

func apply_modifier(index: int) -> void:
	var modifier: MeshModifier = modifiers()[index]
	var result: Dictionary = node.evaluate_modifiers([modifier])
	if not result.ok:
		status.text = result.error
		return
	var stack := modifiers().duplicate()
	stack.remove_at(index)
	set_stack(stack, "Apply %s modifier" % modifier.get_kind(), result.poly)
	status.text = "%s applied to the mesh" % modifier.get_kind()

func apply_all_modifiers() -> void:
	if not is_instance_valid(node): return
	var geometry: Array = []
	var kept: Array = []
	for modifier in modifiers():
		if modifier and modifier.affects_geometry():
			if modifier.enabled: geometry.append(modifier)
		else: kept.append(modifier)
	if geometry.is_empty():
		status.text = "No enabled geometry modifiers to apply"
		return
	var result: Dictionary = node.evaluate_modifiers(geometry)
	if not result.ok:
		status.text = result.error
		return
	set_stack(kept, "Apply all modifiers", result.poly)
	status.text = "%d modifier(s) applied" % geometry.size()

# ---- Theme helpers ------------------------------------------------------------

func editor_style(name: String) -> StyleBox:
	var base := editor_plugin.get_editor_interface().get_base_control()
	return base.get_theme_stylebox(name, "EditorStyles") if base.has_theme_stylebox(name, "EditorStyles") else StyleBoxEmpty.new()

func has_icon(name: String) -> bool:
	return editor_plugin.get_editor_interface().get_base_control().has_theme_icon(name, "EditorIcons")

func editor_icon(name: String) -> Texture2D:
	var base := editor_plugin.get_editor_interface().get_base_control()
	return base.get_theme_icon(name, "EditorIcons") if base.has_theme_icon(name, "EditorIcons") else null

func editor_color(name: String) -> Color:
	return editor_plugin.get_editor_interface().get_base_control().get_theme_color(name, "Editor")

func icon_button(parent: Control, icon_name: String, tooltip: String) -> Button:
	var button := Button.new()
	button.flat = true
	button.icon = editor_icon(icon_name)
	button.tooltip_text = tooltip
	button.focus_mode = Control.FOCUS_NONE
	parent.add_child(button)
	return button

func wide_button(parent: Control, text: String, callback: Callable, tooltip: String = "") -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tooltip
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(callback)
	parent.add_child(button)
	return button

func property(parent: Control, text: String, control: Control) -> Control:
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

func hint(parent: Control, text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", editor_color("font_readonly_color"))
	parent.add_child(label)
	return label
