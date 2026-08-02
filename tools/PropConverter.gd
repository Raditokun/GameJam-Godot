@tool
extends RefCounted
## Bulk converter: turns raw prop nodes into draggable physics props that behave
## exactly like `bowl_dirty2`.
##
## The editor entry point is `tools/BulkPropSetup.gd` -- run THAT, not this.
## The logic lives here as a plain RefCounted rather than on the EditorScript
## because `EditorScript` refuses to instantiate outside the editor, which would
## make this whole conversion impossible to test headlessly.
##
## Running it twice is safe -- anything already converted is skipped.
##
## WHAT EACH PROP BECOMES
##   PropName (RigidBody3D)          <- physics body, no scale, in "draggable"
##   +- Model (the original node)    <- the scale lives here
##   +- CollisionShape3D (BoxShape3D from the mesh AABB)
##   +- NavigationObstacle3D         <- so the enemy paths around it
##
## Two details are load-bearing, both learned from the bowl:
##   - The SCALE goes on the Model child, never on the body. A scaled collider
##     is something Jolt handles badly; the body stays at scale 1 and the shape
##     is sized in world units instead.
##   - The NavigationObstacle3D gets a `vertices` outline, not just a radius.
##     `radius` only feeds avoidance; without the outline the navmesh bake
##     produces no hole at all and the enemy walks straight through the maze.

## Nodes are picked by TYPE, not by name -- anything that is already a physics
## body, a camera, a light, a CSG shape, a marker or a navigation node is left
## alone, which covers Player, Enemy, meja, bowl_dirty2, PrepCamera, EnemyGoal,
## Navigation, Floor, Ramp and the stairs without naming any of them.
## Add names here only if something slips through.
const SKIP_NAMES: Array[String] = []

## Group the drag tool searches. NOTE: there is no drag script to attach --
## PrepCamera.gd owns the whole mechanic and finds bodies by this group, which
## is why the bowl has no script on it either.
const DRAG_GROUP := "draggable"
## Group the navmesh bake parses (GROUPS_WITH_CHILDREN, so the obstacle child
## is reached through the body).
const NAV_GROUP := "navmesh_source"

## Mass = volume * DENSITY, clamped. Calibrated against the bench's actual prop
## scale (~4.5x), where it puts a fridge around 20, a crate around 6 and a slice
## of cheese on the floor value -- a spread wide enough that heavy things shove
## light ones convincingly. Tune DENSITY if the props get rescaled: at the
## bowl's much larger 16.6x scale this same value would read far heavier.
const DENSITY := 0.02
const MIN_MASS := 0.3
const MAX_MASS := 60.0

## Collision boxes are never allowed thinner than this on any axis; a flat
## cutting board would otherwise get a paper-thin collider that things tunnel
## straight through.
const MIN_EXTENT := 0.4

## Physics feel, matched to the bowl.
const FRICTION := 0.55
const BOUNCE := 0.05
const LINEAR_DAMP := 0.6
const ANGULAR_DAMP := 1.2

## Corners on the generated navmesh carve outline. 8 is a good circle/box
## compromise and stays valid however the prop is rotated.
const OUTLINE_SIDES := 8


## Converts every eligible direct child of `root`. Returns a small report object
## so this can be driven from a test as well as from the editor.
func convert_scene(root: Node) -> ConversionReport:
	var report := ConversionReport.new()
	# Snapshot the child list first: the loop reparents nodes as it goes.
	var candidates: Array[Node] = []
	for child in root.get_children():
		candidates.append(child)

	for node in candidates:
		var reason := _skip_reason(node)
		if reason != "":
			report.skipped.append(node.name)
			continue
		var body := convert_prop(node as Node3D, root)
		if body == null:
			report.skipped.append(node.name)
			report.log.append("%s -- no mesh found, left alone" % node.name)
			continue
		report.converted.append(body.name)
		report.log.append("%s -- mass %.1f, box %v" % [body.name, body.mass, _box_size_of(body)])
	return report


