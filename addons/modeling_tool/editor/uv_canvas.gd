@tool
extends Control
const EditOps=preload("res://addons/modeling_tool/editor/uv_edit_ops.gd")
var highlight_flipped := true
signal edited(coordinates: Dictionary, before: Dictionary)
signal preview_changed(coordinates: Dictionary)
signal selection_changed(count: int)
signal user_selection_changed
var selection_tool := "box"
var brush_radius := 40.0
var selecting := false
var region_start := Vector2.ZERO
var region_end := Vector2.ZERO
var subtract_selection := false
var saved_selection := {}
var saved_points := {}
var edge_mode := false
var selected_uv_edges := {}
var saved_uv_edges := {}
var seam_edges := {}
var face_vertices := {}
var edge_faces := {}
var point_mode := false
var selected_points := {}
var poly: PolyMesh
var texture: Texture2D
var tile_atlas := true
var faces := {}
var islands: Array[Array] = []
var selected := {}
var mode := "move"
var zoom := 500.0
var origin := Vector2(60,60)
var dragging := false
var handle := ""
var hovered_handle := ""
var start := Vector2.ZERO
var pivot := Vector2.ZERO
var baseline := {}
var preview := {}

func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	clip_contents = true
	custom_minimum_size = Vector2(300,300)
	resized.connect(queue_redraw)

func bind_mesh(value: PolyMesh) -> void:
	cancel()
	if poly and poly.changed.is_connected(rebuild): poly.changed.disconnect(rebuild)
	poly = value
	selected.clear()
	selected_points.clear(); selected_uv_edges.clear()
	if poly: poly.changed.connect(rebuild)
	rebuild()
	fit.call_deferred()

func rebuild() -> void:
	cancel()
	faces.clear()
	islands.clear()
	face_vertices.clear()
	edge_faces.clear()
	if not poly: queue_redraw(); return
	seam_edges.clear()
	# Faces, corner UVs and islands come from one native query.
	var layout: Dictionary = poly.get_uv_layout()
	var seams: PackedInt64Array = layout.seams
	for i in range(0,seams.size(),2): seam_edges[Vector2i(seams[i],seams[i+1])]=true
	var ids: PackedInt64Array = layout.ids
	var offsets: PackedInt64Array = layout.offsets
	var vertices: PackedInt64Array = layout.vertices
	var uvs: PackedVector2Array = layout.uvs
	for i in ids.size():
		var id: int = ids[i]
		faces[id] = uvs.slice(offsets[i],offsets[i+1])
		face_vertices[id] = vertices.slice(offsets[i],offsets[i+1])
	for island in layout.islands: islands.append(Array(island))
	for key in selected_points.keys():
		if not faces.has(key.x) or key.y>=faces[key.x].size(): selected_points.erase(key)
	for key in selected_uv_edges.keys():
		if not faces.has(key.x) or key.y<0 or key.y>=faces[key.x].size(): selected_uv_edges.erase(key)
	for id in selected.keys():
		if not faces.has(id): selected.erase(id)
	queue_redraw()
	selection_changed.emit(selected.size())

func axis_scale() -> Vector2:
	if texture:
		var dimensions := texture.get_size()
		return dimensions/maxf(dimensions.x,dimensions.y)
	return Vector2.ONE

func to_screen(uv: Vector2) -> Vector2: return origin+uv*zoom*axis_scale()
func to_uv(point: Vector2) -> Vector2: return (point-origin)/(zoom*axis_scale())

