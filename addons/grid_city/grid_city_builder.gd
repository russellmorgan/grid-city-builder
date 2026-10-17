class_name GridCityBuilder
extends RefCounted

## Bakes a GridCityLayout into a node tree:
##   City
##     Ground   one plane under the whole grid (layout.ground_material)
##     Lots     one lot scene per map claim, front (-Z) turned to face an
##              avenue when it touches one, else a random street side
##     Streets  per cell: an edge scene on every side with a street, and the
##              kerb corners around each junction (sidewalk boxes + a
##              junction prop where two streets meet)
##     Lanes    Path3D lanes through every junction (edges carry their own)
##     Markers  named markers from lot MarkerSlots / prefixed Marker3Ds
## plus one StaticBody3D of box shapes per lot and per cell (never trimesh).
## PropSlots are rolled from a per-cell seed, so the same layout always
## bakes the same city and editing one cell doesn't reshuffle the rest.
##
##   var builder := GridCityBuilder.new()
##   var city := builder.build(layout)   # check builder.errors
##
## Pack and save the result (GridCityGenerator / tools/bake.gd do), or add it
## straight to the tree for a per-run city.

const DIRS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
## Edge scene yaw per side (its +Z must point into the cell), DIRS order.
const SIDE_YAW := [0.0, -PI / 2, PI, PI / 2]

## Problems found during the last build; empty = success.
var errors := PackedStringArray()

var _layout: GridCityLayout
var _map: GridCityMap
var _city: Node3D
var _shapes := {}
var _box_meshes := {}
var _reversed_curves := {}
var _sidewalk_mat: Material


## Builds the city for `layout`. Returns the root node (also on errors, so
## the partial result can be inspected); the caller owns it.
func build(layout: GridCityLayout) -> Node3D:
	errors = PackedStringArray()
	_layout = layout
	_map = GridCityMap.new(layout)
	_shapes = {}
	_box_meshes = {}
	_reversed_curves = {}
	_city = Node3D.new()
	_city.name = "City"
	errors.append_array(_map.errors)
	if layout.height() == 0:
		errors.append("layout has no rows")
	if not errors.is_empty():
		return _city
	_sidewalk_mat = layout.sidewalk_material
	if _sidewalk_mat == null:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.72, 0.71, 0.68)
		mat.roughness = 0.9
		_sidewalk_mat = mat
	_build_ground()
	_build_lots()
	_build_streets()
	if layout.lanes_enabled:
		_build_junction_lanes()
	if layout.batch_meshes:
		GridCityBatcher.new().batch(_city, layout.batch_chunk)
	_own(_city)
	return _city


## Packs `city` (from build()) into a scene and saves it to `path`.
static func save(city: Node3D, path: String) -> Error:
	var packed := PackedScene.new()
	var err := packed.pack(city)
	if err != OK:
		return err
	return ResourceSaver.save(packed, path)


func _fail(msg: String) -> void:
	errors.append(msg)


