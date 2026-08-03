extends Control
## Top-left tactical radar. Draws the bench around the player as a disc: the maze
## they built as blocky grey footprints, the swarm as red dots, themselves as an
## arrow at the centre.
##
## The point of it is the aggro mechanic. Enemies only chase what they can see, so
## the player needs to know where the swarm is *without* stepping out from behind
## cover to look -- otherwise the only way to gather information is to break line
## of sight, which is exactly the mistake the radar should let them avoid making.
##
## Everything is found by GROUP, never by node path: the player moves between
## scenes, props are converted in bulk, and enemies are spawned at runtime by
## WaveSpawner, so there is no stable path to any of them.
##
## Drawn entirely in _draw() rather than built from child nodes. The contents
## change every frame and most of it is off-radar at any moment, so immediate-mode
## drawing avoids churning hundreds of Node2Ds that would mostly stay hidden.

@export_group("Radar")
## World radius, in metres, mapped onto the radar disc. Anything further out than
## this is not drawn at all.
@export var radar_radius_meters := 30.0
## Radius of the drawn disc in pixels. With the node at 160x160 this leaves a
## 10 px margin inside the control.
@export var radar_pixel_radius := 70.0

@export_group("Groups")
## Runtime-spawned enemies. Must match WaveSpawner's own `enemy_group`.
@export var enemy_group := "enemies"
## The bench clutter. Same group the drag tool and the navmesh baker read.
@export var prop_group := "draggable"
@export var player_group := "player"

@export_group("Behaviour")
## Rotate the radar so the player's facing is always up. Turn this off for a
## north-up radar, where the world's -Z is up instead.
@export var rotate_with_player := true

## Centre of the disc in control-local pixels. Matches the 160x160 size the node
## is authored at in Player.tscn -- resize the node and this wants updating too.
const CENTER := Vector2(80, 80)

const BACKGROUND_COLOR := Color(0.04, 0.07, 0.1, 0.8)
const BORDER_COLOR := Color(0.2, 0.85, 0.5, 0.8)
const BORDER_WIDTH := 2.0
## The grid is meant to read as a faint scale reference, not as content -- it sits
## under the props and must never compete with an enemy dot for attention.
const GRID_COLOR := Color(0.2, 0.85, 0.5, 0.18)
const PROP_COLOR := Color(0.45, 0.55, 0.65, 0.6)
const ENEMY_COLOR := Color(1.0, 0.2, 0.2, 0.9)
const ENEMY_DOT_RADIUS := 4.0
const SELF_COLOR := Color(0.3, 1.0, 0.75, 1.0)
const SELF_MARKER_SIZE := 7.0

## Fallback footprint, in metres, for a prop with no measurable geometry.
const DEFAULT_PROP_SIZE := Vector2(2.0, 2.0)

var _player: Node3D = null
## Prop footprint half-extents, keyed by instance id. See _measure_prop() for why
## this is cached rather than measured per frame.
var _extent_cache: Dictionary = {}


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	_draw_backdrop()

	var player := _resolve_player()
	if player == null:
		# No player yet (or between scenes): show an empty scope rather than
		# nothing at all, so a missing group reads as "no contacts" and not as a
		# broken HUD element.
		_draw_self_marker()
		return

	var origin := player.global_position
	var yaw := player.global_rotation.y if rotate_with_player else 0.0
	var cos_y := cos(yaw)
	var sin_y := sin(yaw)

	_draw_props(origin, yaw, cos_y, sin_y)
	_draw_enemies(origin, cos_y, sin_y)
	_draw_self_marker()


## Disc, scale rings and crosshair. Drawn back to front so the border sits on top
## of the grid lines that run out to meet it.
func _draw_backdrop() -> void:
	draw_circle(CENTER, radar_pixel_radius, BACKGROUND_COLOR)
	draw_line(
		CENTER - Vector2(radar_pixel_radius, 0.0),
		CENTER + Vector2(radar_pixel_radius, 0.0),
		GRID_COLOR,
		1.0
	)
	draw_line(
		CENTER - Vector2(0.0, radar_pixel_radius),
		CENTER + Vector2(0.0, radar_pixel_radius),
		GRID_COLOR,
		1.0
	)
	draw_arc(CENTER, radar_pixel_radius * 0.5, 0.0, TAU, 48, GRID_COLOR, 1.0)
	draw_arc(CENTER, radar_pixel_radius, 0.0, TAU, 64, BORDER_COLOR, BORDER_WIDTH)


## The maze, as rotated rectangles. Props are the whole point of the radar -- the
## player built the layout and needs to recognise it from above -- so they are
## drawn to their real footprint and angle rather than as dots.
func _draw_props(origin: Vector3, yaw: float, cos_y: float, sin_y: float) -> void:
	var ppm := _pixels_per_meter()
	var range_squared := radar_radius_meters * radar_radius_meters

	for node: Node in get_tree().get_nodes_in_group(prop_group):
		var prop := node as Node3D
		if prop == null or not prop.is_inside_tree():
			continue

		var pos := prop.global_position
		var dx := pos.x - origin.x
		var dz := pos.z - origin.z
		if dx * dx + dz * dz > range_squared:
			continue

		var centre := _to_radar(pos, origin, cos_y, sin_y)
		var half := _prop_extents(prop)
		# Screen-space rotation is the player's yaw MINUS the prop's: turning the
		# player left has to sweep the world right underneath them. Screen Y also
		# grows downward, which is what flips the sign relative to world yaw.
		var angle := yaw - prop.global_rotation.y
		var along_x := Vector2(cos(angle), sin(angle)) * (half.x * ppm)
		var along_z := Vector2(-sin(angle), cos(angle)) * (half.y * ppm)

		draw_colored_polygon(
			PackedVector2Array([
				centre - along_x - along_z,
				centre + along_x - along_z,
				centre + along_x + along_z,
				centre - along_x + along_z,
			]),
			PROP_COLOR
		)


