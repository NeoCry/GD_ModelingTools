@tool
extends RefCounted
const Selection = preload("res://addons/modeling_tool/editor/selection.gd")
var plugin: EditorPlugin
var mode := ""
var source := -1
var destination := -1
var painting := false
var mouse := Vector2.ZERO
var camera: Camera3D
var radius := 60.0
var pivot_mode := "vertex"
var pivot_hit := {}
var pivot_snap = preload("res://addons/modeling_tool/editor/snapping.gd").new()

func cancel() -> void:
	mode=""; source=-1; destination=-1; painting=false; pivot_hit={}
	if plugin:
		plugin.update_overlays()
		if is_instance_valid(plugin.target): plugin.target.update_gizmos()

func start(value: String) -> void:
	if mode==value: cancel(); return
	cancel()
	plugin._activate_selection_editing()
	if not is_instance_valid(plugin.target): return
	plugin.offset_tool.cancel(); plugin.cut_tool.cancel(); plugin.gizmo_plugin.cancel_drag()
	plugin.panel.set_mode("face" if value=="brush" else "vertex")
	mode=value
	if mode=="pivot":
		pivot_snap.vertices=true; pivot_snap.edges=true
		pivot_snap.begin(plugin.get_editor_interface().get_edited_scene_root(),null)
	plugin.target.update_gizmos()
	plugin.panel.report({"weld":"Weld: drag a vertex onto another; release to weld. Esc exits.","brush":"Brush: LMB adds polygons, Shift removes. Wheel changes radius. Esc exits.","pivot":"Pivot: click a vertex, edge or polygon. Esc exits."}[mode])
	plugin.update_overlays()

func input(view: Camera3D,event: InputEvent) -> bool:
	camera=view
	if event is InputEventKey and event.pressed and event.keycode==KEY_ESCAPE: cancel(); return true
	if event is InputEventMouse and event.alt_pressed: return false
	if event is InputEventMouseMotion or event is InputEventMouseButton: mouse=event.position
	var node: EditableMesh = plugin.target
	if mode=="weld":
		destination=Selection.pick(node,view,mouse,"vertex",plugin.panel.xray,plugin.panel.pick_radius)
		if event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_LEFT:
			if event.pressed: source=destination
			else:
				if source>=0 and destination>=0 and source!=destination: weld(source,destination)
				source=-1
	elif mode=="brush":
		if event is InputEventMouseButton:
			if event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP,MOUSE_BUTTON_WHEEL_DOWN]:
				radius=clampf(radius+(5 if event.button_index==MOUSE_BUTTON_WHEEL_UP else -5),5,500)
				plugin.panel.brush_radius.value=radius
			if event.button_index==MOUSE_BUTTON_LEFT: painting=event.pressed
		if painting and (event is InputEventMouseMotion or event is InputEventMouseButton): paint(view,mouse,event.shift_pressed)
	elif mode=="pivot":
		var shared: bool = plugin.snapping.has_geometry_targets()
		pivot_snap.vertices=plugin.snapping.vertices if shared else pivot_mode=="vertex"
		pivot_snap.edges=plugin.snapping.edges if shared else pivot_mode=="edge"
		pivot_snap.edge_centers=plugin.snapping.edge_centers
		pivot_snap.face_centers=plugin.snapping.face_centers
		pivot_hit=pivot_snap.pick(view,mouse,plugin.panel.pick_radius,Vector3.ZERO,Vector3.ZERO,plugin.panel.xray)
		if pivot_mode=="face" and not shared:
			var nearest := INF
			var origin:=view.project_ray_origin(mouse)
			var direction:=view.project_ray_normal(mouse)
			for mesh in pivot_snap.meshes:
				for i in range(0,mesh.triangles.size(),3):
					var hit=Geometry3D.ray_intersects_triangle(origin,direction,mesh.triangles[i],mesh.triangles[i+1],mesh.triangles[i+2])
					if hit!=null and origin.distance_to(hit)<nearest:
						nearest=origin.distance_to(hit); pivot_hit={"position":hit}
		if not shared and plugin.snapping.grid and not pivot_hit.is_empty():
			pivot_hit.position=plugin.Snapping.grid_position(pivot_hit.position,Vector3.ZERO,Vector3.ZERO,plugin.grid_step())
		if event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_LEFT and event.pressed and not pivot_hit.is_empty():
			set_pivot(node,pivot_hit.position)
	plugin.update_overlays()
	return event is InputEventMouseMotion or (event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_LEFT,MOUSE_BUTTON_WHEEL_UP,MOUSE_BUTTON_WHEEL_DOWN])

