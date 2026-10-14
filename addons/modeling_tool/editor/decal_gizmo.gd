@tool
extends EditorNode3DGizmoPlugin
## MeshDecal3D projection box: the decal rectangle, the box it projects through
## (±depth along its Z) and the projection direction.

func _init() -> void:
	create_material("decal", Color(0.35, 0.8, 1.0, 0.9), false, true)

func _has_gizmo(node: Node3D) -> bool:
	return node is MeshDecal3D

func _get_gizmo_name() -> String:
	return "Mesh Decal"

func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var decal := gizmo.get_node_3d() as MeshDecal3D
	if not decal: return
	var hx: float = decal.size.x * 0.5
	var hy: float = decal.size.y * 0.5
	var lines := PackedVector3Array()
	for z in [-decal.depth, 0.0, decal.depth]:
		var corners := [Vector3(-hx, -hy, z), Vector3(hx, -hy, z), Vector3(hx, hy, z), Vector3(-hx, hy, z)]
		for i in 4: lines.append_array([corners[i], corners[(i + 1) % 4]])
	for corner in [Vector3(-hx, -hy, 0), Vector3(hx, -hy, 0), Vector3(hx, hy, 0), Vector3(-hx, hy, 0)]:
		lines.append_array([corner + Vector3(0, 0, decal.depth), corner - Vector3(0, 0, decal.depth)])
	# Projection direction (-Z) and the top of the image (+Y).
	lines.append_array([Vector3(0, 0, decal.depth), Vector3(0, 0, -decal.depth)])
	lines.append_array([Vector3(0, hy, 0), Vector3(0, hy * 1.25, 0)])
	gizmo.add_lines(lines, get_material("decal", gizmo))
