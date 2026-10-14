@tool
extends RefCounted
var enabled:=false
var placing:=false
var frame:=Transform3D.IDENTITY
var step:=1.0
var align_objects:=false
var hit: Variant=null
var scene: Node
var color:=Color(0.25,0.8,1)
var extent:=15

static func face_frame(node: EditableMesh, fid: int) -> Transform3D:
	var face:=node.poly_mesh.get_face(fid)
	var center:=Vector3.ZERO
	for vid in face.vertices: center+=node.global_transform*Vector3(node.poly_mesh.get_vertex(vid).position)
	center/=face.vertices.size()
	var normal: Vector3=(node.global_transform.basis.inverse().transposed()*Vector3(face.normal)).normalized()
	var tangent:=Vector3.ZERO
	for i in face.vertices.size():
		var a: Vector3=node.global_transform*Vector3(node.poly_mesh.get_vertex(face.vertices[i]).position)
		var b: Vector3=node.global_transform*Vector3(node.poly_mesh.get_vertex(face.vertices[(i+1)%face.vertices.size()]).position)
		var edge: Vector3=(b-a)-normal*(b-a).dot(normal)
		if edge.length_squared()>tangent.length_squared(): tangent=edge
	tangent=tangent.normalized()
	return Transform3D(Basis(tangent,normal,tangent.cross(normal).normalized()),center)

func snap(point: Vector3) -> Vector3:
	var local:=frame.affine_inverse()*point
	return frame*Vector3(snappedf(local.x,step),0,snappedf(local.z,step))

func input(plugin: EditorPlugin, camera: Camera3D, event: InputEvent) -> bool:
	if not placing: return false
	if event is InputEventKey and event.pressed and event.keycode==KEY_ESCAPE:
		placing=false; hit=null; plugin.update_overlays(); return true
	if event is InputEventMouse and not event.alt_pressed:
		var plane:=Plane(frame.basis.y,frame.origin)
		hit=plane.intersects_ray(camera.project_ray_origin(event.position),camera.project_ray_normal(event.position))
		if hit!=null: hit=snap(hit)
		plugin.update_overlays()
		if event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_LEFT:
			if event.pressed and hit!=null: place(plugin,hit)
			return true
	return false

func place(plugin: EditorPlugin, point: Vector3) -> void:
	var selected:=plugin.get_editor_interface().get_selection().get_selected_nodes()
	var nodes: Array[Node3D]=[]
	for node in selected:
		if not node is Node3D or node==scene: continue
		var nested:=false
		for other in selected:
			if other!=node and other.is_ancestor_of(node): nested=true
		if not nested: nodes.append(node)
	if nodes.is_empty(): plugin.panel.report("Select an object to place on the working grid",true); return
	var delta: Vector3=point-nodes[0].global_position
	var undo:=plugin.get_undo_redo()
	undo.create_action("Place on Working Grid",UndoRedo.MERGE_DISABLE,scene)
	for node in nodes:
		var value:=node.global_transform
		value.origin+=delta
		if align_objects: value.basis=frame.basis*Basis.from_scale(value.basis.get_scale())
		if node.get_parent() is Node3D and not node.top_level: value=node.get_parent().global_transform.affine_inverse()*value
		undo.add_do_property(node,"transform",value)
		undo.add_undo_property(node,"transform",node.transform)
	undo.commit_action()
	placing=false; hit=null
	plugin.update_overlays()
	plugin.panel.report("Placed on working grid. Undo restores the transform.")

func draw(control: Control,camera: Camera3D) -> void:
	if not enabled or not camera: return
	var ratio:=control.size/camera.get_viewport().get_visible_rect().size
	for i in range(-extent,extent+1):
		for axis in 2:
			var a:=frame* (Vector3(i*step,0,-extent*step) if axis==0 else Vector3(-extent*step,0,i*step))
			var b:=frame* (Vector3(i*step,0,extent*step) if axis==0 else Vector3(extent*step,0,i*step))
			if camera.is_position_behind(a) or camera.is_position_behind(b): continue
			control.draw_line(camera.unproject_position(a)*ratio,camera.unproject_position(b)*ratio,Color(color,0.85 if i==0 else 0.35),2 if i==0 else 1,true)
	if hit!=null and not camera.is_position_behind(hit): control.draw_circle(camera.unproject_position(hit)*ratio,5,Color.YELLOW)
