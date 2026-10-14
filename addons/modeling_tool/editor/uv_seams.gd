@tool
extends RefCounted
## Seam unwrap (LSCM per chart) and texel density run natively.

static func density(poly: PolyMesh, ids: Array, transform: Transform3D, resolution: Vector2, preview: Dictionary = {}) -> Dictionary:
	return poly.measure_uv_density(PackedInt64Array(ids), transform, resolution, preview)

static func unwrap(poly: PolyMesh, face_ids: PackedInt64Array = PackedInt64Array(), seam_overrides: Dictionary = {}, commit: bool = true) -> Dictionary:
	if not commit: return poly.compute_seam_unwrap(face_ids, seam_overrides)
	return poly.execute("uv_unwrap", face_ids, {"seams": seam_overrides})
