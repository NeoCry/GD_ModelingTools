@tool
extends RefCounted
## Positive cotangent harmonic relaxation with fixed borders, run natively.
## Islands follow the UV canvas rule, so `islands` is only kept for the call signature.

static func apply(poly: PolyMesh, _islands: Array, selected: Dictionary, world: Transform3D, iterations: int) -> Dictionary:
	return poly.execute("uv_relax", PackedInt64Array(selected.keys()), {"world": world, "iterations": iterations})
