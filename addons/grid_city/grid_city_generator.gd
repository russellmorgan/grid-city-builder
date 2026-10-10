@tool
@icon("res://addons/grid_city/icon.svg")
class_name GridCityGenerator
extends Node3D

## Bakes `layout` into a scene file and shows it as this node's child.
## Inspector → Bake: builds with GridCityBuilder, saves `output_path`, and
## instances the result here (so it saves with your scene as a plain scene
## instance). Bake again after editing the layout or a lot/street scene;
## editing a prop scene needs no bake (props stay instances). Errors are
## printed to the Output panel and listed in `last_errors`.
##
## Leave `output_path` empty to bake into memory only. With `build_on_ready`
## the city is built when the game starts if nothing was baked (handy for a
## different seed per run, or to skip shipping the baked scene).

@export var layout: GridCityLayout
@export_file("*.tscn") var output_path := ""
@export var build_on_ready := false
@export_tool_button("Bake") var bake_button := bake
@export_tool_button("Clear") var clear_button := clear
## Problems from the last bake (also printed to the Output panel).
var last_errors := PackedStringArray()


func _ready() -> void:
	if build_on_ready and not Engine.is_editor_hint() and not has_node("City"):
		var city := _build()
		if city != null:
			add_child(city)


## Builds the city; saves and instances it when output_path is set.
func bake() -> void:
	var city := _build()
	if city == null:
		return
	if output_path.is_empty():
		clear()
		add_child(city)
		_adopt(city)
		return
	var err := GridCityBuilder.save(city, output_path)
	city.free()
	if err != OK:
		push_error("Grid City: saving %s failed (%s)" % [output_path, error_string(err)])
		return
	var scene: PackedScene = ResourceLoader.load(output_path, "", ResourceLoader.CACHE_MODE_REPLACE)
	clear()
	var inst := scene.instantiate()
	add_child(inst)
	if Engine.is_editor_hint() and is_inside_tree():
		inst.owner = get_tree().edited_scene_root
		var editor := Engine.get_singleton("EditorInterface")
		if editor:
			editor.get_resource_filesystem().scan()
	print("Grid City: baked %s" % output_path)


## Removes the baked city child.
func clear() -> void:
	for child in get_children():
		if child.name == "City":
			remove_child(child)
			child.queue_free()


func _build() -> Node3D:
	if layout == null:
		push_error("Grid City: assign a GridCityLayout first")
		return null
	var builder := GridCityBuilder.new()
	var city := builder.build(layout)
	last_errors = builder.errors
	for e in builder.errors:
		push_error("Grid City: " + e)
	if not builder.errors.is_empty():
		city.free()
		return null
	return city


## Editor: make the in-memory city part of the edited scene so it saves.
func _adopt(city: Node) -> void:
	if not (Engine.is_editor_hint() and is_inside_tree()):
		return
	var root := get_tree().edited_scene_root
	for node in city.find_children("*", "", true, false):
		if node.owner == city:
			node.owner = root
	city.owner = root