func fit() -> void:
	var low := Vector2.ZERO
	var high := Vector2.ONE
	for coords in faces.values():
		for uv in coords: low = low.min(uv); high = high.max(uv)
	var extent := ((high-low)*axis_scale()).max(Vector2.ONE*0.001)
	zoom = maxf(10,minf((size.x-80)/extent.x,(size.y-80)/extent.y))
	origin = (size-extent*zoom)*0.5-low*axis_scale()*zoom
	queue_redraw()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO,size),Color("20242c"))
	var tile := Rect2(to_screen(Vector2.ZERO),Vector2.ONE*zoom*axis_scale())
	if texture:
		if tile_atlas:
			# One repeated draw covers the visible plane, including negative UV tiles.
			texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
			var scale_factor := tile.size / texture.get_size()
			var first := (to_uv(Vector2.ZERO)).floor()
			var last := (to_uv(size)).ceil()
			draw_set_transform(to_screen(first),0,scale_factor)
			draw_texture_rect(texture,Rect2(Vector2.ZERO,(last-first)*texture.get_size()),true)
			draw_set_transform(Vector2.ZERO,0,Vector2.ONE)
		else:
			texture_repeat = CanvasItem.TEXTURE_REPEAT_DISABLED
			draw_texture_rect(texture,tile,false)
	else:
		for y in 16:
			for x in 16:
				draw_rect(Rect2(tile.position+Vector2(x,y)*tile.size/16,tile.size/16),Color("424650") if (x+y)%2 else Color("343842"))
	draw_rect(tile,Color("8b94a3"),false,1)
	var flipped := {}
	if highlight_flipped:
		for island in islands:
			if EditOps.is_flipped(island,faces,preview):
				for id in island: flipped[id]=true
	# Outlines and points are batched per color and drawn over all fills:
	# one draw_multiline per color instead of one draw_line per UV edge.
	var red_lines := PackedVector2Array()
	var purple_lines := PackedVector2Array()
	var green_lines := PackedVector2Array()
	var red_points := PackedVector2Array()
	var green_points := PackedVector2Array()
	for id in faces:
		var points := PackedVector2Array()
		for uv in preview.get(id,faces[id]): points.append(to_screen(uv))
		var on := selected.has(id)
		var area := 0.0
		for i in points.size(): area += points[i].cross(points[(i+1)%points.size()])
		var inverted := flipped.has(id)
		if (on or inverted) and absf(area)>0.0001:
			var indices := Geometry2D.triangulate_polygon(points)
			for i in range(0,indices.size(),3):
				draw_colored_polygon(PackedVector2Array([points[indices[i]],points[indices[i+1]],points[indices[i+2]]]),Color(0.75,0.25,1,0.4) if inverted else Color(1,0.15,0.1,0.2))
		for i in points.size():
			var next := points[(i+1)%points.size()]
			if (selected_uv_edges.has(Vector2i(id,i)) if edge_mode else on): red_lines.append(points[i]); red_lines.append(next)
			elif inverted: purple_lines.append(points[i]); purple_lines.append(next)
			else: green_lines.append(points[i]); green_lines.append(next)
		if on or point_mode:
			for i in points.size():
				if (selected_points.has(Vector2i(id,i)) if point_mode else on): red_points.append(points[i])
				else: green_points.append(points[i])
	for batch in [[green_lines,Color("70e6a1")],[purple_lines,Color("cd78ff")],[red_lines,Color("ff6557")]]:
		if not batch[0].is_empty(): draw_multiline(batch[0],batch[1],2,true)
	for point in green_points: draw_circle(point,4,Color("70e6a1"))
	for point in red_points: draw_circle(point,4,Color("ff6557"))

	draw_gizmo()
	if selection_tool == "brush": draw_arc(region_end,brush_radius,0,TAU,64,Color.WHITE,1.5,true)
	if selecting and selection_tool == "box":
		var rect := Rect2(region_start,region_end-region_start).abs()
		draw_rect(rect,Color(0.2,0.5,1,0.15))
		draw_rect(rect,Color("69b5ff"),false,1.5)

func pick(point: Vector2) -> int:
	var nearest := -1
	var distance := 9.0
	for index in range(islands.size()-1,-1,-1):
		for id in islands[index]:
			var coords: PackedVector2Array = faces[id]
			var points := PackedVector2Array()
			for uv in coords: points.append(to_screen(uv))
			if Geometry2D.is_point_in_polygon(point,points): return index
			for i in points.size():
				var d := Geometry2D.get_closest_point_to_segment(point,points[i],points[(i+1)%points.size()]).distance_to(point)
				if d<distance: distance=d; nearest=index
	return nearest

