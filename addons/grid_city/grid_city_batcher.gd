class_name GridCityBatcher
extends RefCounted

## Bake-time draw-call batching (GridCityLayout.batch_meshes). Every static
## MeshInstance3D in a built city is moved into a MultiMeshInstance3D shared
## with the identical meshes in the same `chunk`-metre square, so a thousand
## streetlights, trees and parked cars cost a handful of draws instead of a
## thousand (the Compatibility/web renderer doesn't batch separate meshes).
##
## What is batched: meshes under plain Node3D parents with no script, either
## loose in a flattened tile (lot, street edge) or inside a prop scene whose
## nodes are all plain Node3D / MeshInstance3D. A prop scene is consumed whole
## (a baked scene can't record a deleted child of an instance), and anything
## else — scripted or physics props, lights, skinned or mirrored meshes —
## stays an ordinary instance. Hidden meshes (collider stand-ins) are dropped.
##
## Trade-offs: a batched prop is no longer a scene instance, so editing its
## scene needs a rebake; and a chunk draws as a whole once any of it is in
## view (visibility ranges become per chunk: the prop's range + the chunk's
## radius).

const GROUP_NAME := "Batches"

var _groups := {}  # key → {mesh, template: MeshInstance3D, chunks: {Vector2i: Array[Transform3D]}}
var _meshes := {}  # key of mesh+surface materials → Mesh to draw
var _chunk := 200.0
var _root: Node3D
var _batched := 0


## Batches every eligible mesh under `root` (a node outside the tree is fine)
## into a `Batches` child of it. Returns the number of MeshInstance3Ds merged.
func batch(root: Node3D, chunk := 200.0) -> int:
	_root = root
	_chunk = maxf(chunk, 10.0)
	_groups = {}
	_meshes = {}
	_batched = 0
	_collect(root)
	if _groups.is_empty():
		return 0
	var parent := Node3D.new()
	parent.name = GROUP_NAME
	root.add_child(parent)
	var n := 0
	for key: String in _groups:
		var g: Dictionary = _groups[key]
		var chunks: Dictionary = g.chunks
		var coords := chunks.keys()
		coords.sort()
		for c: Vector2i in coords:
			var xforms: Array = chunks[c]
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = g.mesh
			mm.instance_count = xforms.size()
			var anchor := Vector3((c.x + 0.5) * _chunk, 0.0, (c.y + 0.5) * _chunk)
			for i in xforms.size():
				var t: Transform3D = xforms[i]
				t.origin -= anchor
				mm.set_instance_transform(i, t)
			var mmi := MultiMeshInstance3D.new()
			mmi.name = "B%d" % n
			n += 1
			mmi.multimesh = mm
			mmi.position = anchor
			_copy_render_settings(g.template, mmi)
			mmi.visibility_range_end = 0.0 if g.template.visibility_range_end <= 0.0 else g.template.visibility_range_end + _chunk * 0.75
			parent.add_child(mmi)
	for g: Dictionary in _groups.values():
		g.template.free()
	return _batched


func _copy_render_settings(from: MeshInstance3D, to: MultiMeshInstance3D) -> void:
	to.layers = from.layers
	to.cast_shadow = from.cast_shadow
	to.gi_mode = from.gi_mode
	to.material_override = from.material_override
	to.material_overlay = from.material_overlay
	to.transparency = from.transparency
	to.visibility_range_begin = from.visibility_range_begin
	to.visibility_range_begin_margin = from.visibility_range_begin_margin
	to.visibility_range_end_margin = from.visibility_range_end_margin
	to.visibility_range_fade_mode = from.visibility_range_fade_mode
	to.ignore_occlusion_culling = from.ignore_occlusion_culling
	to.extra_cull_margin = from.extra_cull_margin
	to.lod_bias = from.lod_bias