## Wraps one raw prop node in a physics body. Returns the new body, or null if
## the node has no mesh to measure.
func convert_prop(prop: Node3D, owner_root: Node) -> RigidBody3D:
	var meshes := _find_meshes(prop)
	if meshes.is_empty():
		return null

	var prop_name := prop.name
	var world := prop.global_transform
	# Free the name up so the body can take it, keeping the scene readable.
	prop.name = prop_name + "_RawTemp"

	var body := RigidBody3D.new()
	owner_root.add_child(body)
	body.owner = owner_root
	body.name = prop_name
	# Position and rotation only -- the scale deliberately stays behind on the
	# model, so the physics body is always scale 1.
	body.global_transform = Transform3D(world.basis.orthonormalized(), world.origin)

	# reparent(true) keeps the prop's world transform, which lands the original
	# scale on the child exactly where it belongs.
	prop.reparent(body, true)
	prop.name = "Model"
	_take_ownership(prop, owner_root)

	var local := _local_mesh_aabb(meshes, body)
	var size := Vector3(
		maxf(local.size.x, MIN_EXTENT),
		maxf(local.size.y, MIN_EXTENT),
		maxf(local.size.z, MIN_EXTENT)
	)

	for shape in build_collision_shapes(meshes, body, local, size):
		body.add_child(shape)
		shape.owner = owner_root

	var obstacle := _build_obstacle(local, size)
	obstacle.name = "NavigationObstacle3D"
	body.add_child(obstacle)
	obstacle.owner = owner_root

	var material := PhysicsMaterial.new()
	material.friction = FRICTION
	material.bounce = BOUNCE
	body.physics_material_override = material
	body.mass = clampf(size.x * size.y * size.z * DENSITY, MIN_MASS, MAX_MASS)
	# Frozen by default, and PrepCamera thaws a prop only while it is held.
	#
	# This is a measured decision, not caution: 500 free rigid bodies resting on
	# the bench never actually get to sleep -- 250 stayed awake indefinitely with
	# only 3 of them really moving -- and cost 63 ms per physics frame against a
	# 16.7 ms budget. Frozen, the same 500 cost effectively nothing and all of
	# them sleep. It is also the better feel for a maze builder: a wall stays
	# exactly where it was put instead of creeping when something brushes it.
	# FREEZE_MODE_KINEMATIC specifically, because a statically frozen body
	# ignores the transform writes and forces the drag tool depends on.
	body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	body.freeze = true
	body.continuous_cd = true
	body.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.linear_damp = LINEAR_DAMP
	body.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.angular_damp = ANGULAR_DAMP
	body.add_to_group(DRAG_GROUP, true)
	body.add_to_group(NAV_GROUP, true)
	return body


## Builds the collision shapes for one prop: a convex hull per mesh surface,
## expressed in the body's own space.
##
## Convex, not a box: an axis-aligned box around something irregular -- a
## Christmas tree, a rack, a pile of bars -- is a huge invisible barrier that
## blocks the player and the enemy metres away from anything they can see.
## Convex, not concave/trimesh: a trimesh collider is static-only and cannot be
## used on a moving RigidBody3D at all.
##
## Each MeshInstance3D becomes its own hull, so a multi-part prop ends up with a
## compound collider that follows its shape rather than one hull swallowing the
## gaps between the parts.
func build_collision_shapes(
	meshes: Array[MeshInstance3D], body: Node3D, local: AABB, size: Vector3
) -> Array[CollisionShape3D]:
	var built: Array[CollisionShape3D] = []
	var to_body := body.global_transform.affine_inverse()

	for mesh_instance in meshes:
		var hull: ConvexPolygonShape3D = mesh_instance.mesh.create_convex_shape(true, true)
		if hull == null or hull.points.size() < 4:
			# Degenerate hull (a flat plane, or a mesh Recast could not simplify).
			# Anything under 4 points is not a solid, so fall back to a box.
			continue
		# create_convex_shape() returns points in MESH space. The body is always
		# scale 1 while the model keeps the authored scale, so the points have to
		# be brought across or every hull comes out at 1/scale of its real size.
		var into_body := to_body * mesh_instance.global_transform
		var points := hull.points
		for i in points.size():
			points[i] = into_body * points[i]
		hull.points = points

		var shape := CollisionShape3D.new()
		shape.shape = hull
		# Named explicitly: add_child() on an unnamed node generates the
		# "@Class@12" form, unreadable in the tree and unfindable by get_node().
		shape.name = "CollisionShape3D" if built.is_empty() else "CollisionShape3D%d" % (built.size() + 1)
		built.append(shape)

	if built.is_empty():
		# No usable hull anywhere -- keep the prop solid with the AABB box.
		var box := BoxShape3D.new()
		box.size = size
		var shape := CollisionShape3D.new()
		shape.shape = box
		shape.name = "CollisionShape3D"
		shape.position = local.get_center()
		built.append(shape)
	return built


