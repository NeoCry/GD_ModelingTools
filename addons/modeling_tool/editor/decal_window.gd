@tool
extends Window
## Mesh Decals: New Mesh Decal starts a decal with its own fresh material and
## places it by clicking surfaces; further clicks place more of the same set
## (sharing its material). Decals placed before keep their materials. With no
## decal selected the window edits the current set; with one selected, that
## decal. Bake turns decals into plain MeshInstance3D nodes that need no add-on.
## Every change is an undo step.

var editor_plugin: EditorPlugin
var decal: MeshDecal3D
var placing := false
# Material of the current set: the decals placed since the last New Mesh Decal.
var current_set: Material = default_material()
var defaults := {"size": Vector2(0.5, 0.5), "depth": 0.25, "offset": 0.002, "max_angle": 80.0, "source_mesh": null, "source_y_up": true}
var place_button: Button
var subject: Label
var status: Label
var updaters: Array[Callable] = []
var file_dialog: EditorFileDialog
var dialog_target := ""
var decal_rows: Array[Control] = []

const IMAGE_FILTERS := ["*.png", "*.jpg", "*.jpeg", "*.webp", "*.svg", "*.tga", "*.bmp", "*.exr", "*.hdr", "*.tres", "*.res"]
const MATERIAL_FILTERS := ["*.tres", "*.res", "*.material"]
const MESH_FILTERS := ["*.tres", "*.res", "*.mesh", "*.obj"]

static func default_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(1, 1, 1, 1)
	material.render_priority = 1
	material.roughness = 0.8
	return material

func _ready() -> void:
	visible = false
	always_on_top = true
	title = "Mesh Decals"
	size = Vector2i(400, 720)
	min_size = Vector2i(340, 420)
	close_requested.connect(func(): set_placing(false); hide())
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
	var new_button := Button.new()
	new_button.text = "New Mesh Decal"
	new_button.icon = editor_icon("Add")
	new_button.tooltip_text = "Start a new decal with its own fresh material, then click a surface in the 3D viewport to place it.\nDecals placed before keep their materials: what you edit from now on changes only the new decal (and copies you place with more clicks).\nEsc stops placing."
	new_button.pressed.connect(new_decal)
	bar.add_child(new_button)
	place_button = Button.new()
	place_button.text = "Place More"
	place_button.icon = editor_icon("Decal")
	place_button.toggle_mode = true
	place_button.tooltip_text = "Place more copies of the current decal (same material, so they change together). Esc or this button stops."
	place_button.toggled.connect(set_placing)
	bar.add_child(place_button)
	subject = Label.new()
	subject.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	subject.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	subject.clip_text = true
	bar.add_child(subject)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]: margin.add_theme_constant_override("margin_" + side, 6)
	scroll.add_child(margin)
	var body := VBoxContainer.new()
	margin.add_child(body)
	build_projection(body)
	build_material(body)
	var status_bar := PanelContainer.new()
	status_bar.add_theme_stylebox_override("panel", editor_style("ContextualToolbar"))
	root.add_child(status_bar)
	status = Label.new()
	status.clip_text = true
	status_bar.add_child(status)
	file_dialog = EditorFileDialog.new()
	file_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	file_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	for filter in IMAGE_FILTERS: file_dialog.add_filter(filter)
	file_dialog.file_selected.connect(_file_chosen)
	add_child(file_dialog)
	refresh()

# ---- Binding --------------------------------------------------------------------

func open(selected: MeshDecal3D) -> void:
	bind(selected)
	if not visible:
		var parent_window := editor_plugin.get_editor_interface().get_base_control().get_window()
		var at := parent_window.position + (parent_window.size - size) / 2
		if not parent_window.gui_embed_subwindows:
			var screen := DisplayServer.screen_get_usable_rect(parent_window.current_screen)
			at.x = clampi(at.x, screen.position.x, maxi(screen.position.x, screen.end.x - size.x))
			at.y = clampi(at.y, screen.position.y + 40, maxi(screen.position.y + 40, screen.end.y - size.y))
		position = at
		show()
	grab_focus()

