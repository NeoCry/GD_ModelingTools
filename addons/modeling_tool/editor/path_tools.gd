@tool
extends RefCounted
## Edge chains to Path3D curves, and path sampling for Extrude Along Path.

# Ordered vertex chains of the selected edges: [{vertices, closed}], or
# {error} when a vertex joins more than two selected edges.
static func chains(poly: PolyMesh, edge_ids: PackedInt64Array) -> Variant:
	var neighbours := {}
	for eid in edge_ids:
		var edge := poly.get_edge(eid)
		if edge.is_empty(): continue
		for pair in [[edge.vertex_a, edge.vertex_b], [edge.vertex_b, edge.vertex_a]]:
			if not neighbours.has(pair[0]): neighbours[pair[0]] = []
			neighbours[pair[0]].append(pair[1])
	for vertex in neighbours:
		if neighbours[vertex].size() > 2: return {"error": "The selected edges branch at a vertex; select simple chains or loops"}
	var result: Array = []
	var visited := {}
	# Open chains start at an end; whatever remains are closed loops.
	var starts: Array = neighbours.keys().filter(func(v): return neighbours[v].size() == 1)
	starts.append_array(neighbours.keys().filter(func(v): return neighbours[v].size() == 2))
	for start in starts:
		if visited.has(start): continue
		var chain := PackedInt64Array([start])
		visited[start] = true
		var previous: int = -1
		var current: int = start
		var closed := false
		while true:
			var next := -1
			for candidate in neighbours[current]:
				if candidate == previous: continue
				if candidate == start and chain.size() > 2: closed = true; break
				if not visited.has(candidate): next = candidate; break
			if closed or next < 0: break
			chain.append(next)
			visited[next] = true
			previous = current
			current = next
		result.append({"vertices": chain, "closed": closed})
	return result

# Curve through the chain vertices (positions in the mesh's local space).
static func make_curve(poly: PolyMesh, chain: Dictionary, smooth: bool = false) -> Curve3D:
	var curve := Curve3D.new()
	var points := poly.get_vertex_positions(chain.vertices)
	for point in points: curve.add_point(point)
	curve.closed = chain.closed
	if smooth and points.size() > 2:
		# Catmull-Rom tangents as Bezier handles.
		var count := points.size()
		for index in count:
			var before: Vector3 = points[(index - 1 + count) % count] if chain.closed or index > 0 else points[index]
			var after: Vector3 = points[(index + 1) % count] if chain.closed or index < count - 1 else points[index]
			var handle := (after - before) / 6.0
			curve.set_point_in(index, -handle)
			curve.set_point_out(index, handle)
	return curve

# Points along the path in `target`'s local space: `segments` even steps by length,
# plus every control point, so the corners of a polyline path stay sharp.
static func sample(path: Path3D, target: Node3D, segments: int) -> PackedVector3Array:
	var curve := path.curve
	if not curve or curve.point_count < 2 or curve.get_baked_length() <= 0: return PackedVector3Array()
	var length := curve.get_baked_length()
	var offsets: Array[float] = []
	for step in segments + 1: offsets.append(length * step / float(maxi(segments, 1)))
	for index in curve.point_count: offsets.append(curve.get_closest_offset(curve.get_point_position(index)))
	offsets.sort()
	var to_local := target.global_transform.affine_inverse() * path.global_transform
	var points := PackedVector3Array()
	var last := -INF
	for offset in offsets:
		if offset - last < length * 1e-4: continue
		last = offset
		points.append(to_local * curve.sample_baked(clampf(offset, 0.0, length), true))
	return points