## Builds the navmesh carve outline: an octagon around the prop's footprint.
## The outline, NOT the radius, is what actually cuts the navigation mesh.
func _build_obstacle(local: AABB, size: Vector3) -> NavigationObstacle3D:
	var obstacle := NavigationObstacle3D.new()
	var centre := local.get_center()
	var reach: float = maxf(size.x, size.z) * 0.5
	var outline := PackedVector3Array()
	for i in OUTLINE_SIDES:
		var angle := TAU * float(i) / float(OUTLINE_SIDES)
		outline.push_back(Vector3(centre.x + cos(angle) * reach, 0.0, centre.z + sin(angle) * reach))
	obstacle.vertices = outline
	obstacle.height = size.y
	obstacle.radius = reach
	obstacle.affect_navigation_mesh = true
	obstacle.carve_navigation_mesh = true
	# Avoidance OFF, and this matters a lot: every obstacle with it enabled joins
	# the RVO simulation every frame, and 500 of them measured 34.8 ms per frame
	# against a 16.7 ms budget -- more than the rest of the physics put together.
	# Carving is what actually routes the enemy around a placed prop; RVO only
	# covers the moment a prop is mid-drag and the navmesh has not caught up, so
	# PrepCamera switches it on for the single prop being held and off again on
	# release.
	obstacle.avoidance_enabled = false
	return obstacle


## Why this node is not a conversion candidate, or "" if it is one.
func _skip_reason(node: Node) -> String:
	if not node is Node3D:
		return "not 3D"
	if SKIP_NAMES.has(node.name):
		return "on the skip list"
	# Anything that already has a physics presence is either already converted
	# or is the player, an enemy, or the bench itself.
	if node is CollisionObject3D:
		return "already a physics body"
	if node is CSGShape3D:
		return "CSG level geometry"
	if node is Camera3D or node is Light3D or node is Marker3D:
		return "not a prop"
	if node is NavigationRegion3D or node is WorldEnvironment:
		return "not a prop"
	if node.is_in_group(DRAG_GROUP):
		return "already converted"
	return ""


func _find_meshes(node: Node) -> Array[MeshInstance3D]:
	var found: Array[MeshInstance3D] = []
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		found.append(node as MeshInstance3D)
	for child in node.get_children():
		found.append_array(_find_meshes(child))
	return found


## Union of every mesh AABB, expressed in `body`'s local space. Measured in the
## body's own frame rather than world space so a rotated prop gets a tight box
## instead of one inflated by its rotation.
func _local_mesh_aabb(meshes: Array[MeshInstance3D], body: Node3D) -> AABB:
	var to_body := body.global_transform.affine_inverse()
	var result := AABB()
	var first := true
	for mesh in meshes:
		var in_body := (to_body * mesh.global_transform) * mesh.get_aabb()
		if first:
			result = in_body
			first = false
		else:
			result = result.merge(in_body)
	return result


## Nodes only get written into the .tscn if the scene root owns them. Instanced
## scenes own their own internals, so recursion stops at an instance boundary.
func _take_ownership(node: Node, owner_root: Node) -> void:
	node.owner = owner_root
	if not node.scene_file_path.is_empty():
		return
	for child in node.get_children():
		_take_ownership(child, owner_root)


func _box_size_of(body: RigidBody3D) -> Vector3:
	for child in body.get_children():
		var shape := child as CollisionShape3D
		if shape != null and shape.shape is BoxShape3D:
			return (shape.shape as BoxShape3D).size
	return Vector3.ZERO


class ConversionReport:
	extends RefCounted
	var converted: Array[String] = []
	var skipped: Array[String] = []
	var log: Array[String] = []