func select_all() -> void:
	cancel()
	selected.clear()
	for id in faces:
		selected[id] = true
		if point_mode:
			for i in faces[id].size():
				selected_points[Vector2i(id,i)]=true
				if edge_mode: selected_uv_edges[Vector2i(id,i)]=true
	queue_redraw()
	selection_changed.emit(selected.size())
	user_selection_changed.emit()

func cancel() -> void:
	if selecting:
		selected=saved_selection.duplicate(); selected_points=saved_points.duplicate(); selected_uv_edges=saved_uv_edges.duplicate(); selecting=false
		selection_changed.emit(selected.size()); user_selection_changed.emit()
	dragging = false
	handle = ""
	preview.clear()
	baseline.clear()
	preview_changed.emit({})
	queue_redraw()

func begin_drag(point: Vector2) -> void:
	baseline.clear()
	pivot = Vector2.ZERO
	var count := 0
	for id in selected:
		baseline[id] = faces[id].duplicate()
		for i in faces[id].size():
			if not point_mode or selected_points.has(Vector2i(id,i)): pivot+=faces[id][i]; count+=1
	if count == 0: return
	pivot /= count
	start = to_uv(point)
	dragging = true

func drag(point: Vector2, snap: bool) -> void:
	var current := to_uv(point)
	var offset := current-start
	var angle := (start-pivot).angle_to(current-pivot)
	var factor := clampf((current-pivot).length()/maxf((start-pivot).length(),0.001),0.01,100)
	if mode=="scale" and handle=="free": factor=clampf(1.0+(point-to_screen(start)).dot(Vector2(1,-1))/100.0,0.01,100)
	if handle == "u": offset.y=0
	if handle == "v": offset.x=0
	if snap:
		offset = offset.snapped(Vector2.ONE*0.01)
		angle = snappedf(angle,PI/12)
		factor = maxf(0.01,snappedf(factor,0.1))
	preview = transformed(baseline,pivot,offset if mode == "move" else Vector2.ZERO,angle if mode == "rotate" else 0,factor if mode == "scale" else 1)
	if mode=="scale" and handle in ["u","v"]:
		var axis := 0 if handle=="u" else 1
		factor=clampf((current[axis]-pivot[axis])/(start[axis]-pivot[axis]),0.01,100)
		if snap: factor=maxf(0.01,snappedf(factor,0.1))
		for id in baseline:
			var values := PackedVector2Array()
			for uv in baseline[id]:
				var value: Vector2 = uv-pivot
				value[axis]*=factor
				values.append(pivot+value)
			preview[id]=values
	preview=mask_transform(preview,baseline)
	preview_changed.emit(preview)
	queue_redraw()

static func transformed(source: Dictionary, center: Vector2, offset: Vector2, angle: float, factor: float) -> Dictionary:
	var result := {}
	for id in source:
		var coords := PackedVector2Array()
		for uv in source[id]: coords.append(center+(uv-center).rotated(angle)*factor+offset)
		result[id] = coords
	return result

func finish() -> void:
	if not dragging: return
	var coords := preview.duplicate(true)
	var before := baseline.duplicate(true)
	cancel()
	if not coords.is_empty() and coords != before: edited.emit(coords,before)

func _gui_input(event: InputEvent) -> void:
	if region_input(event): return
	if event is InputEventMouseButton:
		if event.button_index in [MOUSE_BUTTON_WHEEL_UP,MOUSE_BUTTON_WHEEL_DOWN] and event.pressed:
			var anchor := to_uv(event.position)
			zoom = clampf(zoom*(1.15 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1/1.15),5,30000)
			origin = event.position-anchor*zoom*axis_scale()
			queue_redraw()
			accept_event()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			grab_focus()
			if event.pressed:
				var gizmo_hit := pick_gizmo(event.position)
				if gizmo_hit!="" and not event.shift_pressed:
					begin_drag(event.position)
					handle=gizmo_hit
					accept_event()
					return
				if point_mode:
					pick_points(event.position,event.shift_pressed)
					if not event.shift_pressed and not selected_points.is_empty(): begin_drag(event.position)
					selection_changed.emit(selected.size())
					user_selection_changed.emit()
					queue_redraw(); accept_event(); return
				var island := pick(event.position)
				if island<0:
					selected.clear()
				else:
					var ids := islands[island]
					if event.shift_pressed:
						var remove := selected.has(ids[0])
						for id in ids:
							if remove: selected.erase(id)
							else: selected[id]=true
					else:
						if not selected.has(ids[0]):
							selected.clear()
							for id in ids: selected[id]=true
						begin_drag(event.position)
				selection_changed.emit(selected.size())
				user_selection_changed.emit()
				queue_redraw()
			else: finish()
			accept_event()
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed: cancel(); accept_event()
	elif event is InputEventMouseMotion:
		if event.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			origin += event.relative
			queue_redraw()
		elif dragging: drag(event.position,event.ctrl_pressed)
		else:
			hovered_handle=pick_gizmo(event.position)
			queue_redraw()
		accept_event()
	elif event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ESCAPE: cancel()
			KEY_A: select_all()
			KEY_F: fit()
			_: return
		accept_event()



