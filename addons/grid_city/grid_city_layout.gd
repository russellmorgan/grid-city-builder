@tool
@icon("res://addons/grid_city/icon.svg")
class_name GridCityLayout
extends Resource

## Everything Grid City Builder needs to bake a city: the district map, the
## grid dimensions, which scenes fill each district, and the street, lane and
## collision options. Bake it with a GridCityGenerator node (Inspector →
## Bake), the headless CLI (addons/grid_city/tools/bake.gd), or at runtime
## with GridCityBuilder.new().build(layout).
##
## The map is a grid of cells, one character each; row 0 is north (-Z),
## column 0 is west (-X). Cell (c, r) spans x c…c+1, z r…r+1 in cell_size
## units. Every cell edge that has a street carries half of it (half_street
## of asphalt) plus a sidewalk, so a 1×1 lot is
## cell_size - 2 × (half_street + sidewalk) square. A street runs between two
## neighbouring cells unless both are barrier cells or both belong to the
## same superblock.

@export_group("Map")
## Base seed. Each cell rolls from its own seed derived from this, so
## editing one cell doesn't reshuffle the rest of the city.
@export var city_seed := 1234
## One string per row, one character per cell, all rows the same length.
@export var rows := PackedStringArray()
## Characters whose cells are barriers (city edge, water, rail yards): no
## street runs between two barrier cells.
@export var barrier_letters := ""
## Letters that always claim a block of cells, e.g. {"P": Vector2i(2, 2)}.
## A non-square size is laid out horizontally when the cell to the right has
## the same letter, else vertically. Superblocks drop their inner streets.
@export var superblocks: Dictionary[String, Vector2i] = {}

@export_group("Dimensions")
@export var cell_size := 100.0
## Asphalt from the lattice line to the kerb (half the street width).
@export var half_street := 10.0
@export var sidewalk := 5.0
@export var kerb_height := 0.15
## Lattice lines (both axes) that are avenues: lots prefer to face them,
## their edges use avenue_edge, junctions on them get avenue_junction_prop.
@export var avenue_lines := PackedInt32Array()

@export_group("Lots")
## Letter → lot scenes the seed picks from. Lot scenes are centred on their
## origin with the front (street side) facing -Z, and carry a `lot_size`
## Vector2 metadata (x width, z depth) the builder checks against the cell.
@export var pools: Dictionary[String, Array] = {}
## Cell → a specific lot scene, overriding the cell's pool.
@export var cell_overrides: Dictionary[Vector2i, PackedScene] = {}
## Cell → marker name. The lot's Marker3D named "MarkerSlot" is exported as
## Markers/<name> (e.g. a quest giver, a spawn point, a shop entrance).
@export var cell_markers: Dictionary[Vector2i, String] = {}
## Lot Marker3Ds whose names start with one of these are all exported as
## Markers/<prefix><n> (e.g. "Spawn" → Spawn0, Spawn1…).
@export var export_marker_prefixes := PackedStringArray()

@export_group("Streets")
## Edge scenes span one cell side between the corners: lattice line at
## z = 0, +Z into the cell, x ∈ ±(cell_size / 2 - half_street - sidewalk).
@export var avenue_edge: PackedScene
@export var street_edge: PackedScene
## Placed on each kerb corner where two streets meet.
@export var avenue_junction_prop: PackedScene
@export var street_junction_prop: PackedScene
@export var sidewalk_material: Material
## The plane under the whole city (lots and sidewalks sit on top of it).
@export var ground_material: Material

@export_group("Lanes")
## Path3D lanes for navigation/traffic: every Path3D in an edge scene, plus
## generated lanes through each junction. All join the lane_group.
@export var lanes_enabled := true
@export var lane_group := "grid_city_lanes"
## Lateral offsets of the lanes on one side of an avenue / street, measured
## from the lattice line, innermost first.
@export var avenue_lane_offsets := PackedFloat32Array([2.5, 7.5])
@export var street_lane_offsets := PackedFloat32Array([2.5])
## Edge scenes are authored for right-hand traffic; false reverses them.
@export var right_hand_traffic := true
## Optional script (extending Path3D) attached to every lane, e.g. a
## traffic/road addon's lane class.
@export var lane_script: Script
@export var lane_height := 0.1

@export_group("Collision")
## One StaticBody3D of box shapes per lot and per cell: the AABB of every
## prop mesh (unless tagged `no_collider` metadata) and of every lot/edge
## mesh tagged `solid`. A mesh tagged `collision_group = "<name>"` goes in a
## separate body in that group instead.
@export var build_colliders := true
@export_flags_3d_physics var collision_layer := 1


func width() -> int:
	return rows[0].length() if not rows.is_empty() else 0


func height() -> int:
	return rows.size()


## Distance from a lattice line to the lot boundary on a street side.
func edge_depth() -> float:
	return half_street + sidewalk
