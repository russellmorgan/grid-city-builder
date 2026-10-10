class_name GridCityMap
extends RefCounted

## Street-network queries on a GridCityLayout, for the builder and for
## runtime code (AI that drives junction to junction, spawners, minimaps).
## Cells are Vector2i(column, row); junctions sit on lattice points
## Vector2i(x, y) at world (x, 0, y) × cell_size relative to the city root.

var layout: GridCityLayout
## cell → claim Rect2i (in cells).
var _claims: Dictionary = {}
var _claim_list: Array[Rect2i] = []
## Problems found while reading the map (bad superblocks, ragged rows).
var errors := PackedStringArray()


func _init(city_layout: GridCityLayout) -> void:
	layout = city_layout
	for r in layout.height():
		if layout.rows[r].length() != layout.width():
			errors.append("row %d is %d characters, expected %d" % [r, layout.rows[r].length(), layout.width()])
	if errors.is_empty():
		_build_claims()


func letter(cell: Vector2i) -> String:
	if cell.x < 0 or cell.y < 0 or cell.x >= layout.width() or cell.y >= layout.height():
		return ""
	return layout.rows[cell.y][cell.x]


## Barrier cell, or outside the map (which counts as a barrier).
func is_barrier(cell: Vector2i) -> bool:
	var l := letter(cell)
	return l.is_empty() or layout.barrier_letters.contains(l)


func is_avenue(line: int) -> bool:
	return layout.avenue_lines.has(line)


## Every claim (lot footprint in cells), row-major.
func claims() -> Array[Rect2i]:
	return _claim_list


func claim_of(cell: Vector2i) -> Rect2i:
	return _claims.get(cell, Rect2i(cell, Vector2i.ONE))


## True when a street runs along the edge shared by two adjacent cells.
func street_between(a: Vector2i, b: Vector2i) -> bool:
	if is_barrier(a) and is_barrier(b):
		return false
	return claim_of(a) != claim_of(b)


## True when a street runs between two adjacent lattice junctions.
func has_segment(a: Vector2i, b: Vector2i) -> bool:
	var lo := Vector2i(mini(a.x, b.x), mini(a.y, b.y))
	if b.y == a.y:  # along x, on line z = lo.y: the cells above and below
		return street_between(Vector2i(lo.x, lo.y - 1), lo)
	return street_between(Vector2i(lo.x - 1, lo.y), lo)  # along z, on line x = lo.x


## Directions (unit Vector2i, y = +Z) of the streets leaving junction `j`.
func arms(j: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dir: Vector2i in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
		if has_segment(j, j + dir):
			out.append(dir)
	return out


## World position (relative to the city root) of lattice junction `j`.
func junction_position(j: Vector2i) -> Vector3:
	return Vector3(j.x, 0, j.y) * layout.cell_size


func _build_claims() -> void:
	for r in layout.height():
		for c in layout.width():
			var cell := Vector2i(c, r)
			if _claims.has(cell):
				continue
			var l := letter(cell)
			var size: Vector2i = layout.superblocks.get(l, Vector2i.ONE)
			if size.x != size.y and letter(cell + Vector2i.RIGHT) != l:
				size = Vector2i(size.y, size.x)
			var rect := Rect2i(cell, size)
			var ok := true
			for y in range(r, rect.end.y):
				for x in range(c, rect.end.x):
					var other := Vector2i(x, y)
					ok = ok and letter(other) == l and not _claims.has(other)
			if not ok:
				errors.append("superblock %s at %s needs %d×%d cells of '%s'" % [l, cell, size.x, size.y, l])
				rect = Rect2i(cell, Vector2i.ONE)
			for y in range(r, rect.end.y):
				for x in range(c, rect.end.x):
					_claims[Vector2i(x, y)] = rect
			_claim_list.append(rect)