func _collect(node: Node) -> void:
	for child in node.get_children():
		if not child is Node3D or child.get_script() != null:
			continue
		var c3 := child as Node3D
		if not c3.scene_file_path.is_empty():
			# a prop scene: all of it or none of it
			if _unit_ok(c3):
				_take_unit(c3)
				c3.get_parent().remove_child(c3)
				c3.free()
			continue
		if c3 is MeshInstance3D:
			var mi := c3 as MeshInstance3D
			if not c3.get_child_count() == 0:
				continue
			if not mi.visible:
				continue  # loose hidden meshes may be toggled by game code: leave them
			if _mesh_ok(mi):
				_add(mi, _rel(mi))
				node.remove_child(mi)
				mi.free()
		elif c3.get_class() == "Node3D":
			_collect(c3)


## True when every node of the prop scene is a plain Node3D or a MeshInstance3D
## that is either hidden or batchable.
func _unit_ok(node: Node3D) -> bool:
	if node.get_script() != null:
		return false
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.get_child_count() > 0:
			return false
		return not mi.visible or _mesh_ok(mi)
	if node.get_class() != "Node3D":
		return false
	for child in node.get_children():
		if not child is Node3D or not _unit_ok(child):
			return false
	return true


func _take_unit(node: Node3D) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null and _visible_chain(mi):
			_add(mi, _rel(mi))
		return
	for child in node.get_children():
		_take_unit(child)


func _visible_chain(node: Node3D) -> bool:
	while node != _root and node != null:
		if not node.visible:
			return false
		node = node.get_parent() as Node3D
	return true


func _mesh_ok(mi: MeshInstance3D) -> bool:
	if mi.mesh == null or mi.skin != null or mi.has_meta("no_batch"):
		return false
	if not mi.get_skeleton_path().is_empty() and mi.get_skeleton_path() != NodePath(".."):
		return false
	if mi.get_blend_shape_count() > 0 or not _visible_chain(mi):
		return false
	return _rel(mi).basis.determinant() > 0.0


func _rel(node: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	while node != _root and node != null:
		t = node.transform * t
		node = node.get_parent() as Node3D
	return t


func _add(mi: MeshInstance3D, t: Transform3D) -> void:
	var overrides := []
	var any_override := false
	for s in mi.mesh.get_surface_count():
		var m := mi.get_surface_override_material(s)
		overrides.append(m)
		any_override = any_override or m != null
	var mesh_key := str(mi.mesh.get_instance_id())
	if any_override:
		for m: Material in overrides:
			mesh_key += "/" + (str(m.get_instance_id()) if m else "-")
	var key := "%s|%d|%d|%s|%s|%d|%d|%f|%f|%f|%f|%d|%d|%f|%f" % [mesh_key,
			mi.layers, mi.cast_shadow, _id(mi.material_override), _id(mi.material_overlay),
			mi.gi_mode, mi.visibility_range_fade_mode, mi.visibility_range_begin,
			mi.visibility_range_end, mi.visibility_range_begin_margin, mi.visibility_range_end_margin,
			int(mi.ignore_occlusion_culling), int(mi.transparency * 100.0), mi.extra_cull_margin, mi.lod_bias]
	var g: Dictionary = _groups.get(key, {})
	if g.is_empty():
		var mesh := mi.mesh
		if any_override:
			mesh = _meshes.get(mesh_key)
			if mesh == null:
				mesh = mi.mesh.duplicate()
				for s in overrides.size():
					if overrides[s] != null:
						mesh.surface_set_material(s, overrides[s])
				_meshes[mesh_key] = mesh
		g = {mesh = mesh, template = mi.duplicate(), chunks = {}}
		_groups[key] = g
	var cell := Vector2i(floori(t.origin.x / _chunk), floori(t.origin.z / _chunk))
	if not g.chunks.has(cell):
		g.chunks[cell] = []
	g.chunks[cell].append(t)
	_batched += 1


func _id(o: Object) -> String:
	return str(o.get_instance_id()) if o else "-"
