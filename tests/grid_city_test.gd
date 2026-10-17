extends SceneTree

## Headless checks for Grid City Builder:
##   godot --headless --path . --script res://tests/grid_city_test.gd
## Bakes the demo layout and checks: no builder errors (which covers every
## lot's lot_size vs its cell), one lot per claim, one edge per street side,
## no trimesh colliders, the named + prefixed markers, a strongly connected
## lane graph (right- and left-hand traffic), deterministic output, and that
## a broken layout reports errors instead of baking.

const DEMO := "res://addons/grid_city/demo/demo_layout.tres"

var failures := PackedStringArray()


func _initialize() -> void:
	var layout: GridCityLayout = load(DEMO)
	var builder := GridCityBuilder.new()
	var city := builder.build(layout)
	_check(builder.errors.is_empty(), "demo bake errors: %s" % ", ".join(builder.errors))

	var map := GridCityMap.new(layout)
	_check(city.get_node("Lots").get_child_count() == map.claims().size(),
			"expected one lot per claim (%d), got %d" % [map.claims().size(), city.get_node("Lots").get_child_count()])
	var sides := 0
	for r in layout.height():
		for c in layout.width():
			for dir in GridCityBuilder.DIRS:
				if map.street_between(Vector2i(c, r), Vector2i(c, r) + dir):
					sides += 1
	var edges := city.find_children("Edge?", "Node3D", true, false).size()
	_check(edges == sides, "expected %d street edges, got %d" % [sides, edges])

	for shape: CollisionShape3D in city.find_children("*", "CollisionShape3D", true, false):
		if shape.shape is ConcavePolygonShape3D:
			_check(false, "trimesh collider at %s" % city.get_path_to(shape))
			break
	var grass := city.find_children("GrassBody", "StaticBody3D", true, false)
	_check(not grass.is_empty() and grass[0].is_in_group("Grass"), "park lawns should get a body in the Grass group")

	for marker in ["Town Square", "Warehouse Dock", "Bus Depot", "Post0", "Post1", "Post2"]:
		_check(city.has_node(NodePath("Markers/" + marker)), "missing marker %s" % marker)

	_check_lanes(city, layout, "right-hand")
	var left: GridCityLayout = layout.duplicate()
	left.right_hand_traffic = false
	var left_city := builder.build(left)
	_check_lanes(left_city, left, "left-hand")
	left_city.free()

	var again := builder.build(layout)
	_check(_digest(city) == _digest(again), "two bakes of the same layout differ")
	again.free()

	var batched_layout: GridCityLayout = layout.duplicate()
	batched_layout.batch_meshes = true
	var batched := builder.build(batched_layout)
	_check(builder.errors.is_empty(), "batched bake errors: %s" % ", ".join(builder.errors))
	var plain := _drawn(city)
	var merged := _drawn(batched)
	_check(batched.has_node("Batches"), "batched city has no Batches node")
	_check(merged[0] < plain[0], "batching left %d mesh instances of %d" % [merged[0], plain[0]])
	_check(merged[0] + merged[1] == plain[0], "batching changed the drawn mesh count: %d + %d vs %d" % [merged[0], merged[1], plain[0]])
	_check(batched.find_children("*", "CollisionShape3D", true, false).size() == city.find_children("*", "CollisionShape3D", true, false).size(),
			"batching changed the collision shapes")
	var batched_again := builder.build(batched_layout)
	_check(_digest(batched) == _digest(batched_again), "two batched bakes differ")
	batched_again.free()
	batched.free()
	city.free()

	var broken: GridCityLayout = layout.duplicate()
	broken.cell_markers = {}
	broken.cell_overrides = {}
	for rows in [["CNNC", "WPDE", "WDDE", "CSSC"], ["CNNC", "WDDE", "WDXE", "CSSC"], ["CNNC", "WDDE", "WDE", "CSSC"]]:
		broken.rows = PackedStringArray(rows)  # lone 2×2 P / no pool for X / ragged row
		var bad := builder.build(broken)
		_check(builder.errors.size() == 1, "broken layout %s should report one error, got %s" % [rows, builder.errors])
		bad.free()

	for f in failures:
		printerr("  - " + f)
	print("GRID_CITY_TEST: %s" % ("PASS" if failures.is_empty() else "FAIL"))
	quit(0 if failures.is_empty() else 1)


func _check(ok: bool, msg: String) -> void:
	if not ok:
		failures.append(msg)


## Lanes link end → start within 0.5 m; every lane must reach, and be
## reached from, every other (forward + reverse BFS from one lane).
func _check_lanes(city: Node3D, layout: GridCityLayout, label: String) -> void:
	var lanes := city.find_children("*", "Path3D", true, false)
	_check(not lanes.is_empty(), "%s: no lanes" % label)
	if lanes.is_empty():
		return
	var starts := {}
	for i in lanes.size():
		var lane: Path3D = lanes[i]
		_check(lane.is_in_group(layout.lane_group), "%s: lane %s not in group %s" % [label, lane.name, layout.lane_group])
		starts.get_or_add(_key(_rel(lane, city) * lane.curve.get_point_position(0)), []).append(i)
	var fwd := {}
	var back := {}
	for i in lanes.size():
		var lane: Path3D = lanes[i]
		var end := _rel(lane, city) * lane.curve.get_point_position(lane.curve.point_count - 1)
		for j: int in starts.get(_key(end), []):
			fwd.get_or_add(i, []).append(j)
			back.get_or_add(j, []).append(i)
	for graph in [fwd, back]:
		var seen := {0: true}
		var queue := [0]
		while not queue.is_empty():
			for n: int in graph.get(queue.pop_back(), []):
				if not seen.has(n):
					seen[n] = true
					queue.append(n)
		_check(seen.size() == lanes.size(), "%s: lane graph not strongly connected (%d / %d)" % [label, seen.size(), lanes.size()])


func _key(p: Vector3) -> Vector3i:
	return Vector3i((p * 2.0).round())  # 0.5 m buckets


func _rel(node: Node3D, ancestor: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	while node != ancestor:
		t = node.transform * t
		node = node.get_parent()
	return t


## Every node's path, class, scene and transform, in tree order.
## [visible MeshInstance3Ds, instances inside MultiMeshInstance3Ds].
func _drawn(city: Node) -> Array[int]:
	var meshes := 0
	var instances := 0
	for mi: MeshInstance3D in city.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh != null and mi.is_visible_in_tree() == mi.visible and mi.visible:
			meshes += 1
	for mm: MultiMeshInstance3D in city.find_children("*", "MultiMeshInstance3D", true, false):
		instances += mm.multimesh.instance_count
	return [meshes, instances]


func _digest(city: Node) -> int:
	var parts := PackedStringArray()
	for node in city.find_children("*", "", true, false):
		var line := "%s %s %s" % [city.get_path_to(node), node.get_class(), node.scene_file_path]
		if node is Node3D:
			line += " " + str(node.transform)
		parts.append(line)
	return "\n".join(parts).hash()
