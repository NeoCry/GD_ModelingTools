@tool
extends RefCounted
const Topology = preload("res://addons/modeling_tool/editor/topology_tools.gd")
const Selection = preload("res://addons/modeling_tool/editor/selection.gd")
var plugin: EditorPlugin
var kind := ""
var seed := -1
var topology := {}
var sliding := false
var ratio := 0.5
var count := 1
var slide_start := 0.5
var anchor := {}
var segments: Array = []
var pending: Array = []
var preview: MeshInstance3D

func start(owner_plugin: EditorPlugin, tool: String) -> void:
	cancel()
	plugin = owner_plugin
	kind = tool
	plugin.gizmo_plugin.cancel_drag()
	plugin._clear_hover()
	# Detect external edits while the modal preview is active.
	plugin.target.poly_mesh.changed.connect(_mesh_changed)
	preview = MeshInstance3D.new()
	preview.name = "_ModelingCutPreview"
	preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	plugin.target.add_child(preview,false,Node.INTERNAL_MODE_BACK)
	plugin.target.update_gizmos()
	plugin.update_overlays()
	plugin.panel.report("Split Edge: hover to position; click or Enter: apply; Esc: cancel" if kind == "split_edge" else "Loop Cut: hover an edge; wheel: count; click: slide; Esc: cancel" if kind == "loop_cut" else "Knife: click an edge/vertex, click a path ending on an edge; Enter: apply; RMB: new path; Esc: cancel")

func _mesh_changed() -> void:
	cancel()

func cancel() -> void:
	if is_instance_valid(plugin) and is_instance_valid(plugin.target) and plugin.target.poly_mesh:
		if plugin.target.poly_mesh.changed.is_connected(_mesh_changed): plugin.target.poly_mesh.changed.disconnect(_mesh_changed)
	kind = ""
	seed = -1
	topology = {}
	sliding = false
	ratio = 0.5
	count = 1
	anchor = {}
	segments = []
	pending = []
	if is_instance_valid(preview): preview.queue_free()
	preview = null
	if is_instance_valid(plugin):
		if is_instance_valid(plugin.target): plugin.target.update_gizmos()
		plugin.update_overlays()

func update(camera: Camera3D, mouse: Vector2, snap: bool = false) -> void:
	if kind == "": return
	var node: EditableMesh = plugin.target
	var lines := PackedVector3Array()
	var markers := PackedVector3Array()
	if kind == "split_edge":
		seed=Selection.pick(node,camera,mouse,"edge",plugin.panel.xray,plugin.panel.pick_radius)
		if seed>=0:
			ratio=clampf(Topology.edge_ratio(node,camera,seed,mouse),0.001,0.999)
			if snap: ratio=clampf(snappedf(ratio,0.1),0.001,0.999)
			markers.append(Topology.edge_point(node.poly_mesh,seed,ratio))
		plugin.panel.report("Split edge: %.1f%% — click/Enter to apply" % (ratio*100))
	elif kind == "loop_cut":
		if not sliding:
			var hit := Selection.pick(node,camera,mouse,"edge",false,plugin.panel.pick_radius)
			if hit != seed:
				seed = hit
				topology = Topology.ring(node.poly_mesh,seed)
		else:
			ratio = clampf(0.5+Topology.edge_ratio(node,camera,seed,mouse)-slide_start,0.01,0.99)
			if snap: ratio = clampf(snappedf(ratio,0.1),0.01,0.99)
		lines = Topology.ring_lines(node.poly_mesh,topology,ratio,count)
		plugin.panel.report("Split Edge: hover to position; click or Enter: apply; Esc: cancel" if kind == "split_edge" else "Loop Cut: %d cut(s), slide %.2f; click/Enter: apply; RMB: center; Esc: cancel" % [count,ratio] if sliding else "Loop Cut: %d cut(s); hover a quad edge, wheel: count, click: slide" % count)
		if not sliding and seed >= 0 and topology.is_empty():
			plugin.panel.report("Loop Cut runs through quads and stops at triangles and n-gons; this edge has no quad. Imported meshes: Untriangulate first",true)
	else:
		pending = Topology.knife_stroke(node,camera,anchor,mouse,plugin.panel.pick_radius) if not anchor.is_empty() else []
		for segment in segments + pending:
			lines.append(segment.a.position)
			lines.append(segment.b.position)
			markers.append(segment.a.position)
			markers.append(segment.b.position)
		var point := Topology.knife_point(node,camera,mouse,plugin.panel.pick_radius,not anchor.is_empty())
		if not point.is_empty(): markers.append(point.position)
		if not anchor.is_empty(): markers.append(anchor.position)
	preview.mesh = Topology.preview_mesh(lines,markers)
	plugin.update_overlays()

