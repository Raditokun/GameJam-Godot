extends SceneTree
## Rebuilds the collision shapes of props ALREADY converted in Main.tscn, using
## PropConverter's current (multi-convex) shape builder.
##
## PropConverter.convert_scene() cannot do this: it skips anything already in the
## `draggable` group, so re-running it over a converted scene is a no-op. This
## walks the converted bodies instead, drops their existing CollisionShape3Ds and
## builds new ones from the Model child's meshes.
##
## Usage (headless):
##   godot --headless --path <project> --script res://tools/rebuild_prop_colliders.gd -- [args]
##     --sample=N   only process the first N props (dry-run projection)
##     --save       actually write Main.tscn back; omit to leave it untouched
##
## `bowl_dirty2` is deliberately excluded: CLAUDE.md documents it as the
## hand-tuned reference the whole prop pipeline was calibrated against, and its
## CylinderShape3D was fitted by hand.

const SCENE_PATH := "res://scenes/Main.tscn"
const DRAG_GROUP := "draggable"
const EXCLUDE := ["bowl_dirty2"]


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var sample := -1
	var save := false
	for a in args:
		if a.begins_with("--sample="):
			sample = int(a.split("=")[1])
		elif a == "--save":
			save = true

	print("scene   = ", SCENE_PATH)
	print("sample  = ", "all" if sample < 0 else str(sample))
	print("save    = ", save)

	var packed := load(SCENE_PATH) as PackedScene
	if packed == null:
		print("FAIL: could not load ", SCENE_PATH)
		quit(1)
		return

	# Wait for the root window to be live BEFORE the scene goes in. Nodes added
	# during _initialize() are not "inside tree" yet and global_transform silently
	# returns identity, which would build every hull in the wrong frame.
	await process_frame

	var scene := packed.instantiate()
	var before_nodes := _count_nodes(scene)
	get_root().add_child(scene)

	# From here to pack() there must be NO await. add_child runs _ready() on the
	# whole scene, which is harmless, but letting a single frame process is not:
	# WaveSpawner._physics_process() calls clear_enemies(), which adopts the
	# hand-placed Enemy instance into `enemies` and queue_free()s it -- and the
	# packed scene then comes out with the Enemy missing. Learned the hard way.
	print("nodes in fresh instance = ", before_nodes)

	var converter = load("res://tools/PropConverter.gd").new()

	var bodies: Array[Node] = []
	for node in scene.get_children():
		var body := node as RigidBody3D
		if body == null or not body.is_in_group(DRAG_GROUP):
			continue
		if EXCLUDE.has(String(body.name)):
			continue
		bodies.append(body)
	print("converted props found = ", bodies.size())

	var limit: int = bodies.size() if sample < 0 else mini(sample, bodies.size())
	var before_total := 0
	var after_total := 0
	var processed := 0
	var multi := 0
	var fallback_boxes := 0
	var started := Time.get_ticks_msec()

	for i in limit:
		var body := bodies[i] as RigidBody3D
		var model := body.get_node_or_null("Model")
		if model == null:
			continue
		var meshes := _find_meshes(model)
		if meshes.is_empty():
			continue

		var old: Array[Node] = []
		for c in body.get_children():
			if c is CollisionShape3D:
				old.append(c)
		before_total += old.size()

		var local: AABB = converter._local_mesh_aabb(meshes, body)
		var size := Vector3(
			maxf(local.size.x, converter.MIN_EXTENT),
			maxf(local.size.y, converter.MIN_EXTENT),
			maxf(local.size.z, converter.MIN_EXTENT)
		)
		var fresh: Array = converter.build_collision_shapes(meshes, body, local, size)
		if fresh.is_empty():
			continue

		for c in old:
			body.remove_child(c)
			c.queue_free()
		for s in fresh:
			body.add_child(s)
			s.owner = scene
			if s.shape is BoxShape3D:
				fallback_boxes += 1
		after_total += fresh.size()
		if fresh.size() > 1:
			multi += 1
		processed += 1

		if processed % 25 == 0:
			var elapsed := Time.get_ticks_msec() - started
			print("  ...%d/%d props, %d ms elapsed (%.0f ms/prop)"
				% [processed, limit, elapsed, float(elapsed) / processed])

	var total_ms := Time.get_ticks_msec() - started
	print("--- result ---")
	print("props processed    = ", processed)
	print("shapes before      = ", before_total)
	print("shapes after       = ", after_total)
	print("ratio              = %.2fx" % (float(after_total) / maxf(before_total, 1)))
	print("props with >1 hull = ", multi, " of ", processed)
	print("fallback boxes     = ", fallback_boxes)
	print("time               = %d ms (%.0f ms/prop)" % [total_ms, float(total_ms) / maxi(processed, 1)])
	if sample >= 0 and processed > 0:
		var per: float = float(after_total) / processed
		var per_ms: float = float(total_ms) / processed
		print("PROJECTED over all %d props: ~%d shapes, ~%.0f s to run"
			% [bodies.size(), int(per * bodies.size()), per_ms * bodies.size() / 1000.0])

	# Nothing may have vanished. A queue_free()d node is still in the tree at this
	# point, so count only what is actually still live.
	var after_nodes := _count_nodes(scene)
	var doomed := _count_doomed(scene)
	print("nodes now              = ", after_nodes, " (expected ",
		before_nodes + after_total - before_total, ")")
	print("queued for deletion    = ", doomed, " (must be 0)")
	if doomed != 0:
		print("FAIL: the scene's own scripts freed something -- refusing to save")
		quit(1)
		return

	if save:
		var out := PackedScene.new()
		var err := out.pack(scene)
		if err != OK:
			print("FAIL: pack() returned ", err)
			quit(1)
			return
		err = ResourceSaver.save(out, SCENE_PATH)
		print("saved -> ", SCENE_PATH, "  err=", err)
		if err != OK:
			quit(1)
			return
	else:
		print("(dry run -- Main.tscn NOT written)")
	quit(0)


func _count_nodes(node: Node) -> int:
	var total := 1
	for child in node.get_children():
		total += _count_nodes(child)
	return total


func _count_doomed(node: Node) -> int:
	var total := 1 if node.is_queued_for_deletion() else 0
	for child in node.get_children():
		total += _count_doomed(child)
	return total


func _find_meshes(node: Node) -> Array[MeshInstance3D]:
	var found: Array[MeshInstance3D] = []
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		found.append(node as MeshInstance3D)
	for child in node.get_children():
		found.append_array(_find_meshes(child))
	return found
