@tool
extends RefCounted
## UV projections run natively: cube, cylinder, sphere and planar.

static func project(poly: PolyMesh, ids: PackedInt64Array, kind: String, plane: String = "auto") -> Dictionary:
	return poly.execute("uv_project", ids, {"kind": kind, "plane": plane})

# One shared projection frame for the selection; uniform scaling preserves aspect.
static func planar(poly: PolyMesh, ids: PackedInt64Array, plane: String) -> Dictionary:
	return poly.execute("uv_project", ids, {"kind": "planar", "plane": plane})