func weld(a: int,b: int) -> void:
	var poly: PolyMesh=plugin.target.poly_mesh
	var before:=poly.get_selected_vertices()
	var result:=poly.execute("merge",PackedInt64Array([a,b]),{"position":poly.get_vertex(b).position,"allow_non_manifold":true})
	if not result.ok: plugin.panel.report(result.error,true); return
	plugin._record_delta(poly,result.delta,"Weld",before,result.new_vertices)

func paint(view: Camera3D,point: Vector2,remove: bool) -> void:
	var node: EditableMesh=plugin.target
	var selected := {}
	for id in node.poly_mesh.get_selected_faces(): selected[id]=true
	var brushed: Dictionary=node.poly_mesh.faces_in_brush(view,node.global_transform,point,radius,plugin.panel.xray)
	var ids: Array=Array(brushed.faces)
	if int(brushed.hit)>=0: ids.append(int(brushed.hit))
	for id in ids:
		if remove: selected.erase(id)
		else: selected[id]=true
	node.poly_mesh.select("face",PackedInt64Array(selected.keys()),false)

func draw(control: Control) -> void:
	if not is_instance_valid(camera): return
	var ratio: Vector2=control.size/camera.get_viewport().get_visible_rect().size
	control.draw_set_transform(Vector2.ZERO,0,ratio)
	if mode=="brush": control.draw_arc(mouse,radius,0,TAU,64,Color("72bcff"),2,true)
	if not is_instance_valid(plugin.target):
		control.draw_set_transform(Vector2.ZERO)
		return
	var poly: PolyMesh=plugin.target.poly_mesh
	if mode=="weld":
		if source>=0 and not poly.get_vertex(source).is_empty():
			var start: Vector2=camera.unproject_position(plugin.target.global_transform*Vector3(poly.get_vertex(source).position))
			control.draw_line(start,mouse,Color.YELLOW,2,true)
		if destination>=0 and not poly.get_vertex(destination).is_empty():
			control.draw_circle(camera.unproject_position(plugin.target.global_transform*Vector3(poly.get_vertex(destination).position)),7,Color.YELLOW,false,2,true)
	if mode=="pivot" and not camera.is_position_behind(plugin.target.global_position):
		var origin:=camera.unproject_position(plugin.target.global_position)
		for axis in 3:
			var direction: Vector3=plugin.target.global_basis[axis].normalized()
			var projected:=camera.unproject_position(plugin.target.global_position+direction)-origin
			var end:=origin+projected.normalized()*42
			control.draw_line(origin,end,[Color.RED,Color.GREEN,Color.DODGER_BLUE][axis],3,true)
		control.draw_circle(origin,6,Color.WHITE,false,2,true)
	if mode=="pivot" and not pivot_hit.is_empty(): control.draw_circle(camera.unproject_position(pivot_hit.position),8,Color.CYAN,false,2,true)

	control.draw_set_transform(Vector2.ZERO)

static func mass_center(node: EditableMesh) -> Vector3:
	var triangles:=node.get_base_mesh().get_faces()
	var area:=0.0
	var volume:=0.0
	var surface:=Vector3.ZERO
	var solid:=Vector3.ZERO
	var closed:=node.poly_mesh.is_closed_manifold()
	for i in range(0,triangles.size(),3):
		var a:=triangles[i]; var b:=triangles[i+1]; var c:=triangles[i+2]
		var weight: float=(node.global_basis*(b-a)).cross(node.global_basis*(c-a)).length()*0.5
		area+=weight; surface+=(a+b+c)*weight/3.0
		var v: float=a.dot(b.cross(c))/6.0
		volume+=v; solid+=(a+b+c)*v/4.0
	var center:=solid/volume if closed and absf(volume)>1e-10 else surface/maxf(area,1e-10)
	return node.global_transform*center

