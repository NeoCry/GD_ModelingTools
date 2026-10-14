@tool
extends RefCounted

static func signed_area(uv: PackedVector2Array) -> float:
	var area := 0.0
	for i in range(1,uv.size()-1): area+=(uv[i]-uv[0]).cross(uv[i+1]-uv[0])
	return area*0.5

# Ignore collapsed faces. Mixed winding is a fold and cannot be fixed by mirroring
# an entire island without turning its other faces inside out.
static func is_flipped(island: Array, faces: Dictionary, preview: Dictionary = {}) -> bool:
	var negative := false
	for id in island:
		var uv: PackedVector2Array=preview.get(id,faces[id])
		var extent := Vector2.ZERO
		for point in uv: extent=extent.max((point-uv[0]).abs())
		var tolerance := extent.length_squared()*1e-10
		var area := signed_area(uv)
		if area>tolerance: return false
		if area < -tolerance: negative=true
	return negative

# The operators below run natively; islands follow the UV canvas rule, so the
# `islands` arguments are only kept for the call signatures.
static func flip_islands(poly: PolyMesh, _islands: Array, selected: Dictionary) -> Dictionary:
	return poly.execute("uv_flip", PackedInt64Array(selected.keys()), {})

static func stitch_split(poly: PolyMesh, points: Dictionary, edges: Dictionary, split: bool) -> Dictionary:
	return poly.execute("uv_split" if split else "uv_stitch", PackedInt64Array(), {"points": points.keys(), "edges": edges.keys()})

static func apply_density(poly: PolyMesh, _islands: Array, selected: Dictionary, transform: Transform3D, resolution: Vector2, target: float) -> Dictionary:
	return poly.execute("uv_density", PackedInt64Array(selected.keys()), {"world": transform, "resolution": resolution, "target": target})

static func align_islands(poly: PolyMesh, _islands: Array, selected: Dictionary, world: Transform3D, resolution: Vector2, vertical: bool) -> Dictionary:
	return poly.execute("uv_align", PackedInt64Array(selected.keys()), {"world": world, "resolution": resolution, "vertical": vertical})

static func straighten_islands(poly: PolyMesh, selected: Dictionary, world: Transform3D) -> Dictionary:
	return poly.execute("uv_straighten", PackedInt64Array(selected.keys()), {"world": world})

static func reunwrap_islands(poly: PolyMesh, selected: Dictionary, world: Transform3D) -> Dictionary:
	return poly.execute("uv_reunwrap", PackedInt64Array(selected.keys()), {"world": world})
