extends SceneTree
## One-shot repair: rewrite every NavigationObstacle3D carve outline already saved in
## Main.tscn from a single-radius circle to a per-axis octagon matching the prop.
##
##   godot --headless --path <project> --script res://tools/refit_carve_outlines.gd
##
## PropConverter.gd generates outlines correctly now; this fixes the 503 props that were
## converted before that change. It edits Main.tscn as TEXT, replacing only the `radius`
## and `vertices` lines inside NavigationObstacle3D blocks, so every other node,
## instance override and unique_id in the scene is left byte-for-byte alone.
##
## Pass --check to report what would change without writing.

const SCENE_PATH := "res://scenes/Main.tscn"
const SIDES := 8
const MIN_REACH := 0.2

var _started := false


func _process(_delta: float) -> bool:
	if _started:
		return true
	_started = true

	var dry := "--check" in OS.get_cmdline_user_args() or "--check" in OS.get_cmdline_args()

	# 1. Measure every prop's real footprint from its own collision shapes.
	var main := (load(SCENE_PATH) as PackedScene).instantiate()
	root.add_child(main)
	var fits := {}
	for node: Node in main.get_children():
		var body := node as PhysicsBody3D
		if body == null:
			continue
		if body.get_node_or_null("NavigationObstacle3D") == null:
			continue
		var fp := _footprint(body)
		if fp.is_empty():
			continue
		fits[String(body.name)] = fp
	print("measured %d props" % fits.size())

	# 2. Rewrite the radius/vertices lines inside each obstacle block.
	var text := FileAccess.get_file_as_string(SCENE_PATH)
	if text.is_empty():
		print("could not read ", SCENE_PATH)
		quit(1)
		return true

	var out := PackedStringArray()
	var in_obstacle := false
	var parent := ""
	var changed := 0
	var skipped := 0

	for line in text.split("\n"):
		if line.begins_with("[node "):
			in_obstacle = line.contains('type="NavigationObstacle3D"')
			parent = _attr(line, "parent") if in_obstacle else ""
			if in_obstacle and not fits.has(parent):
				skipped += 1
				in_obstacle = false
			out.append(line)
			continue

		if in_obstacle and (line.begins_with("radius = ") or line.begins_with("vertices = ")):
			var fp: Dictionary = fits[parent]
			if line.begins_with("radius = "):
				out.append("radius = %s" % _num(maxf(fp.rx, fp.rz)))
				changed += 1
			else:
				out.append("vertices = %s" % _outline(fp))
			continue

		out.append(line)

	print("rewrote outlines for %d props (%d obstacle blocks had no matching prop)" % [
		changed, skipped,
	])
	if dry:
		print("--check: nothing written")
		quit(0)
		return true

	var f := FileAccess.open(SCENE_PATH, FileAccess.WRITE)
	if f == null:
		print("could not open for write")
		quit(1)
		return true
	f.store_string("\n".join(out))
	f.close()
	print("saved ", SCENE_PATH)
	quit(0)
	return true


## The prop's footprint rectangle, in the body's local space. Not a circle (which walls
## off metres of empty floor around thin props) and not an inscribed octagon (which cuts
## the corners and leaves walkable slivers inside solid props).
func _outline(fp: Dictionary) -> String:
	var corners := [
		Vector2(-fp.rx, -fp.rz),
		Vector2(fp.rx, -fp.rz),
		Vector2(fp.rx, fp.rz),
		Vector2(-fp.rx, fp.rz),
	]
	var parts := PackedStringArray()
	for c: Vector2 in corners:
		parts.append(_num(fp.cx + c.x))
		parts.append("0")
		parts.append(_num(fp.cz + c.y))
	return "PackedVector3Array(%s)" % ", ".join(parts)


## Half extents and centre of the body's collision shapes, in body space.
func _footprint(body: PhysicsBody3D) -> Dictionary:
	var box := AABB()
	var first := true
	for child: Node in body.get_children():
		var cs := child as CollisionShape3D
		if cs == null or cs.shape == null:
			continue
		var b: AABB = cs.shape.get_debug_mesh().get_aabb()
		b.position += cs.position
		if first:
			box = b
			first = false
		else:
			box = box.merge(b)
	if first:
		return {}
	var c := box.get_center()
	return {
		"cx": c.x,
		"cz": c.z,
		"rx": maxf(box.size.x * 0.5, MIN_REACH),
		"rz": maxf(box.size.z * 0.5, MIN_REACH),
	}


func _attr(line: String, key: String) -> String:
	var needle := key + '="'
	var i := line.find(needle)
	if i < 0:
		return ""
	var start := i + needle.length()
	var end := line.find('"', start)
	return line.substr(start, end - start)


func _num(v: float) -> String:
	return String.num(v, 5).trim_suffix("0").trim_suffix(".")