func set_pivot(node: EditableMesh,world: Vector3) -> void:
	var old:=node.global_transform
	var next:=old; next.origin=world
	if absf(old.basis.determinant())<1e-10: plugin.panel.report("Cannot move pivot of a zero-scale object",true); return
	var original: PolyMesh=node.poly_mesh
	var poly:=original.clone()
	var result:=poly.execute("transform",poly.get_vertex_ids(),{"transform":next.affine_inverse()*old})
	if not result.ok: plugin.panel.report(result.error,true); return
	poly.clear_history()
	poly.select("vertex",original.get_selected_vertices())
	poly.select("edge",original.get_selected_edges())
	poly.select("face",original.get_selected_faces())
	var undo:=plugin.get_undo_redo()
	undo.create_action("Modeling: Move pivot",UndoRedo.MERGE_DISABLE,node)
	undo.add_do_method(self,"assign_poly",node,poly)
	undo.add_do_method(node,"set_modeling_global_transform",next)
	undo.add_undo_method(self,"assign_poly",node,original)
	undo.add_undo_method(node,"set_modeling_global_transform",old)
	for child in node.get_children():
		if child is Node3D:
			undo.add_do_property(child,"global_transform",child.global_transform)
			undo.add_undo_property(child,"global_transform",child.global_transform)
	undo.commit_action()
	plugin.panel.report("Pivot moved; world geometry preserved")

func assign_poly(node: EditableMesh,poly: PolyMesh) -> void:
	if plugin.target==node:
		var old:=node.poly_mesh
		if old.changed.is_connected(plugin._refresh): old.changed.disconnect(plugin._refresh)
		if old.selection_changed.is_connected(plugin._refresh): old.selection_changed.disconnect(plugin._refresh)
	node.poly_mesh=poly
	if plugin.target==node:
		poly.changed.connect(plugin._refresh)
		poly.selection_changed.connect(plugin._refresh)
		plugin._refresh()
	if is_instance_valid(plugin.uv_window) and plugin.uv_window.node==node: plugin.uv_window.canvas.bind_mesh(poly)

func merge_objects() -> void:
	var nodes:=plugin.get_editor_interface().get_selection().get_selected_nodes()
	var root: Node=plugin.get_editor_interface().get_edited_scene_root()
	if nodes.size()<2 or not root: plugin.panel.report("Select at least two mesh objects",true); return
	for node in nodes:
		if not node is MeshInstance3D or not node.mesh or node==root or node.skin:
			plugin.panel.report("Merge requires static mesh children of the scene",true); return
	var built:=combine(nodes)
	if not built.ok: plugin.panel.report(built.error,true); return
	var output:=EditableMesh.new()
	output.name="MergedMesh"; output.poly_mesh=built.poly
	if root is Node3D: output.transform=root.global_transform.affine_inverse()
	var undo:=plugin.get_undo_redo()
	undo.create_action("Modeling: Merge objects",UndoRedo.MERGE_DISABLE,root)
	undo.add_do_method(root,"add_child",output,true)
	undo.add_do_method(output,"set_owner",root)
	undo.add_do_reference(output)
	undo.add_undo_method(root,"remove_child",output)
	for node in nodes:
		undo.add_do_property(node,"visible",false)
		undo.add_undo_property(node,"visible",node.visible)
	undo.commit_action()
	var selection:=plugin.get_editor_interface().get_selection()
	selection.clear(); selection.add_node(output)
	plugin.panel.report("Meshes merged without welding; original objects hidden. Undo restores them.")

