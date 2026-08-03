extends SceneTree
## One-shot repair for the NavigationObstacle3D nodes saved in Main.tscn.
##
##   godot --headless --path <project> --script res://tools/refit_carve_outlines.gd
##   ... --script res://tools/refit_carve_outlines.gd -- --check   (dry run)
##
## Fixes two things at once:
##
## 1. THE WARNING TRIANGLES. NavigationObstacle3D only supports rotation around Y, and
##    every prop on the bench is tilted at least slightly (368 under 1 degree, but 43 are
##    over 30 and one is at 175). An obstacle inherits its parent's basis, so all 522
##    warned. Each obstacle now carries a local basis that is the inverse of its body's,
##    leaving its global basis identity -- no tilt, no warning.
##
## 2. THE CARVE SHAPE. With the obstacle untilted, its local axes are world axes, so the
##    outline is written as the prop's true WORLD-space footprint: the 2D convex hull of
##    every collision point projected onto the XZ plane. Previously the outline was a
##    body-space AABB rectangle, which is only correct for an untilted prop -- a prop
##    lying on its side carved its height instead of its width.
##
## It edits the scene as TEXT, touching only the transform/radius/height/vertices lines
## inside NavigationObstacle3D blocks, so every other node, instance override and
## unique_id survives byte-for-byte.

const SCENE_PATH := "res://scenes/Main.tscn"
const MIN_REACH := 0.2
## Above this many hull points the outline is replaced by its bounding rectangle -- a
## 30-point outline costs bake time for no useful accuracy.
const MAX_HULL_POINTS := 10

var _started := false


func _process(_delta: float) -> bool:
	if _started:
		return true
	_started = true

	var dry := "--check" in OS.get_cmdline_user_args() or "--check" in OS.get_cmdline_args()

	var main := (load(SCENE_PATH) as PackedScene).instantiate()
	root.add_child(main)

	var fits := {}
	for node: Node in main.get_children():
		var body := node as PhysicsBody3D
		if body == null:
			continue
		if body.get_node_or_null("NavigationObstacle3D") == null:
			continue
		var fit := _measure(body)
		if not fit.is_empty():
			fits[String(body.name)] = fit
	print("measured %d props" % fits.size())

	var text := FileAccess.get_file_as_string(SCENE_PATH)
	if text.is_empty():
		print("could not read ", SCENE_PATH)
		quit(1)
		return true

	var out := PackedStringArray()
	var in_obstacle := false
	var parent := ""
	var changed := 0

	for line in text.split("\n"):
		if line.begins_with("[node "):
			in_obstacle = line.contains('type="NavigationObstacle3D"')
			parent = _attr(line, "parent") if in_obstacle else ""
			if in_obstacle and not fits.has(parent):
				in_obstacle = false
			out.append(line)
			if in_obstacle:
				# Untilt: written straight after the header so it cannot be missed.
				out.append("transform = %s" % _transform_str(fits[parent]["basis"]))
				changed += 1
			continue

		if in_obstacle:
			# Drop the old versions of the lines we own; everything else passes through.
			if (
				line.begins_with("transform = ")
				or line.begins_with("radius = ")
				or line.begins_with("height = ")
				or line.begins_with("vertices = ")
			):
				if line.begins_with("radius = "):
					out.append("radius = %s" % _num(fits[parent]["radius"]))
					out.append("height = %s" % _num(fits[parent]["height"]))
					out.append("vertices = %s" % _outline_str(fits[parent]["outline"]))
				continue

		out.append(line)

	print("rewrote %d obstacle blocks" % changed)
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


## Everything the obstacle needs: the local basis that cancels the body's rotation, the
## world-space footprint hull relative to the body origin, the height, and a radius.
func _measure(body: PhysicsBody3D) -> Dictionary:
	var points := PackedVector2Array()
	var min_y := 1e9
	var max_y := -1e9
	var origin := body.global_position

	for child: Node in body.get_children():
		var cs := child as CollisionShape3D
		if cs == null or cs.shape == null:
			continue
		var xf := body.global_transform * cs.transform
		for p: Vector3 in _shape_points(cs.shape):
			var w := xf * p
			points.append(Vector2(w.x - origin.x, w.z - origin.z))
			min_y = minf(min_y, w.y)
			max_y = maxf(max_y, w.y)
	if points.is_empty():
		return {}

	var hull := Geometry2D.convex_hull(points)
	if hull.size() > MAX_HULL_POINTS or hull.size() < 3:
		hull = _bounding_rect(points)
	# Godot closes the polygon itself; a duplicated last point makes a degenerate edge.
	if hull.size() > 1 and hull[0].is_equal_approx(hull[hull.size() - 1]):
		hull.remove_at(hull.size() - 1)

	var reach := 0.0
	for p: Vector2 in hull:
		reach = maxf(reach, p.length())

	return {
		"basis": body.global_basis.inverse(),
		"outline": hull,
		"height": maxf(max_y - min_y, MIN_REACH),
		"radius": maxf(reach, MIN_REACH),
	}


## Representative points for a shape: real hull points where we have them, AABB corners
## otherwise. Hull points matter -- the AABB of a rotated hull is much fatter than the
## hull itself, and that difference is exactly the phantom wall we are removing.
func _shape_points(shape: Shape3D) -> Array:
	var convex := shape as ConvexPolygonShape3D
	if convex != null and convex.points.size() >= 4:
		var list := []
		for p: Vector3 in convex.points:
			list.append(p)
		return list
	var box: AABB = shape.get_debug_mesh().get_aabb()
	var list2 := []
	for i in 8:
		list2.append(box.get_endpoint(i))
	return list2


func _bounding_rect(points: PackedVector2Array) -> PackedVector2Array:
	var mn := Vector2(1e9, 1e9)
	var mx := Vector2(-1e9, -1e9)
	for p: Vector2 in points:
		mn.x = minf(mn.x, p.x)
		mn.y = minf(mn.y, p.y)
		mx.x = maxf(mx.x, p.x)
		mx.y = maxf(mx.y, p.y)
	return PackedVector2Array([
		Vector2(mn.x, mn.y), Vector2(mx.x, mn.y), Vector2(mx.x, mx.y), Vector2(mn.x, mx.y),
	])


## Transform3D's 12-float form takes the basis as ROWS, while GDScript's basis.x/y/z are
## COLUMNS. Writing the columns would store the transpose -- for a rotation, the inverse.
func _transform_str(b: Basis) -> String:
	var v := [
		b.x.x, b.y.x, b.z.x,
		b.x.y, b.y.y, b.z.y,
		b.x.z, b.y.z, b.z.z,
		0.0, 0.0, 0.0,
	]
	var parts := PackedStringArray()
	for n: float in v:
		parts.append(_num(n))
	return "Transform3D(%s)" % ", ".join(parts)


func _outline_str(hull: PackedVector2Array) -> String:
	var parts := PackedStringArray()
	for p: Vector2 in hull:
		parts.append(_num(p.x))
		parts.append("0")
		parts.append(_num(p.y))
	return "PackedVector3Array(%s)" % ", ".join(parts)


func _attr(line: String, key: String) -> String:
	var needle := key + '="'
	var i := line.find(needle)
	if i < 0:
		return ""
	var start := i + needle.length()
	var end := line.find('"', start)
	return line.substr(start, end - start)


func _num(v: float) -> String:
	if absf(v) < 0.00001:
		return "0"
	return String.num(v, 5).trim_suffix("0").trim_suffix(".")
