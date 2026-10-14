@tool
extends RefCounted

# Render a private mesh during a drag. The editable resource and its undo history
# remain untouched until the canvas emits its final edit.
var target: EditableMesh
var source: PolyMesh
var scratch: PolyMesh
var original: Mesh
var rendered: Mesh

func update(node: EditableMesh, coordinates: Dictionary) -> void:
	if coordinates.is_empty():
		clear()
		return
	if not is_instance_valid(node) or not node.is_inside_tree():
		clear()
		return
	if target!=node or source!=node.poly_mesh or scratch==null:
		clear()
		target=node
		source=node.poly_mesh
		original=node.mesh
		scratch=source.clone()
		scratch.history_limit=0
	var result := scratch.execute("uv_coordinates",PackedInt64Array(coordinates.keys()),{"coordinates":coordinates})
	if not result.ok:
		clear()
		return
	rendered=scratch.to_array_mesh()
	target.mesh=rendered

func clear() -> void:
	# External edits may already have rebuilt the mesh. Never overwrite those.
	if is_instance_valid(target) and target.poly_mesh==source and target.mesh==rendered:
		target.mesh=original
	target=null
	source=null
	scratch=null
	original=null
	rendered=null
