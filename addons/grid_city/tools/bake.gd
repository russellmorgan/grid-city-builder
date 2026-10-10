extends SceneTree

## Headless bake, for build scripts and CI:
##   godot --headless --path . --script res://addons/grid_city/tools/bake.gd -- <layout.tres> <out.tscn>
## Prints GRID_CITY_BAKE: saved <out> (… lots, … lanes, … markers) and exits
## 0, or prints each error and exits 1.


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2:
		printerr("usage: … --script res://addons/grid_city/tools/bake.gd -- <layout.tres> <out.tscn>")
		quit(2)
		return
	var layout := load(args[0]) as GridCityLayout
	if layout == null:
		printerr("GRID_CITY_BAKE: %s is not a GridCityLayout" % args[0])
		quit(1)
		return
	var builder := GridCityBuilder.new()
	var city := builder.build(layout)
	if not builder.errors.is_empty():
		for e in builder.errors:
			printerr("GRID_CITY_BAKE: " + e)
		city.free()
		quit(1)
		return
	var stats := "%d lots, %d lanes, %d markers" % [city.get_node("Lots").get_child_count(),
			city.find_children("*", "Path3D", true, false).size(), city.get_node("Markers").get_child_count()]
	var err := GridCityBuilder.save(city, args[1])
	city.free()
	if err != OK:
		printerr("GRID_CITY_BAKE: saving %s failed (%s)" % [args[1], error_string(err)])
		quit(1)
		return
	print("GRID_CITY_BAKE: saved %s (%s)" % [args[1], stats])
	quit(0)
