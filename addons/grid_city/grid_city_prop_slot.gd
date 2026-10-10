@tool
@icon("res://addons/grid_city/icon.svg")
class_name GridCityPropSlot
extends Marker3D

## Placement marker in a city tile scene (lots, street edges). The builder
## swaps it for one of `variants`, rolled from the cell's seed: `chance` to
## appear at all, ± `jitter` metres, one of `yaw_options` degrees added, and
## (for buildings) the slot's scale.y replaced by a height in `height_range`
## metres. The slot's x/z scale is the footprint; building scenes are a 1 m
## unit box standing on y = 0. `repeat` places that many copies `step` apart
## (slot-local axes), each rolled on its own: parked-car rows, tree lines,
## lamp rows. Variants stay scene instances in the baked city.

@export var variants: Array[PackedScene] = []
@export_range(0.0, 1.0) var chance := 1.0
@export var jitter := Vector3.ZERO
@export var yaw_options := PackedFloat32Array()
@export var height_range := Vector2.ZERO
@export var repeat := 1
@export var step := Vector3.ZERO


## [[scene, transform in the slot's parent space], …] for the copies that
## appear. Every copy draws the same randoms whether it appears or not, so
## tweaking one chance doesn't reshuffle the rest of the cell.
func roll(rng: RandomNumberGenerator) -> Array:
	var out := []
	for i in repeat:
		var hit := rng.randf() < chance
		var offset := Vector3(rng.randf_range(-jitter.x, jitter.x), rng.randf_range(-jitter.y, jitter.y), rng.randf_range(-jitter.z, jitter.z))
		var yaw := rng.randi()
		var height := rng.randf_range(height_range.x, height_range.y)
		var pick := rng.randi()
		if not hit or variants.is_empty():
			continue
		var t := transform
		t.origin += transform.basis.orthonormalized() * (step * i) + offset
		if not yaw_options.is_empty():
			t.basis = t.basis.rotated(Vector3.UP, deg_to_rad(yaw_options[yaw % yaw_options.size()]))
		if height_range != Vector2.ZERO:
			t.basis.y = Vector3.UP * height
		out.append([variants[pick % variants.size()], t])
	return out