func input(camera: Camera3D, event: InputEvent) -> bool:
	if kind == "": return false
	if event is InputEventKey:
		if not event.pressed or event.echo: return true
		if event.keycode == KEY_ESCAPE:
			cancel()
			plugin.panel.report("Cut cancelled")
		elif event.keycode in [KEY_ENTER,KEY_KP_ENTER,KEY_SPACE]:
			if kind == "knife" or sliding or (kind=="split_edge" and seed>=0): commit()
		return true
	if event is InputEventMouseMotion:
		if event.alt_pressed or event.button_mask & MOUSE_BUTTON_MASK_MIDDLE: return false
		update(camera,event.position,event.ctrl_pressed)
		return true
	if event is InputEventMouseButton:
		if event.alt_pressed or event.button_index == MOUSE_BUTTON_MIDDLE: return false
		if not event.pressed: return true
		if event.button_index in [MOUSE_BUTTON_WHEEL_UP,MOUSE_BUTTON_WHEEL_DOWN]:
			if kind == "loop_cut" and not sliding:
				count = clampi(count + (1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1),1,64)
				update(camera,event.position)
			return true
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if kind=="split_edge": cancel(); return true
			if kind == "loop_cut":
				if sliding:
					ratio = 0.5
					commit()
				else: cancel()
			else:
				# Discard only the unfinished tail of a path. Completed cuts remain staged.
				while not segments.is_empty() and segments[-1].b.has("face"): segments.pop_back()
				anchor = {}
				pending = []
				update(camera,event.position)
			return true
		if event.button_index == MOUSE_BUTTON_LEFT:
			update(camera,event.position,event.ctrl_pressed)
			if kind=="split_edge":
				if seed>=0: commit()
				return true
			if kind == "loop_cut":
				if topology.is_empty(): return true
				if sliding: commit()
				else:
					sliding = true
					slide_start = Topology.edge_ratio(plugin.target,camera,seed,event.position)
					update(camera,event.position)
			else:
				if anchor.is_empty():
					anchor = Topology.knife_point(plugin.target,camera,event.position,plugin.panel.pick_radius)
				elif not pending.is_empty():
					segments.append_array(pending)
					anchor = pending[-1].b.duplicate()
					pending = []
				update(camera,event.position)
			return true
	return true

func commit() -> void:
	var poly: PolyMesh = plugin.target.poly_mesh
	var before := Selection.selected_ids(poly,plugin.panel.mode)
	var operation := kind
	var options := {"ratio":ratio,"cuts":count} if kind in ["loop_cut","split_edge"] else {"segments":segments.duplicate(true)}
	var ids := PackedInt64Array([seed]) if kind in ["loop_cut","split_edge"] else PackedInt64Array()
	if kind == "knife" and segments.is_empty():
		plugin.panel.report("Knife: confirm at least one edge-to-edge segment before Enter",true)
		return
	if kind == "knife" and segments[-1].b.has("face"):
		plugin.panel.report("Finish the path on an edge or vertex before Enter",true)
		return
	cancel()
	var result := poly.execute(operation if operation in ["loop_cut","split_edge"] else "knife_segments",ids,options)
	if not result.ok:
		plugin.panel.report(result.error,true)
		return
	var key: String = {"vertex":"new_vertices","edge":"new_edges","face":"new_faces"}[plugin.panel.mode]
	plugin._record_delta(poly,result.delta,operation,before,result[key])