func bind(selected: MeshDecal3D) -> void:
	if is_instance_valid(decal) and decal.tree_exited.is_connected(_decal_left): decal.tree_exited.disconnect(_decal_left)
	decal = selected if is_instance_valid(selected) and selected.is_inside_tree() else null
	if decal: decal.tree_exited.connect(_decal_left)
	refresh()

func _decal_left() -> void:
	bind(null)

# The StandardMaterial3D the material controls edit (null for other material types).
func material() -> StandardMaterial3D:
	var current: Material = decal.material_override if decal else current_set
	return current as StandardMaterial3D

func refresh() -> void:
	if not is_instance_valid(subject): return
	if decal: subject.text = decal.name
	else:
		var placed := set_members().size()
		subject.text = "Current decal" + (" (%d placed)" % placed if placed > 0 else " (not placed yet)")
	title = "Mesh Decals — %s" % decal.name if decal else "Mesh Decals"
	for row in decal_rows: row.visible = decal != null
	for updater in updaters: updater.call()

# ---- Projection -------------------------------------------------------------------

func build_projection(body: VBoxContainer) -> void:
	heading(body, "Projection")
	var size_row := HBoxContainer.new()
	property(body, "Size", size_row)
	for axis in 2:
		var field := spin(0.001, 10000, 0.01)
		field.prefix = ["w", "h"][axis]
		size_row.add_child(field)
		field.value_changed.connect(func(value):
			var current: Vector2 = get_setting("size")
			current[axis] = value
			set_setting("size", current))
		updaters.append(func(): if not field.get_line_edit().has_focus(): field.set_value_no_signal(Vector2(get_setting("size"))[axis]))
	shape_rows(body)
	setting_spin(body, "Depth", "depth", 0.0001, 1000, 0.01).tooltip_text = "How far in front of and behind the decal it projects (along its local Z)."
	setting_spin(body, "Offset", "offset", -1, 1, 0.0005).tooltip_text = "Lift above the surface, against z-fighting."
	setting_spin(body, "Max Angle", "max_angle", 0, 90, 0.5).tooltip_text = "Surfaces turned further than this from the projection direction get no decal (avoids stretching on side walls)."
	var rotation_field := spin(-360, 360, 1)
	rotation_field.suffix = "°"
	rotation_field.tooltip_text = "Turn the decal around the surface normal (its local Z)."
	decal_rows.append(property(body, "Rotation", rotation_field).get_parent())
	rotation_field.value_changed.connect(func(value):
		if not decal: return
		var basis := decal.basis
		var turned := Basis(basis.z.normalized(), deg_to_rad(value) - current_rotation()) * basis
		set_node_property(decal, "basis", turned, "Rotate decal"))
	updaters.append(func(): if decal and not rotation_field.get_line_edit().has_focus(): rotation_field.set_value_no_signal(rad_to_deg(current_rotation())))
	var target_row := HBoxContainer.new()
	decal_rows.append(property(body, "Surface", target_row).get_parent())
	var target_label := Label.new()
	target_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	target_label.clip_text = true
	target_row.add_child(target_label)
	var pick := Button.new()
	pick.text = "Pick…"
	pick.tooltip_text = "Project onto another mesh."
	pick.pressed.connect(pick_target)
	target_row.add_child(pick)
	updaters.append(func():
		if not decal: return
		var node := decal.get_node_or_null(decal.target)
		target_label.text = String(node.name) if node else "(none)")