func gizmo_center() -> Vector2:
	if dragging and mode != "move": return to_screen(pivot)
	var center := Vector2.ZERO
	var count := 0
	for id in selected:
		var coordinates: PackedVector2Array=preview.get(id,faces.get(id,PackedVector2Array()))
		for i in coordinates.size():
			if not point_mode or selected_points.has(Vector2i(id,i)): center+=coordinates[i]; count+=1
	return to_screen(center/maxi(count,1))

func pick_gizmo(point: Vector2) -> String:
	if selected.is_empty() or mode == "none": return ""
	var center := gizmo_center()
	var local := point-center
	if mode=="rotate": return "ring" if absf(local.length()-58)<9 else ""
	if local.length()<11: return "free"
	for axis in ["u","v"]:
		var end := center+(Vector2(72,0) if axis=="u" else Vector2(0,-72))
		if Geometry2D.get_closest_point_to_segment(point,center,end).distance_to(point)<9: return axis
	return ""

func draw_gizmo() -> void:
	if selected.is_empty() or mode == "none": return
	var center := gizmo_center()
	if mode=="rotate":
		draw_arc(center,58,0,TAU,96,Color.YELLOW if hovered_handle=="ring" or dragging else Color("69b5ff"),3,true)
		draw_circle(center,4,Color.WHITE)
		return
	for axis in ["u","v"]:
		var direction := Vector2.RIGHT if axis=="u" else Vector2.UP
		var end := center+direction*72
		var color := Color("ff615b") if axis=="u" else Color("73df89")
		if hovered_handle==axis or handle==axis: color=Color.YELLOW
		draw_line(center,end,Color("19202b"),6,true)
		draw_line(center,end,color,3,true)
		if mode=="scale": draw_rect(Rect2(end-Vector2.ONE*6,Vector2.ONE*12),color)
		else:
			var side := direction.orthogonal()*6
			draw_colored_polygon(PackedVector2Array([end+direction*4,end-direction*10+side,end-direction*10-side]),color)
		draw_string(ThemeDB.fallback_font,end+Vector2(9,-8),axis.to_upper(),HORIZONTAL_ALIGNMENT_LEFT,-1,14,color)
	draw_rect(Rect2(center-Vector2.ONE*7,Vector2.ONE*14),Color.YELLOW if hovered_handle=="free" or handle=="free" else Color.WHITE)

func clear_selection() -> void:
	cancel(); selected.clear(); selected_points.clear(); selected_uv_edges.clear()
	selection_changed.emit(0); user_selection_changed.emit(); queue_redraw()

func set_point_mode(enabled: bool) -> void:
	edge_mode=false
	point_mode=enabled
	clear_selection()

func mask_transform(result: Dictionary,source: Dictionary) -> Dictionary:
	if point_mode:
		for id in result:
			for i in result[id].size():
				if not selected_points.has(Vector2i(id,i)): result[id][i]=source[id][i]
	return result

func pick_points(point: Vector2,extend: bool) -> void:
	var picked:=Vector2i(-1,-1)
	var distance:=10.0
	for id in faces:
		for i in faces[id].size():
			var d: float=to_screen(faces[id][i]).distance_to(point)
			if d<distance: distance=d; picked=Vector2i(id,i)
	if picked.x<0:
		if not extend: selected_points.clear()
	else:
		var group:=point_component(picked)
		var remove:=extend and selected_points.has(picked)
		if not extend and not selected_points.has(picked): selected_points.clear()
		for key in group:
			if remove: selected_points.erase(key)
			else: selected_points[key]=true
	selected.clear()
	for key in selected_points: selected[key.x]=true