func _draw_enemies(origin: Vector3, cos_y: float, sin_y: float) -> void:
	for node: Node in get_tree().get_nodes_in_group(enemy_group):
		var enemy := node as Node3D
		# A queue_free()d node stays in its group until the end of the frame, so
		# without this guard a wave that was just cleared keeps painting dots.
		if enemy == null or not enemy.is_inside_tree() or enemy.is_queued_for_deletion():
			continue

		var point := _to_radar(enemy.global_position, origin, cos_y, sin_y)
		# Clip against the disc, not the control's rectangle -- a contact just
		# outside the ring would otherwise appear in the corners of the square.
		# Inset by the dot radius so dots never straddle the border.
		if point.distance_to(CENTER) > radar_pixel_radius - ENEMY_DOT_RADIUS:
			continue
		draw_circle(point, ENEMY_DOT_RADIUS, ENEMY_COLOR)


## The player, always dead centre and always pointing up: with rotate_with_player
## on, up IS their facing, and the arrow is what makes that legible.
func _draw_self_marker() -> void:
	draw_colored_polygon(
		PackedVector2Array([
			CENTER + Vector2(0.0, -SELF_MARKER_SIZE),
			CENTER + Vector2(-SELF_MARKER_SIZE * 0.7, SELF_MARKER_SIZE * 0.7),
			CENTER + Vector2(SELF_MARKER_SIZE * 0.7, SELF_MARKER_SIZE * 0.7),
		]),
		SELF_COLOR
	)


## World position -> radar pixels, relative to the player and rotated into their
## frame.
##
## The player's forward is -Z (the convention the capsule and the enemies both
## use), so for a yaw of `y` forward is (-sin y, -cos y) and right is
## (cos y, -sin y) on the XZ plane. Projecting the offset onto those two gives the
## radar axes; the forward component is then negated because screen Y grows
## downward while "ahead" has to draw upward.
func _to_radar(world: Vector3, origin: Vector3, cos_y: float, sin_y: float) -> Vector2:
	var dx := world.x - origin.x
	var dz := world.z - origin.z
	var forward := -(dx * sin_y + dz * cos_y)
	var right := dx * cos_y - dz * sin_y
	return CENTER + Vector2(right, -forward) * _pixels_per_meter()


func _pixels_per_meter() -> float:
	return radar_pixel_radius / maxf(radar_radius_meters, 0.001)


func _resolve_player() -> Node3D:
	if _player != null and is_instance_valid(_player) and _player.is_inside_tree():
		return _player
	_player = null
	for node: Node in get_tree().get_nodes_in_group(player_group):
		var candidate := node as Node3D
		if candidate != null:
			_player = candidate
			break
	return _player


## Cached footprint half-extents, in metres, along the prop's own X and Z.
##
## Measured once per prop and kept. Measuring is not cheap -- get_debug_mesh()
## rebuilds geometry for the shape -- and the bench carries ~500 draggables, so
## doing this inside _draw() would cost more than everything else on the HUD put
## together. Props are never freed during a round, so the cache cannot grow
## unbounded; their footprint does not change when they are dragged, only their
## transform does, and that is read fresh every frame.
func _prop_extents(prop: Node3D) -> Vector2:
	var id := prop.get_instance_id()
	if _extent_cache.has(id):
		return _extent_cache[id]

	var footprint := _shape_footprint(prop)
	if footprint == Vector2.ZERO:
		footprint = _visual_footprint(prop)
	if footprint == Vector2.ZERO:
		footprint = DEFAULT_PROP_SIZE

	var half := footprint * 0.5
	_extent_cache[id] = half
	return half


## Footprint from the prop's collision shapes, in body space. Preferred over the
## visual bounds because it is what the player and the enemies actually collide
## with, which is what the maze is made of. Returns ZERO if there are none.
func _shape_footprint(prop: Node3D) -> Vector2:
	var bounds := AABB()
	var found := false
	for child in prop.get_children():
		var shape_node := child as CollisionShape3D
		if shape_node == null or shape_node.shape == null:
			continue
		# get_debug_mesh() covers every shape type; reaching for a per-type
		# `size` or `radius` would miss the convex hulls the props actually use.
		var box: AABB = shape_node.transform * shape_node.shape.get_debug_mesh().get_aabb()
		bounds = bounds.merge(box) if found else box
		found = true
	return Vector2(bounds.size.x, bounds.size.z) if found else Vector2.ZERO


## Fallback footprint from rendered geometry, for anything tagged draggable that
## has no collision shape of its own.
func _visual_footprint(prop: Node3D) -> Vector2:
	# global_transform on a node outside the tree does not just give a poor
	# answer, it errors and hands back identity -- which would silently measure
	# the prop in the wrong frame. Fall through to the default size instead.
	if not prop.is_inside_tree():
		return Vector2.ZERO

	var bounds := AABB()
	var found := false
	var to_local_space := prop.global_transform.affine_inverse()
	for node in _descendants(prop):
		var visual := node as VisualInstance3D
		if visual == null:
			continue
		var box: AABB = (to_local_space * visual.global_transform) * visual.get_aabb()
		bounds = bounds.merge(box) if found else box
		found = true
	return Vector2(bounds.size.x, bounds.size.z) if found else Vector2.ZERO


func _descendants(root: Node) -> Array[Node]:
	var found: Array[Node] = []
	for child in root.get_children():
		found.append(child)
		found.append_array(_descendants(child))
	return found