# Shape: the clipped surface piece (rectangle), or a mesh of your own.
func shape_rows(body: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	property(body, "Shape", row)
	var shape_label := Label.new()
	shape_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	shape_label.clip_text = true
	row.add_child(shape_label)
	var from_file := Button.new()
	from_file.icon = editor_icon("Load")
	from_file.tooltip_text = "Use a mesh file (.tres, .res, .mesh, .obj) as the decal shape."
	from_file.pressed.connect(func(): open_dialog("source_mesh", EditorFileDialog.FILE_MODE_OPEN_FILE, MESH_FILTERS))
	row.add_child(from_file)
	var from_node := Button.new()
	from_node.icon = editor_icon("MeshInstance3D")
	from_node.tooltip_text = "Use the mesh of an object in the scene (any MeshInstance3D or EditableMesh, e.g. a plate you modeled)."
	from_node.pressed.connect(pick_source_node)
	row.add_child(from_node)
	var clear := Button.new()
	clear.icon = editor_icon("Clear")
	clear.tooltip_text = "Back to the rectangle cut from the surface."
	clear.pressed.connect(func(): set_setting("source_mesh", null))
	row.add_child(clear)
	var y_up := CheckBox.new()
	y_up.text = "On"
	y_up.tooltip_text = "The mesh was modeled lying flat (XZ plane, Y up): its Y becomes the height above the surface and its -Z the top of the decal. Off: XY plane with Z as the height."
	var y_up_row := property(body, "Modeled Y-up", y_up).get_parent()
	y_up.toggled.connect(func(on): set_setting("source_y_up", on))
	updaters.append(func():
		var source: Mesh = get_setting("source_mesh")
		shape_label.text = "Rectangle (surface)" if source == null else (source.resource_path.get_file() if source.resource_path != "" else (source.resource_name if source.resource_name != "" else "Custom mesh"))
		y_up_row.visible = source != null
		y_up.set_pressed_no_signal(get_setting("source_y_up")))

func pick_source_node() -> void:
	var types: Array[StringName] = [&"MeshInstance3D"]
	editor_plugin.get_editor_interface().popup_node_selector(func(path: NodePath):
		var scene := editor_plugin.get_editor_interface().get_edited_scene_root()
		var picked := scene.get_node_or_null(path) if scene and not path.is_empty() else null
		if picked is MeshInstance3D and not picked is MeshDecal3D and picked.mesh:
			var copy: Mesh = picked.mesh.duplicate()
			copy.resource_name = picked.name
			set_setting("source_mesh", copy)
			status.text = "Decal shape: %s. It is projected onto the surface vertex by vertex; subdivide it for curved surfaces." % picked.name, types)

func current_rotation() -> float:
	# Angle of the decal's X around its Z, relative to the projection of the parent's X (or Z).
	var basis := decal.basis.orthonormalized()
	var reference := Vector3.RIGHT if absf(basis.z.dot(Vector3.RIGHT)) < 0.9 else Vector3.BACK
	reference = (reference - basis.z * reference.dot(basis.z)).normalized()
	return atan2(reference.cross(basis.x).dot(basis.z), reference.dot(basis.x))

func get_setting(key: String) -> Variant:
	return decal.get(key) if decal else defaults.get(key)

func set_setting(key: String, value: Variant) -> void:
	if decal: set_node_property(decal, key, value, "Decal %s" % key.capitalize())
	else: defaults[key] = value

func setting_spin(body: VBoxContainer, text: String, key: String, low: float, high: float, step: float) -> SpinBox:
	var field := spin(low, high, step)
	property(body, text, field)
	field.value_changed.connect(func(value): set_setting(key, int(value) if step >= 1 else value))
	updaters.append(func(): if not field.get_line_edit().has_focus(): field.set_value_no_signal(get_setting(key)))
	return field

func pick_target() -> void:
	if not decal: return
	var types: Array[StringName] = [&"MeshInstance3D"]
	editor_plugin.get_editor_interface().popup_node_selector(func(path: NodePath):
		var scene := editor_plugin.get_editor_interface().get_edited_scene_root()
		var picked := scene.get_node_or_null(path) if scene and not path.is_empty() else null
		if picked is MeshInstance3D and not picked is MeshDecal3D and is_instance_valid(decal):
			set_node_property(decal, "target", decal.get_path_to(picked), "Decal surface"), types)

# ---- Material -----------------------------------------------------------------------

func build_material(body: VBoxContainer) -> void:
	heading(body, "Material")
	texture_row(body, "Albedo", "albedo_texture")
	var color := ColorPickerButton.new()
	color.edit_alpha = true
	property(body, "Color", color)
	color.color_changed.connect(func(value): set_material("albedo_color", value, true))
	updaters.append(func(): if material(): color.color = material().albedo_color)
	var transparency := OptionButton.new()
	for item in ["Alpha", "Alpha Scissor", "Alpha Hash", "Opaque"]: transparency.add_item(item)
	property(body, "Transparency", transparency)
	var modes := [BaseMaterial3D.TRANSPARENCY_ALPHA, BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR, BaseMaterial3D.TRANSPARENCY_ALPHA_HASH, BaseMaterial3D.TRANSPARENCY_DISABLED]
	transparency.item_selected.connect(func(index): set_material("transparency", modes[index]))
	updaters.append(func(): if material(): transparency.select(maxi(modes.find(material().transparency), 0)))
	material_spin(body, "Scissor Threshold", "alpha_scissor_threshold", 0, 1, 0.01)
	texture_row(body, "Normal Map", "normal_texture")
	material_spin(body, "Normal Strength", "normal_scale", -16, 16, 0.01)
	material_spin(body, "Roughness", "roughness", 0, 1, 0.01)
	material_spin(body, "Metallic", "metallic", 0, 1, 0.01)
	var emission := ColorPickerButton.new()
	property(body, "Emission", emission)
	emission.color_changed.connect(func(value):
		set_material("emission_enabled", value.v > 0.0001)
		set_material("emission", value, true))
	updaters.append(func(): if material(): emission.color = material().emission if material().emission_enabled else Color.BLACK)
	material_spin(body, "Emission Energy", "emission_energy_multiplier", 0, 100, 0.01)
	var unshaded := CheckBox.new()
	unshaded.text = "On"
	property(body, "Unshaded", unshaded)
	unshaded.toggled.connect(func(on): set_material("shading_mode", BaseMaterial3D.SHADING_MODE_UNSHADED if on else BaseMaterial3D.SHADING_MODE_PER_PIXEL))
	updaters.append(func(): if material(): unshaded.set_pressed_no_signal(material().shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED))
	material_spin(body, "Render Priority", "render_priority", -128, 127, 1).tooltip_text = "Draw order among transparent materials (decals above the surface use 1)."
	var files := HBoxContainer.new()
	body.add_child(files)
	var load_material_button := Button.new()
	load_material_button.text = "Load Material…"
	load_material_button.icon = editor_icon("Load")
	load_material_button.tooltip_text = "Use a saved material (.tres): for the selected decal, or for new decals. Decals using the same file share it."
	load_material_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	load_material_button.pressed.connect(func(): open_dialog("load_material", EditorFileDialog.FILE_MODE_OPEN_FILE, MATERIAL_FILTERS))
	files.add_child(load_material_button)
	var save_material_button := Button.new()
	save_material_button.text = "Save Material…"
	save_material_button.icon = editor_icon("Save")
	save_material_button.tooltip_text = "Save this material as a .tres, to reuse it for other decals."
	save_material_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_material_button.pressed.connect(func(): open_dialog("save_material", EditorFileDialog.FILE_MODE_SAVE_FILE, ["*.tres"]))
	files.add_child(save_material_button)
	var unique := Button.new()
	unique.text = "Make Material Unique"
	unique.tooltip_text = "Give the selected decal its own copy of the material (decals placed together share one)."
	unique.pressed.connect(func():
		if decal and decal.material_override: set_node_property(decal, "material_override", decal.material_override.duplicate(), "Unique decal material"))
	body.add_child(unique)
	decal_rows.append(unique)
	hint(body, "New Mesh Decal gives each new decal its own material: set it up here, before or after placing. Decals placed earlier are not affected. Copies placed with Place More share the material and change together. To change an older decal, select it in the scene (Make Material Unique separates it from its copies). Textures with transparency (PNG) work with Alpha; a normal map adds relief.")
	heading(body, "Bake")
	var bake_row := HBoxContainer.new()
	body.add_child(bake_row)
	var bake_one := Button.new()
	bake_one.text = "Bake Selected"
	bake_one.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bake_one.tooltip_text = "Replace the selected decal by a plain MeshInstance3D with the same mesh and material. It stops following the surface but needs no add-on."
	bake_one.pressed.connect(func(): if decal: bake([decal]))
	bake_row.add_child(bake_one)
	decal_rows.append(bake_one)
	var bake_all := Button.new()
	bake_all.text = "Bake All in Scene"
	bake_all.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bake_all.tooltip_text = "Replace every mesh decal of the edited scene by a plain MeshInstance3D (one undo step)."
	bake_all.pressed.connect(func():
		var scene := editor_plugin.get_editor_interface().get_edited_scene_root()
		if scene: bake(scene.find_children("*", "MeshDecal3D", true, true)))
	bake_row.add_child(bake_all)
	hint(body, "Decals are saved in the scene with their mesh. They need this add-on's extension to load and follow the surface; disabling only the editor plugin keeps them working. Bake them before removing the add-on or sharing the scene with a project without it.")

func texture_row(body: VBoxContainer, text: String, key: String) -> void:
	var row := HBoxContainer.new()
	property(body, text, row)
	var preview := TextureRect.new()
	preview.custom_minimum_size = Vector2(28, 28)
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	row.add_child(preview)
	var name_label := Label.new()
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.clip_text = true
	row.add_child(name_label)
	var load_button := Button.new()
	load_button.icon = editor_icon("Load")
	load_button.tooltip_text = "Load a texture"
	load_button.pressed.connect(func(): open_dialog(key, EditorFileDialog.FILE_MODE_OPEN_FILE, IMAGE_FILTERS))
	row.add_child(load_button)
	var clear := Button.new()
	clear.icon = editor_icon("Clear")
	clear.tooltip_text = "Remove the texture"
	clear.pressed.connect(func(): set_material(key, null))
	row.add_child(clear)
	updaters.append(func():
		var texture: Texture2D = material().get(key) if material() else null
		preview.texture = texture
		name_label.text = texture.resource_path.get_file() if texture and texture.resource_path != "" else ("(texture)" if texture else "(none)"))

func open_dialog(target: String, mode: EditorFileDialog.FileMode, filters: Array) -> void:
	dialog_target = target
	file_dialog.file_mode = mode
	file_dialog.clear_filters()
	for filter in filters: file_dialog.add_filter(filter)
	file_dialog.popup_file_dialog()

func _file_chosen(path: String) -> void:
	match dialog_target:
		"source_mesh":
			var mesh := load(path) as Mesh
			if mesh: set_setting("source_mesh", mesh)
			else: status.text = "Not a mesh: " + path
		"load_material": load_material(path)
		"save_material": save_material(path)
		_:
			var texture := load(path) as Texture2D
			if not texture:
				status.text = "Not a texture: " + path
				return
			if dialog_target == "normal_texture": set_material("normal_enabled", true)
			set_material(dialog_target, texture)

# A saved material is used as it is (shared): edits change the .tres for every decal using it.
func load_material(path: String) -> void:
	var loaded := load(path) as Material
	if not loaded:
		status.text = "Not a material: " + path
		return
	if decal: set_node_property(decal, "material_override", loaded, "Decal material")
	else:
		current_set = loaded
		refresh()
	status.text = "%s uses %s" % [decal.name if decal else "New decals", path.get_file()]

func save_material(path: String) -> void:
	var current: Material = decal.material_override if decal else current_set
	if not current:
		status.text = "No material to save"
		return
	if ResourceSaver.save(current, path) != OK:
		status.text = "Could not save " + path
		return
	current.take_over_path(path)
	status.text = "Material saved to %s; load it for other decals to share it" % path

func material_spin(body: VBoxContainer, text: String, key: String, low: float, high: float, step: float) -> SpinBox:
	var field := spin(low, high, step)
	property(body, text, field)
	field.value_changed.connect(func(value): set_material(key, int(value) if step >= 1 else value, true))
	updaters.append(func(): if material() and not field.get_line_edit().has_focus(): field.set_value_no_signal(material().get(key)))
	return field

func set_material(key: String, value: Variant, merge: bool = false) -> void:
	var target := material()
	if not target:
		status.text = "The decal's material is not a StandardMaterial3D"
		return
	var old: Variant = target.get(key)
	if old == value: return
	var undo := editor_plugin.get_undo_redo()
	var scene := editor_plugin.get_editor_interface().get_edited_scene_root()
	undo.create_action("Decal material: %s" % key.capitalize(), UndoRedo.MERGE_ENDS if merge else UndoRedo.MERGE_DISABLE, decal if decal else scene)
	undo.add_do_property(target, key, value)
	undo.add_undo_property(target, key, old)
	undo.commit_action()
	refresh()

# ---- Placement ----------------------------------------------------------------------

# Decals of the current set placed in the edited scene.
func set_members() -> Array:
	var scene := editor_plugin.get_editor_interface().get_edited_scene_root() if editor_plugin else null
	if not scene: return []
	return scene.find_children("*", "MeshDecal3D", true, true).filter(func(item): return item.material_override == current_set)

# New Mesh Decal: earlier decals keep their materials; a fresh material is edited
# from now on and the next click places the new decal.
func new_decal() -> void:
	current_set = default_material()
	var selection := editor_plugin.get_editor_interface().get_selection()
	if decal: selection.clear()
	bind(null)
	set_placing(true)
	status.text = "New decal: click a surface to place it, set its material here. Esc stops placing."

func set_placing(on: bool) -> void:
	placing = on
	if is_instance_valid(place_button): place_button.set_pressed_no_signal(on)
	if is_instance_valid(status): status.text = "Click a surface in the 3D viewport to place a decal; Esc stops." if on else ""

# Viewport input while placing: a left click places a decal; Esc stops.
func viewport_input(camera: Camera3D, event: InputEvent) -> bool:
	if not placing: return false
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		set_placing(false)
		return true
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.alt_pressed:
		if event.pressed: place_at(camera, event.position)
		return true
	return false

func surface_hit(camera: Camera3D, mouse: Vector2) -> Dictionary:
	var scene := editor_plugin.get_editor_interface().get_edited_scene_root()
	var best := {}
	if not scene: return best
	var from := camera.project_ray_origin(mouse)
	var direction := camera.project_ray_normal(mouse)
	var candidates: Array = scene.find_children("*", "MeshInstance3D", true, true)
	if scene is MeshInstance3D: candidates.append(scene)
	for node in candidates:
		if node is MeshDecal3D or not node.is_visible_in_tree(): continue
		var hit: Dictionary = MeshDecal3D.raycast(node, from, direction)
		if hit.hit and (best.is_empty() or hit.distance < best.distance):
			best = hit
			best.node = node
	return best

func place_at(camera: Camera3D, mouse: Vector2) -> MeshDecal3D:
	var hit := surface_hit(camera, mouse)
	if hit.is_empty():
		status.text = "No surface under the cursor"
		return null
	var surface: MeshInstance3D = hit.node
	var scene := editor_plugin.get_editor_interface().get_edited_scene_root()
	# Z along the surface normal, X along the view's horizontal: the image reads upright.
	var z: Vector3 = Vector3(hit.normal).normalized()
	var x := camera.global_basis.x - z * camera.global_basis.x.dot(z)
	if x.length() < 0.01: x = z.cross(Vector3.UP if absf(z.y) < 0.9 else Vector3.RIGHT)
	x = x.normalized()
	var world := Transform3D(Basis(x, z.cross(x), z), hit.position)
	var created := MeshDecal3D.new()
	var count := 1
	while surface.has_node(NodePath("Decal%d" % count)): count += 1
	created.name = "Decal%d" % count
	created.transform = surface.global_transform.affine_inverse() * world
	created.size = defaults.size
	created.depth = defaults.depth
	created.offset = defaults.offset
	created.max_angle = defaults.max_angle
	created.source_mesh = defaults.source_mesh
	created.source_y_up = defaults.source_y_up
	created.target = NodePath("..")
	created.material_override = current_set
	var undo := editor_plugin.get_undo_redo()
	undo.create_action("Place decal", UndoRedo.MERGE_DISABLE, surface)
	undo.add_do_method(surface, "add_child", created, true)
	undo.add_do_method(created, "set_owner", scene)
	undo.add_do_reference(created)
	undo.add_undo_method(surface, "remove_child", created)
	undo.commit_action()
	status.text = "%s placed on %s. Click again for a copy; Esc stops." % [created.name, surface.name]
	refresh()
	return created

# ---- Bake ---------------------------------------------------------------------------

# Replaces decals by plain MeshInstance3D nodes (same name, place, mesh, material).
func bake(decals: Array) -> Array[MeshInstance3D]:
	var baked: Array[MeshInstance3D] = []
	var scene := editor_plugin.get_editor_interface().get_edited_scene_root()
	var undo := editor_plugin.get_undo_redo()
	undo.create_action("Bake decals", UndoRedo.MERGE_DISABLE, scene)
	for item in decals:
		var source := item as MeshDecal3D
		if not source or not source.mesh or not source.get_parent(): continue
		var parent := source.get_parent()
		var index := source.get_index()
		var plain := MeshInstance3D.new()
		plain.name = source.name
		plain.transform = source.transform
		plain.mesh = source.mesh.duplicate()
		plain.material_override = source.material_override
		plain.cast_shadow = source.cast_shadow
		undo.add_do_method(parent, "remove_child", source)
		undo.add_do_method(parent, "add_child", plain, true)
		undo.add_do_method(parent, "move_child", plain, index)
		undo.add_do_method(plain, "set_owner", scene)
		undo.add_do_reference(plain)
		undo.add_undo_method(parent, "remove_child", plain)
		undo.add_undo_method(parent, "add_child", source, true)
		undo.add_undo_method(parent, "move_child", source, index)
		undo.add_undo_method(source, "set_owner", scene)
		undo.add_undo_reference(source)
		baked.append(plain)
	if baked.is_empty():
		status.text = "No decals with geometry to bake"
		return baked
	undo.commit_action()
	status.text = "%d decal(s) baked to MeshInstance3D" % baked.size()
	return baked

# ---- Helpers ------------------------------------------------------------------------

func set_node_property(target: Object, key: String, value: Variant, label: String) -> void:
	var old: Variant = target.get(key)
	if old == value: return
	var undo := editor_plugin.get_undo_redo()
	undo.create_action(label, UndoRedo.MERGE_ENDS, target)
	undo.add_do_property(target, key, value)
	undo.add_undo_property(target, key, old)
	undo.commit_action()
	refresh()

func spin(low: float, high: float, step: float) -> SpinBox:
	var field := SpinBox.new()
	field.min_value = low
	field.max_value = high
	field.step = step
	field.allow_greater = true
	field.allow_lesser = low < 0
	field.select_all_on_focus = true
	field.custom_minimum_size.x = 0
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return field

func heading(parent: Control, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_override("font", editor_plugin.get_editor_interface().get_base_control().get_theme_font("bold", "EditorFonts"))
	parent.add_child(label)

func property(parent: Control, text: String, control: Control) -> Control:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var label := Label.new()
	label.text = text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.clip_text = true
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return control

func hint(parent: Control, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", editor_plugin.get_editor_interface().get_base_control().get_theme_color("font_readonly_color", "Editor"))
	parent.add_child(label)

func editor_style(name: String) -> StyleBox:
	var base := editor_plugin.get_editor_interface().get_base_control()
	return base.get_theme_stylebox(name, "EditorStyles") if base.has_theme_stylebox(name, "EditorStyles") else StyleBoxEmpty.new()

func editor_icon(name: String) -> Texture2D:
	var base := editor_plugin.get_editor_interface().get_base_control()
	return base.get_theme_icon(name, "EditorIcons") if base.has_theme_icon(name, "EditorIcons") else null