func set_selection_tool(value: String) -> void:
	cancel()
	selection_tool=value
	queue_redraw()

func region_input(event: InputEvent) -> bool:
	if selection_tool == "select" or dragging: return false
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed and not event.shift_pressed and not event.ctrl_pressed and pick_gizmo(event.position)!="": return false
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		grab_focus()
		if event.pressed:
			cancel()
			saved_selection=selected.duplicate(); saved_points=selected_points.duplicate(); saved_uv_edges=selected_uv_edges.duplicate()
			region_start=event.position; region_end=event.position
			subtract_selection=event.ctrl_pressed
			if not event.shift_pressed and not subtract_selection:
				selected.clear(); selected_points.clear(); selected_uv_edges.clear()
			selecting=true
			if selection_tool == "brush": region_select(region_start,region_end,true,subtract_selection)
		else:
			if selecting and selection_tool == "box": region_select(region_start,event.position,false,subtract_selection)
			selecting=false
		queue_redraw(); accept_event(); return true
	if event is InputEventMouseMotion:
		var previous := region_end
		region_end=event.position
		if selecting and selection_tool == "brush": region_select(previous,region_end,true,subtract_selection)
		queue_redraw()
		if selecting: accept_event(); return true
	return false

func region_select(a: Vector2,b: Vector2,circle: bool,remove: bool) -> void:
	if edge_mode:
		select_edge_region(a,b,circle,remove)
		return
	if point_mode and not circle and a.distance_to(b)<3:
		var previous:=selected_points.duplicate()
		selected_points.clear(); pick_points(b,false)
		var hits:=selected_points.keys(); selected_points=previous
		for key in hits:
			if remove: selected_points.erase(key)
			else: selected_points[key]=true
		selected.clear()
		for key in selected_points: selected[key.x]=true
		selection_changed.emit(selected.size()); user_selection_changed.emit(); queue_redraw()
		return
	var rect := Rect2(a,b-a).abs()
	if not circle and a.distance_to(b)<3: rect=rect.grow(5)
	var corners := PackedVector2Array([rect.position,Vector2(rect.end.x,rect.position.y),rect.end,Vector2(rect.position.x,rect.end.y)])
	for id in faces:
		var points := PackedVector2Array()
		for uv in faces[id]: points.append(to_screen(uv))
		var hit := false
		for i in points.size():
			var inside := Geometry2D.get_closest_point_to_segment(points[i],a,b).distance_to(points[i])<=brush_radius if circle else rect.has_point(points[i])
			if point_mode and inside:
				if remove: selected_points.erase(Vector2i(id,i))
				else: selected_points[Vector2i(id,i)]=true
			hit=hit or inside
		if point_mode: continue
		if circle:
			hit=hit or Geometry2D.is_point_in_polygon(b,points) or Geometry2D.is_point_in_polygon(a,points)
			for i in points.size():
				var p := points[i]; var q := points[(i+1)%points.size()]
				hit=hit or Geometry2D.segment_intersects_segment(a,b,p,q)!=null or Geometry2D.get_closest_point_to_segment(a,p,q).distance_to(a)<=brush_radius or Geometry2D.get_closest_point_to_segment(b,p,q).distance_to(b)<=brush_radius
		else:
			for corner in corners: hit=hit or Geometry2D.is_point_in_polygon(corner,points)
			for i in points.size():
				for j in 4: hit=hit or Geometry2D.segment_intersects_segment(points[i],points[(i+1)%points.size()],corners[j],corners[(j+1)%4])!=null
		if hit:
			for island in islands:
				if id in island:
					for fid in island:
						if remove: selected.erase(fid)
						else: selected[fid]=true
					break
	if point_mode:
		selected.clear()
		for key in selected_points: selected[key.x]=true
	selection_changed.emit(selected.size()); user_selection_changed.emit(); queue_redraw()

