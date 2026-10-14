@tool
extends RefCounted
## Thin wrappers over the native PolyMesh geometry operators.

static func subset(poly: PolyMesh, ids: PackedInt64Array, keep_loose: bool=false) -> PolyMesh:
	return poly.extract(ids, keep_loose)

static func mirror(poly: PolyMesh, axis: int) -> PolyMesh:
	return poly.mirrored(axis)

static func symmetric_positions(poly: PolyMesh, positions: Dictionary, axes: Array, center: Vector3 = Vector3.ZERO) -> Dictionary:
	return poly.symmetric_positions(positions, axes, center)

# `clip`: extra options, e.g. Mirror clipping ({clip_axes, clip_center, clip_distance}).
static func transform(poly: PolyMesh, ids: PackedInt64Array, value: Transform3D, clip: Dictionary = {}) -> Dictionary:
	var options := {"transform": value}
	options.merge(clip)
	return poly.execute("transform", ids, options)

static func slide(poly: PolyMesh, ids: PackedInt64Array, factor: float, clip: Dictionary = {}) -> Dictionary:
	var options := {"factor": factor}
	options.merge(clip)
	return poly.execute("slide_edges", ids, options)

static func vertex_rails(poly: PolyMesh, id: int) -> Array:
	return Array(poly.get_vertex_rails(id))

static func slide_vertices(poly: PolyMesh, ids: PackedInt64Array, factor: float, rail: int, clip: Dictionary = {}) -> Dictionary:
	var options := {"factor": factor, "rail": rail}
	options.merge(clip)
	return poly.execute("slide_vertices", ids, options)