func _rng(cell: Vector2i, stream: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([_layout.city_seed, cell.x, cell.y, stream])
	return rng


func _group(node_name: String) -> Node3D:
	var node := Node3D.new()
	node.name = node_name
	_city.add_child(node)
	return node


func _build_ground() -> void:
	var size := Vector2(_layout.width(), _layout.height()) * _layout.cell_size
	var plane := PlaneMesh.new()
	plane.size = size
	var mat := _layout.ground_material
	if mat == null:
		var std := StandardMaterial3D.new()
		std.albedo_color = Color(0.24, 0.24, 0.26)
		std.roughness = 0.95
		mat = std
	plane.material = mat
	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	ground.mesh = plane
	ground.position = Vector3(size.x / 2.0, 0.005, size.y / 2.0)
	_city.add_child(ground)


# ------------------------------------------------------------------ lots

func _build_lots() -> void:
	var lots := _group("Lots")
	_group("Markers")
	var placed := {}
	for claim in _map.claims():
		var cell := claim.position
		var letter := _map.letter(cell)
		var rng := _rng(cell, 0)
		var rect := _lot_rect(claim)
		var scene := _lot_scene(letter, cell, rng)
		if scene == null:
			continue
		var lot: Node3D = scene.instantiate()
		lot.name = "%s_%d_%d" % [letter, cell.x, cell.y]
		var yaw := _lot_yaw(claim, rect, rng)
		lot.transform = Transform3D(Basis(Vector3.UP, yaw), Vector3(rect.get_center().x, 0, rect.get_center().y))
		lots.add_child(lot)
		var size: Vector2 = lot.get_meta("lot_size", Vector2.ZERO)
		if is_equal_approx(absf(sin(yaw)), 1.0):
			size = Vector2(size.y, size.x)
		if not size.is_equal_approx(rect.size):
			_fail("%s is %s but '%s' at %s needs %s" % [scene.resource_path, size, letter, cell, rect.size])
		_flatten(lot)
		_resolve_slots(lot, rng)
		_place_markers(lot, cell, placed)
		_add_bodies(lot)
	for cell: Vector2i in _layout.cell_markers:
		if not placed.has(cell):
			_fail("marker '%s': cell %s has no lot" % [_layout.cell_markers[cell], cell])


## Claim footprint in world x/z, minus the street edge on every side with a street.
func _lot_rect(claim: Rect2i) -> Rect2:
	var lo := Vector2(claim.position) * _layout.cell_size
	var hi := Vector2(claim.end) * _layout.cell_size
	var last := claim.end - Vector2i.ONE
	var edge := _layout.edge_depth()
	if _map.street_between(claim.position, claim.position + Vector2i.UP):
		lo.y += edge
	if _map.street_between(last, last + Vector2i.DOWN):
		hi.y -= edge
	if _map.street_between(claim.position, claim.position + Vector2i.LEFT):
		lo.x += edge
	if _map.street_between(last, last + Vector2i.RIGHT):
		hi.x -= edge
	return Rect2(lo, hi - lo)


func _lot_scene(letter: String, cell: Vector2i, rng: RandomNumberGenerator) -> PackedScene:
	if _layout.cell_overrides.has(cell):
		return _layout.cell_overrides[cell]
	var pool: Array = _layout.pools.get(letter, [])
	if pool.is_empty():
		_fail("no pool (and no cell override) for '%s' at %s" % [letter, cell])
		return null
	return pool[rng.randi() % pool.size()]


## Front (-Z) toward a street side, preferring avenues; a non-square lot
## keeps its long side (authored along X) on the long side of the claim.
## A lot with no street side (e.g. a barrier corner) turns its front-right
## corner toward the city centre.
func _lot_yaw(claim: Rect2i, rect: Rect2, rng: RandomNumberGenerator) -> float:
	var options: Array[Vector2i] = []
	var avenues: Array[Vector2i] = []
	var last := claim.end - Vector2i.ONE
	for dir in DIRS:
		var from := claim.position if dir.x < 0 or dir.y < 0 else last
		if not _map.street_between(from, from + dir):
			continue
		if not is_equal_approx(rect.size.x, rect.size.y) and (dir.y != 0) != (rect.size.x > rect.size.y):
			continue
		options.append(dir)
		var line := claim.position.y if dir.y < 0 else claim.end.y if dir.y > 0 else claim.position.x if dir.x < 0 else claim.end.x
		if _map.is_avenue(line):
			avenues.append(dir)
	if not avenues.is_empty():
		options = avenues
	if options.is_empty():
		var centre := Vector2(_layout.width(), _layout.height()) * _layout.cell_size / 2.0
		var inward := (centre - rect.get_center()).sign()
		for yaw: float in [0.0, PI / 2, PI, -PI / 2]:
			var front_right := Basis(Vector3.UP, yaw) * Vector3(1, 0, -1)
			if Vector2(front_right.x, front_right.z).sign() == inward:
				return yaw
		return 0.0
	var dir := options[rng.randi() % options.size()]
	return atan2(-float(dir.x), -float(dir.y))


## Turns an instanced tile into plain nodes of the city scene (so its slots
## can be replaced); props instanced later stay scene instances.
func _flatten(node: Node) -> void:
	node.scene_file_path = ""


func _resolve_slots(node: Node, rng: RandomNumberGenerator) -> void:
	for slot in node.find_children("*", "Marker3D", true, false):
		if not slot is GridCityPropSlot:
			continue
		var parent := slot.get_parent()
		var index := slot.get_index()
		var copies: Array = slot.roll(rng)
		var base := slot.name
		parent.remove_child(slot)
		slot.free()
		for i in copies.size():
			var inst: Node3D = copies[i][0].instantiate()
			# Deterministic unique name: a clash would get Godot's @Node3D@<n>,
			# whose counter differs run to run.
			var inst_name := base if copies.size() == 1 else "%s%d" % [base, i]
			var suffix := 1
			while parent.has_node(NodePath(inst_name)):
				inst_name = "%s_%d" % [base if copies.size() == 1 else "%s%d" % [base, i], suffix]
				suffix += 1
			inst.name = inst_name
			inst.transform = copies[i][1]
			inst.set_meta("_grid_city_prop", true)
			parent.add_child(inst)
			parent.move_child(inst, index + i)


func _place_markers(lot: Node3D, cell: Vector2i, placed: Dictionary) -> void:
	var markers := _city.get_node("Markers")
	var marker_name: String = _layout.cell_markers.get(cell, "")
	for slot: Node3D in lot.find_children("MarkerSlot*", "Marker3D", true, false):
		if not marker_name.is_empty():
			_add_marker(markers, marker_name.validate_node_name(), slot)
			placed[cell] = true
			marker_name = ""
		slot.free()
	if not marker_name.is_empty():
		_fail("marker '%s' at %s: the lot has no MarkerSlot" % [marker_name, cell])
		placed[cell] = true
	for prefix in _layout.export_marker_prefixes:
		for slot: Node3D in lot.find_children(prefix + "*", "Marker3D", true, false):
			var n := 0
			while markers.has_node(NodePath("%s%d" % [prefix, n])):
				n += 1
			_add_marker(markers, "%s%d" % [prefix, n], slot)
			slot.free()


func _add_marker(markers: Node3D, marker_name: String, slot: Node3D) -> void:
	var marker := Marker3D.new()
	marker.name = marker_name
	markers.add_child(marker)
	marker.transform = _rel(slot, _city)


# --------------------------------------------------------------- streets

func _build_streets() -> void:
	var streets := _group("Streets")
	for r in _layout.height():
		for c in _layout.width():
			var cell := Vector2i(c, r)
			var node := Node3D.new()
			node.name = "S_%d_%d" % [c, r]
			streets.add_child(node)
			var rng := _rng(cell, 1)
			var centre := (Vector2(cell) + Vector2(0.5, 0.5)) * _layout.cell_size
			for i in DIRS.size():
				var dir := DIRS[i]
				if not _map.street_between(cell, cell + dir):
					continue
				var line := (cell.y + maxi(dir.y, 0)) if dir.y != 0 else (cell.x + maxi(dir.x, 0))
				var scene := _layout.avenue_edge if _map.is_avenue(line) else _layout.street_edge
				if scene == null:
					_fail("layout has no %s scene" % ("avenue_edge" if _map.is_avenue(line) else "street_edge"))
					return
				var mid := centre + Vector2(dir) * _layout.cell_size / 2.0
				var edge: Node3D = scene.instantiate()
				edge.name = "Edge%s" % ["N", "E", "S", "W"][i]
				edge.transform = Transform3D(Basis(Vector3.UP, SIDE_YAW[i]), Vector3(mid.x, 0, mid.y))
				node.add_child(edge)
				_flatten(edge)
				_resolve_slots(edge, rng)
				_adopt_lanes(edge)
			_build_corners(node, cell)
			if node.get_child_count() == 0:
				node.free()
			else:
				_add_bodies(node)


## The edge-depth square at each cell corner, in a frame where the junction
## is the origin and the cell lies toward +x/+z (yaw maps it to the
## quadrant). Local +x / +z arms decide the piece: both = kerb corner (+ a
## junction prop); one = straight sidewalk strip; none but the junction has
## arms = outer corner of an L/T.
func _build_corners(node: Node3D, cell: Vector2i) -> void:
	# [junction, yaw, local +x arm dir, local +z arm dir]
	var corners := [
		[cell, 0.0, Vector2i(1, 0), Vector2i(0, 1)],
		[cell + Vector2i(1, 0), -PI / 2, Vector2i(0, 1), Vector2i(-1, 0)],
		[cell + Vector2i(1, 1), PI, Vector2i(-1, 0), Vector2i(0, -1)],
		[cell + Vector2i(0, 1), PI / 2, Vector2i(0, -1), Vector2i(1, 0)],
	]
	var half := _layout.half_street
	var edge := _layout.edge_depth()
	for i in corners.size():
		var j: Vector2i = corners[i][0]
		var arms := _map.arms(j)
		if arms.is_empty():
			continue
		var ax: bool = arms.has(corners[i][2])
		var az: bool = arms.has(corners[i][3])
		var corner := Node3D.new()
		corner.name = "Corner%d" % i
		corner.transform = Transform3D(Basis(Vector3.UP, corners[i][1]), _map.junction_position(j))
		node.add_child(corner)
		if ax and az:
			_sidewalk(corner, Rect2(half, half, edge - half, edge - half))
			var avenue := _map.is_avenue(j.x) or _map.is_avenue(j.y)
			var prop_scene := _layout.avenue_junction_prop if avenue else _layout.street_junction_prop
			if prop_scene != null:
				var prop: Node3D = prop_scene.instantiate()
				prop.name = "JunctionProp"
				prop.position = Vector3(half + 1.2, _layout.kerb_height, half + 1.2)
				prop.rotation.y = PI / 4 * (1 if avenue else -1) + PI
				prop.set_meta("_grid_city_prop", true)
				corner.add_child(prop)
		elif ax:
			_sidewalk(corner, Rect2(0, half, edge, edge - half))
		elif az:
			_sidewalk(corner, Rect2(half, 0, edge - half, edge))
		else:
			_sidewalk(corner, Rect2(half, 0, edge - half, edge))
			_sidewalk(corner, Rect2(0, half, half, edge - half))


## A kerb-height sidewalk box over `rect` (local x/z); tagged solid.
func _sidewalk(parent: Node3D, rect: Rect2) -> void:
	var size := Vector3(rect.size.x, _layout.kerb_height, rect.size.y)
	var mesh: BoxMesh = _box_meshes.get(size)
	if mesh == null:
		mesh = BoxMesh.new()
		mesh.size = size
		mesh.material = _sidewalk_mat
		_box_meshes[size] = mesh
	var mi := MeshInstance3D.new()
	mi.name = "Sidewalk%d" % parent.get_child_count()
	mi.mesh = mesh
	mi.position = Vector3(rect.get_center().x, _layout.kerb_height / 2.0, rect.get_center().y)
	mi.set_meta("solid", true)
	parent.add_child(mi)


# ----------------------------------------------------------------- lanes

## Every Path3D in an edge scene is a lane: grouped, given the lane script,
## reversed for left-hand traffic — or dropped when lanes are off.
func _adopt_lanes(edge: Node3D) -> void:
	for lane: Path3D in edge.find_children("*", "Path3D", true, false):
		if not _layout.lanes_enabled:
			lane.free()
			continue
		var curve := lane.curve
		if not _layout.right_hand_traffic and curve != null:
			if not _reversed_curves.has(curve):
				_reversed_curves[curve] = _reversed(curve)
			curve = _reversed_curves[curve]
		_make_lane(lane, curve)


func _make_lane(lane: Path3D, curve: Curve3D) -> void:
	if _layout.lane_script != null:
		lane.set_script(_layout.lane_script)
	lane.curve = curve
	if not _layout.lane_group.is_empty():
		lane.add_to_group(_layout.lane_group, true)


func _reversed(curve: Curve3D) -> Curve3D:
	var out := Curve3D.new()
	for i in range(curve.point_count - 1, -1, -1):
		out.add_point(curve.get_point_position(i), curve.get_point_out(i), curve.get_point_in(i))
	return out


## Lanes through each junction: every incoming lane end (edge depth out on
## its arm, on the traffic side) to the other arms' outgoing lane starts, no
## U-turns, lane-for-lane with merges/splits so every lane in and out stays
## connected (a strongly connected graph).
func _build_junction_lanes() -> void:
	var lanes := _group("Lanes")
	var edge := _layout.edge_depth()
	for jy in _layout.height() + 1:
		for jx in _layout.width() + 1:
			var j := Vector2i(jx, jy)
			var arms := _map.arms(j)
			if arms.size() < 2:
				continue
			var centre := _map.junction_position(j) + Vector3.UP * _layout.lane_height
			for a in arms:
				var travel := -a
				var offs_in := _lane_offsets(j, a)
				for b in arms:
					if b == a:
						continue
					var offs_out := _lane_offsets(j, b)
					var pairs := {}
					for i in offs_in.size():
						pairs[[i, mini(i, offs_out.size() - 1)]] = true
					for i in offs_out.size():
						pairs[[mini(i, offs_in.size() - 1), i]] = true
					for pair: Array in pairs.keys():
						var p0: Vector3 = centre + _v3(a) * edge - _v3(_side(a)) * offs_in[pair[0]]
						var p1: Vector3 = centre + _v3(b) * edge + _v3(_side(b)) * offs_out[pair[1]]
						var k: float = 0.0 if b == travel else p0.distance_to(p1) * 0.45
						var curve := Curve3D.new()
						curve.add_point(p0, Vector3.ZERO, _v3(travel) * k)
						curve.add_point(p1, -_v3(b) * k, Vector3.ZERO)
						var lane := Path3D.new()
						lane.name = "J%d_%d_%d" % [jx, jy, lanes.get_child_count()]
						_make_lane(lane, curve)
						lanes.add_child(lane)


func _lane_offsets(j: Vector2i, arm: Vector2i) -> PackedFloat32Array:
	var line := j.y if arm.y == 0 else j.x
	return _layout.avenue_lane_offsets if _map.is_avenue(line) else _layout.street_lane_offsets


## The traffic side of travel direction `d` (x/z; Godot's -Z = north):
## right for right-hand traffic, left otherwise.
func _side(d: Vector2i) -> Vector2i:
	var right := Vector2i(-d.y, d.x)
	return right if _layout.right_hand_traffic else -right


func _v3(d: Vector2i) -> Vector3:
	return Vector3(d.x, 0, d.y)


# ------------------------------------------------------------- collision

## Box per collidable mesh AABB, in `owner_node`'s space: meshes inside a
## prop instance (unless tagged no_collider) and meshes tagged `solid`.
## Tagged `collision_group` → a body per group, in that group.
func _add_bodies(owner_node: Node3D) -> void:
	if not _layout.build_colliders:
		_clear_prop_tags(owner_node)
		return
	var bodies := {}
	for mi: MeshInstance3D in owner_node.find_children("*", "MeshInstance3D", true, false):
		if mi.has_meta("no_collider") or mi.mesh == null:
			continue
		var group: String = mi.get_meta("collision_group", "")
		if group.is_empty() and not (mi.has_meta("solid") or _in_prop(mi, owner_node)):
			continue
		var body: StaticBody3D = bodies.get(group)
		if body == null:
			body = StaticBody3D.new()
			body.name = "Body" if group.is_empty() else "%sBody" % group.validate_node_name()
			body.collision_layer = _layout.collision_layer
			if not group.is_empty():
				body.add_to_group(group, true)
			bodies[group] = body
		var aabb := _rel(mi, owner_node) * mi.get_aabb()
		var shape := CollisionShape3D.new()
		shape.name = "Box%d" % body.get_child_count()
		shape.shape = _box_shape(aabb.size)
		shape.position = aabb.get_center()
		body.add_child(shape)
	for body: StaticBody3D in bodies.values():
		owner_node.add_child(body)
	_clear_prop_tags(owner_node)


func _clear_prop_tags(node: Node) -> void:
	for child in node.get_children():
		child.remove_meta("_grid_city_prop")
		if child.scene_file_path.is_empty():
			_clear_prop_tags(child)


## `node`'s transform in `ancestor`'s space (works outside the tree).
func _rel(node: Node3D, ancestor: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	while node != ancestor:
		t = node.transform * t
		node = node.get_parent()
	return t


func _in_prop(node: Node, stop: Node) -> bool:
	while node != stop and node != null:
		if node.has_meta("_grid_city_prop"):
			return true
		node = node.get_parent()
	return false


func _box_shape(size: Vector3) -> BoxShape3D:
	size = size.snapped(Vector3.ONE * 0.01)
	var shape: BoxShape3D = _shapes.get(size)
	if shape == null:
		shape = BoxShape3D.new()
		shape.size = size
		_shapes[size] = shape
	return shape


## Everything the builder made or flattened belongs to the City scene;
## nodes inside prop instances keep their instance as owner.
func _own(node: Node) -> void:
	for child in node.get_children():
		if child.owner == null or child.owner.scene_file_path.is_empty():
			child.owner = _city
		_own(child)
