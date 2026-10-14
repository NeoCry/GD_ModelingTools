@tool
extends RefCounted
## Correct the native editor's translation preview before its undo transaction commits.
var plugin: EditorPlugin
var active := false
var moved := false
var originals: Dictionary = {}
var camera: Camera3D
var mouse := Vector2.ZERO
var press := Vector2.ZERO
var ctrl := false
var pending := false

func clear() -> void:
	active = false
	moved = false
	pending = false
	originals.clear()
	if plugin:
		plugin.snapping.clear()
		plugin.update_overlays()

func input(view: Camera3D, event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		clear()
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		clear()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and not event.alt_pressed:
			clear()
			if not plugin.snapping.grid and not plugin.snapping.has_geometry_targets(): return
			var selected := plugin.get_editor_interface().get_selection().get_selected_nodes()
			for node in selected:
				if not node is Node3D or node.has_meta("_edit_lock_"): continue
				var parent_selected := false
				for other in selected:
					if other != node and other.is_ancestor_of(node): parent_selected = true
				if not parent_selected: originals[node] = node.global_transform
			active = not originals.is_empty()
			camera = view
			mouse = event.position
			press = event.position
			ctrl = event.ctrl_pressed
			plugin.snapping.begin(plugin.get_editor_interface().get_edited_scene_root(),null,selected)
		elif not event.pressed:
			# The editor records its final transform after forwarding this release.
			if pending: update_preview()
			clear()
	elif active and event is InputEventMouseMotion:
		if event.alt_pressed or not event.button_mask & MOUSE_BUTTON_MASK_LEFT: clear(); return
		camera = view
		mouse = event.position
		ctrl = event.ctrl_pressed
		if not pending:
			pending = true
			update_preview.call_deferred()

func update_preview() -> void:
	if not active or not pending: return
	pending = false
	var origin := Vector3.ZERO
	var delta := Vector3.ZERO
	var first := true
	for node in originals:
		if not is_instance_valid(node) or not node.is_inside_tree(): clear(); return
		var before: Transform3D = originals[node]
		# Rotation and scale belong entirely to the native editor.
		if not node.global_basis.is_equal_approx(before.basis): clear(); return
		var offset: Vector3 = node.global_position-before.origin
		if first: delta = offset; first = false
		elif not offset.is_equal_approx(delta): clear(); return
		origin += before.origin
	if originals.is_empty(): return
	origin /= originals.size()
	if delta.is_zero_approx() and not moved: return
	moved = true
	# Native axis drags are collinear with a world or local basis axis.
	# A drag from the pivot itself is free movement, including depth snapping.
	var axis := Vector3.ZERO
	if press.distance_to(camera.unproject_position(origin)) > 14 and not delta.is_zero_approx():
		for basis in [Basis.IDENTITY,(originals[originals.keys()[0]] as Transform3D).basis.orthonormalized()]:
			for i in 3:
				if delta.normalized().cross(basis[i]).length() < 0.0001: axis = basis[i]
	var hit: Dictionary = plugin.snapping.pick(camera,mouse,plugin.panel.pick_radius,origin,axis,plugin.panel.xray)
	var position := origin+delta
	if not hit.is_empty(): position = hit.snapped_position
	elif plugin.snapping.grid or ctrl:
		position = plugin.Snapping.grid_position(position,origin,axis,plugin.grid_step()*(0.1 if Input.is_key_pressed(KEY_SHIFT) else 1.0))
	for node in originals:
		var next: Transform3D = originals[node]
		next.origin += position-origin
		node.global_transform = next
	plugin.update_overlays()