static func combine(nodes: Array, space: Transform3D=Transform3D.IDENTITY) -> Dictionary:
	var result:=PolyMesh.new()
	var materials: Array=[]
	for node in nodes:
		var poly: PolyMesh
		if node is EditableMesh:
			# Merged objects keep what their modifier stacks show.
			poly=node.poly_mesh
			var shown: Array=Array(node.modifiers).filter(func(m): return m and m.enabled)
			if not shown.is_empty():
				var evaluated: Dictionary=node.evaluate_modifiers(shown)
				if evaluated.ok: poly=evaluated.poly
		else:
			var mesh:=ArrayMesh.new()
			for surface in node.mesh.get_surface_count():
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,node.mesh.surface_get_arrays(surface))
				mesh.surface_set_material(surface,node.get_active_material(surface))
			poly=PolyMesh.new()
			var imported:=poly.from_array_mesh(mesh)
			if not imported.ok: return imported
		if not poly: return {"ok":false,"error":"Mesh has no editable geometry"}
		# Each material used by this mesh becomes one slot of the merged mesh.
		var material_map: Dictionary={}
		for material_id in poly.get_used_materials():
			material_map[material_id]=materials.size()
			var material: Material=node.material_override
			if not material and node is EditableMesh:
				for surface in node.mesh.get_surface_count():
					if node.mesh.surface_get_name(surface)=="Material_"+str(material_id): material=node.get_active_material(surface)
			if not material and material_id<poly.materials.size(): material=poly.materials[material_id]
			materials.append(material)
		result.append_mesh(poly,space*node.global_transform,material_map)
	result.materials=materials
	if not result.validate().is_empty(): return {"ok":false,"error":"Merged topology is invalid: "+result.validate()}
	result.clear_history()
	return {"ok":true,"poly":result}

func mirror_geometry(axis: int) -> void:
	var node: EditableMesh=plugin.target
	if not is_instance_valid(node) or not node.poly_mesh: return
	var reflected: PolyMesh=preload("res://addons/modeling_tool/editor/geometry_tools.gd").mirror(node.poly_mesh,axis)
	var undo:=plugin.get_undo_redo()
	undo.create_action("Modeling: Mirror "+["X","Y","Z"][axis],UndoRedo.MERGE_DISABLE,node)
	undo.add_do_method(self,"assign_poly",node,reflected)
	undo.add_undo_method(self,"assign_poly",node,node.poly_mesh)
	undo.commit_action()
	plugin.panel.report("Geometry mirrored around local pivot")

func separate_faces() -> void:
	var node: EditableMesh=plugin.target
	var root: Node=plugin.get_editor_interface().get_edited_scene_root()
	if not is_instance_valid(node) or not node.poly_mesh or node==root: return
	var ids:=node.poly_mesh.get_selected_faces()
	if ids.is_empty(): plugin.panel.report("Select polygons to separate",true); return
	var helper=preload("res://addons/modeling_tool/editor/geometry_tools.gd")
	var remainder:=PackedInt64Array()
	for fid in node.poly_mesh.get_face_ids():
		if fid not in ids: remainder.append(fid)
	var output:=EditableMesh.new()
	output.name=str(node.name)+"_Separated"
	output.poly_mesh=helper.subset(node.poly_mesh,ids)
	output.transform=node.transform; output.material_override=node.material_override
	var kept: PolyMesh=helper.subset(node.poly_mesh,remainder,true)
	var overrides: Array=[]
	var material_ids: Array=[]
	for fid in node.poly_mesh.get_face_ids():
		var material: int=node.poly_mesh.get_face(fid).material
		if material not in material_ids: material_ids.append(material)
	material_ids.sort()
	for surface in node.get_surface_override_material_count():
		var override_material:=node.get_surface_override_material(surface)
		overrides.append(override_material)
		if override_material and surface<material_ids.size():
			var id: int=material_ids[surface]
			for poly in [kept,output.poly_mesh]:
				var materials: Array=poly.materials.duplicate()
				if materials.size()<=id: materials.resize(id+1)
				materials[id]=override_material; poly.materials=materials
	var parent:=node.get_parent()
	var undo:=plugin.get_undo_redo()
	undo.create_action("Modeling: Separate polygons",UndoRedo.MERGE_DISABLE,node)
	undo.add_do_method(self,"assign_mesh_state",node,kept,[])
	undo.add_undo_method(self,"assign_mesh_state",node,node.poly_mesh,overrides)
	undo.add_do_method(parent,"add_child",output,true)
	undo.add_do_method(output,"set_owner",root)
	undo.add_do_reference(output)
	undo.add_undo_method(parent,"remove_child",output)
	undo.commit_action()
	plugin.panel.report("Selected polygons separated into "+str(output.name))

func assign_mesh_state(node: EditableMesh, poly: PolyMesh, overrides: Array) -> void:
	assign_poly(node,poly)
	for surface in node.get_surface_override_material_count():
		node.set_surface_override_material(surface,overrides[surface] if surface<overrides.size() else null)