func uv_seam(a: int,b: int) -> bool:
	return seam_edges.has(Vector2i(mini(a,b),maxi(a,b)))

func same_island(a: int,b: int) -> bool:
	for island in islands:
		if a in island: return b in island
	return false

func set_component_mode(index: int) -> void:
	set_point_mode(index!=0)
	edge_mode=index==2

func select_edge_region(a: Vector2,b: Vector2,circle: bool,remove: bool) -> void:
	var click:=not circle and a.distance_to(b)<3
	var nearest:=Vector2i(-1,-1); var best:=8.0
	if click:
		for fid in faces:
			for i in faces[fid].size():
				var p:=to_screen(faces[fid][i]); var q:=to_screen(faces[fid][(i+1)%faces[fid].size()])
				var distance:=Geometry2D.get_closest_point_to_segment(b,p,q).distance_to(b)
				if distance<best: best=distance; nearest=Vector2i(fid,i)
	var rect:=Rect2(a,b-a).abs().grow(5 if a.distance_to(b)<3 else 0)
	var corners: Array[Vector2]=[rect.position,Vector2(rect.end.x,rect.position.y),rect.end,Vector2(rect.position.x,rect.end.y)]
	for fid in faces:
		for i in faces[fid].size():
			var p:=to_screen(faces[fid][i]); var q:=to_screen(faces[fid][(i+1)%faces[fid].size()])
			var hit:=false
			if circle:
				hit=Geometry2D.segment_intersects_segment(a,b,p,q)!=null or Geometry2D.get_closest_point_to_segment(b,p,q).distance_to(b)<=brush_radius or Geometry2D.get_closest_point_to_segment(p,a,b).distance_to(p)<=brush_radius or Geometry2D.get_closest_point_to_segment(q,a,b).distance_to(q)<=brush_radius
			else:
				hit=rect.has_point(p) or rect.has_point(q)
				for j in 4: hit=hit or Geometry2D.segment_intersects_segment(p,q,corners[j],corners[(j+1)%4])!=null
			if click: hit=Vector2i(fid,i)==nearest
			if hit:
				var key:=Vector2i(fid,i)
				if remove: selected_uv_edges.erase(key)
				else: selected_uv_edges[key]=true
	selected_points.clear(); selected.clear()
	for key in selected_uv_edges:
		selected[key.x]=true
		for endpoint in [key,Vector2i(key.x,(key.y+1)%faces[key.x].size())]:
			for corner in point_component(endpoint): selected_points[corner]=true; selected[corner.x]=true
	selection_changed.emit(selected.size()); user_selection_changed.emit(); queue_redraw()

func _build_edge_faces() -> void:
	# Built on demand: only point/edge UV selection walks across shared edges.
	for id in face_vertices:
		var corners: PackedInt64Array = face_vertices[id]
		for j in corners.size():
			var key := Vector2i(mini(corners[j],corners[(j+1)%corners.size()]),maxi(corners[j],corners[(j+1)%corners.size()]))
			if not edge_faces.has(key): edge_faces[key] = []
			edge_faces[key].append(id)

func point_component(seed: Vector2i) -> Array:
	if edge_faces.is_empty(): _build_edge_faces()
	var vertex: int=face_vertices[seed.x][seed.y]
	var uv: Vector2=faces[seed.x][seed.y]
	var group: Array=[]; var visited := {}; var stack: Array=[seed.x]
	while not stack.is_empty():
		var fid: int=stack.pop_back()
		if visited.has(fid): continue
		visited[fid]=true
		var corners: PackedInt64Array=face_vertices[fid]; var i: int=corners.find(vertex)
		if i<0 or faces[fid][i].distance_to(uv)>0.00001: continue
		group.append(Vector2i(fid,i))
		# Continue across the two non-seam edges that meet at this corner.
		for other in [corners[(i+1)%corners.size()],corners[(i+corners.size()-1)%corners.size()]]:
			var key := Vector2i(mini(vertex,other),maxi(vertex,other))
			if seam_edges.has(key): continue
			for neighbor in edge_faces.get(key,[]):
				if neighbor!=fid: stack.append(neighbor)
	return group
