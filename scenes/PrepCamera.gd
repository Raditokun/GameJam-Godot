extends Camera3D
## The Preparation Phase camera: a high, steeply-angled tactical view of the
## workbench, plus the mouse drag-and-drop tool that goes with it.
##
## The angle is authored in the scene (~75 degrees down, aimed at the middle of
## the tabletop). This script owns everything that angle implies:
##   - it takes over as the current camera while the round is in PREPARATION,
##     and hands back to the player's first-person camera on lock-in;
##   - it frees the mouse cursor, because a tactical view is pointed with the
##     cursor, not with a captured look axis;
##   - it drives a RayCast3D from the cursor into the bench so objects can be
##     picked up, moved over the table and dropped.
##
## Draggable objects are found by group, not by node path: anything in
## `drag_group` that is a physics body can be picked up, so adding the rest of
## the clutter later is a matter of tagging it.

## Group a physics body must be in before this tool will pick it up.
@export var drag_group := "draggable"
## How far the cursor ray reaches into the scene. The bench is enormous from a
## miniature's point of view and this camera sits ~130 units above it, so the
## ray has to be much longer than a first-person interaction range.
@export var pick_distance := 900.0
@export_group("Carry Spring")
## Pull stiffness in 1/seconds-squared. The held body is never teleported --
## it is dragged by a spring-damper anchored at the exact point the cursor
## grabbed it, and the physics engine works out the rest. Raise for a tighter,
## more responsive grip; lower for a heavier, laggier one.
@export var spring_stiffness := 120.0
## Velocity damping in 1/seconds. Critical damping is 2 * sqrt(stiffness)
## (~22 at the default); staying deliberately under that leaves the overshoot
## and settle that reads as momentum.
@export var spring_damping := 14.0
## Ceiling on the spring's stretch, in metres. Without it, grabbing something
## far from the cursor produces a colossal force spike -- across a bench this
## wide the error term can reach 200+ on its own.
@export var max_pull := 25.0
## How far above the surface a held object floats, in metres. A little
## clearance stops the spring from grinding the object along the tabletop.
@export var hover_height := 3.0

@export_group("Carry Sway")
## Lever arm the pull force is allowed to act on, in metres. The tilt is real
## physics -- the force acts at the grabbed point, so it torques the body -- but
## at this scale the raw offset is several metres and the resulting torque flips
## the object end over end. Clamping the arm keeps the lean proportional to
## where you grabbed while staying in a range the solver can settle.
@export var tilt_arm := 0.6
## Restoring torque that rolls a held object back upright, in 1/seconds-squared.
## This is what turns the tilt into a pendulum: accelerate and the object leans,
## stop and it swings level again. Set to 0 to let it tumble freely.
@export var upright_torque := 40.0
## Damping on that restoring torque, in 1/seconds. Too low and a hard yank rings
## forever; too high and the sway is flattened out of existence.
@export var upright_damping := 9.0
## Spin, in newton-metre-seconds, added by one mouse-wheel notch. Applied as a
## torque impulse rather than a rotation, so a held object keeps spinning and
## slows down on its own.
@export var spin_impulse := 45.0

@export_group("Settling")
## Combined linear + angular speed below which a released prop counts as at
## rest and is eligible to be frozen again.
@export var refreeze_speed := 1.5
## Seconds a released prop must stay at rest before it is frozen. Long enough
## that a thrown prop finishes its tumble first.
@export var refreeze_delay := 0.4

@onready var ray: RayCast3D = $MouseRay

## The body currently being dragged, or null. Everything else reads this to
## decide whether a drag is in progress -- keep the identifier plain so it is
## never confused with a property of the body it points at.
var _dragged: RigidBody3D = null
## How far to lift a held body so its lowest collision point rests on the
## surface under the cursor, in metres.
var _base_lift := 0.0
## The spot on the body the cursor actually grabbed, in the body's local space.
## The spring pulls on THIS point rather than the centre of mass, which is what
## makes a fast drag torque the object over instead of sliding it flat.
var _grab_local := Vector3.ZERO
## Where the spring is currently pulling that grab point towards. Kept between
## frames so the object keeps being carried when the cursor leaves the bench
## instead of going limp mid-air.
var _target := Vector3.ZERO
## Gravity restored on release; a held object hangs on the spring alone.
var _rest_gravity_scale := 1.0
## Whether the held prop was frozen before it was picked up, so release can put
## it back the way it was found. Converted props are frozen; the bowl is not.
var _was_frozen := false
## Released props still coming to rest, mapped to how long they have been still.
## Once a prop settles it is frozen again -- see _update_settling().
var _settling := {}


func _ready() -> void:
	# Driven by hand every frame from the cursor, so the node must not also be
	# casting along its own -Z on the physics tick.
	ray.enabled = false
	ray.target_position = Vector3(0.0, 0.0, -pick_distance)
	GameState.phase_changed.connect(_on_phase_changed)
	# Deferred: the player captures the mouse in its own _ready(), and this has
	# to be the one that wins regardless of which node readies first.
	_apply_phase.call_deferred(GameState.phase)


func _physics_process(delta: float) -> void:
	# Runs regardless of which camera is current: a prop thrown just before
	# lock-in still has to finish settling and freeze itself.
	_update_settling(delta)
	if not current:
		return
	_aim_at_cursor()
	if _dragged != null:
		_update_drag(delta)


func _unhandled_input(event: InputEvent) -> void:
	if not current or not GameState.is_preparation():
		return
	if event.is_action_pressed("fire"):
		_try_grab()
	elif event.is_action_released("fire"):
		_drop()
	elif _dragged != null and event.is_action_pressed("slot_next"):
		_dragged.apply_torque_impulse(Vector3.DOWN * spin_impulse)
	elif _dragged != null and event.is_action_pressed("slot_prev"):
		_dragged.apply_torque_impulse(Vector3.UP * spin_impulse)


## Points the RayCast3D from the camera through the mouse cursor. project_ray_*
## does the screen-to-world maths for whatever FOV and viewport size are in
## effect, so the pick stays accurate if either changes.
func _aim_at_cursor() -> void:
	var mouse := get_viewport().get_mouse_position()
	var origin := project_ray_origin(mouse)
	var direction := project_ray_normal(mouse)
	ray.global_position = origin
	# target_position is local, and this node is pitched steeply, so the world
	# direction has to be converted rather than assigned straight in.
	ray.target_position = ray.to_local(origin + direction * pick_distance)
	ray.force_raycast_update()


func _try_grab() -> void:
	if _dragged != null or not ray.is_colliding():
		return
	var body := ray.get_collider() as RigidBody3D
	if body == null or not body.is_in_group(drag_group):
		return

	_dragged = body
	_base_lift = _lowest_point(body)
	# Anchor the spring where the player actually clicked. Grab a bowl by its
	# rim and it will swing from the rim.
	_grab_local = body.to_local(ray.get_collision_point())
	_target = body.global_position
	# A held body hangs on its spring; gravity would just add a permanent sag
	# the spring has to fight, and it comes back the instant it is let go.
	_rest_gravity_scale = body.gravity_scale
	body.gravity_scale = 0.0
	# Props sit frozen so 500 of them cost nothing; thaw this one for as long as
	# it is in hand, or the carry spring would have nothing to push on.
	_was_frozen = body.freeze
	body.freeze = false
	body.sleeping = false
	# It is being carried, not settling.
	_settling.erase(body.get_instance_id())
	# Switch this one prop into the avoidance simulation while it is in hand, so
	# the enemy dodges it live instead of waiting for the navmesh to re-bake.
	# Left off for the other 500, which would cost more than all other physics.
	_set_avoidance(body, true)
	# Excluding the body from the ray (rather than switching its collision off)
	# means it keeps colliding with everything else and the exclusion takes
	# effect immediately -- collision layer changes have to be deferred.
	ray.add_exception(body)


func _drop() -> void:
	if _dragged == null:
		return
	if is_instance_valid(_dragged):
		ray.remove_exception(_dragged)
		# Let go: gravity comes back and whatever momentum and spin the drag
		# built up carries into the fall, so a flung object really is flung.
		_dragged.gravity_scale = _rest_gravity_scale
		_set_avoidance(_dragged, false)
		if _was_frozen:
			# Do NOT freeze on the spot -- that would stop a thrown prop dead in
			# mid-air. It re-freezes once it has come to rest by itself.
			_settling[_dragged.get_instance_id()] = 0.0
	_dragged = null


## Drags the held body with a spring-damper instead of moving it.
##
## Nothing here writes position or rotation. A force is applied at the grabbed
## point, and because that point is offset from the centre of mass, the same
## force that pulls the body sideways also torques it -- so yanking the cursor
## left makes the object lean and swing on its own. A separate restoring torque
## rolls it back upright, which is what turns a one-off tilt into a pendulum.
func _update_drag(_delta: float) -> void:
	if not is_instance_valid(_dragged):
		_dragged = null
		return

	# Only re-aim while the cursor is over something; off the bench the object
	# keeps hanging at the last valid target rather than going limp.
	if ray.is_colliding():
		_target = ray.get_collision_point() + Vector3.UP * (_base_lift + hover_height)

	var mass := _dragged.mass
	var grab_point := _dragged.to_global(_grab_local)
	# The error steers the body's CENTRE, because _target is where the body
	# itself should hover. Measuring to the grab point instead would bury a
	# rim-grabbed object by however far the rim sits above its origin.
	# Clamped so grabbing something far away pulls hard but not explosively.
	var error := (_target - _dragged.global_position).limit_length(max_pull)
	var force := error * spring_stiffness - _dragged.linear_velocity * spring_damping
	# Applying at an offset is what produces the tilt; apply_central_force would
	# slide the object around perfectly flat and lose the whole effect.
	var arm := (grab_point - _dragged.global_position).limit_length(tilt_arm)
	_dragged.apply_force(force * mass, arm)

	if upright_torque > 0.0:
		_dragged.apply_torque(_upright_torque_for(_dragged) * mass)


## Toggles a prop's RVO avoidance, if it has an obstacle child at all.
func _set_avoidance(body: PhysicsBody3D, enabled: bool) -> void:
	for child in body.get_children():
		var obstacle := child as NavigationObstacle3D
		if obstacle != null:
			obstacle.avoidance_enabled = enabled


## Watches released props and freezes each one once it stops moving, handing the
## bench back to the cheap all-frozen state. Without this every prop the player
## ever touched would stay awake for the rest of the round.
func _update_settling(delta: float) -> void:
	if _settling.is_empty():
		return
	var finished: Array = []
	for id in _settling:
		var body := instance_from_id(id) as RigidBody3D
		if body == null or not is_instance_valid(body) or body == _dragged:
			finished.append(id)
			continue
		var speed := body.linear_velocity.length() + body.angular_velocity.length()
		if speed > refreeze_speed:
			_settling[id] = 0.0
			continue
		var still: float = float(_settling[id]) + delta
		_settling[id] = still
		if still >= refreeze_delay:
			body.freeze = true
			finished.append(id)
	for id in finished:
		_settling.erase(id)


## Torque that rolls a body back level, plus its damping.
##
## The axis is normalised and scaled by the lean ANGLE rather than left as the
## raw cross product: the cross product's length is sin(lean), which collapses
## to zero at 180 degrees, so a fully inverted object sits in a stable
## equilibrium and stays upside down forever. The angle form keeps pushing.
func _upright_torque_for(body: RigidBody3D) -> Vector3:
	var up := body.global_basis.y
	var axis := up.cross(Vector3.UP)
	if axis.length_squared() < 0.000001:
		# Exactly level (nothing to do) or exactly inverted (any horizontal axis
		# will start it falling back the right way).
		axis = Vector3.ZERO if up.dot(Vector3.UP) > 0.0 else body.global_basis.x
	else:
		axis = axis.normalized() * up.angle_to(Vector3.UP)
	return axis * upright_torque - body.angular_velocity * upright_damping


## How far the body's lowest collision point sits below its origin, so a
## placement can rest ON a surface instead of being buried in it. Measured from
## the collision shapes rather than the mesh -- the collider is what everything
## else in the scene will actually touch.
func _lowest_point(body: PhysicsBody3D) -> float:
	var lowest := 0.0
	for child in body.get_children():
		var shape := child as CollisionShape3D
		if shape == null or shape.shape == null:
			continue
		# get_debug_mesh() gives a usable AABB for every shape type, so this
		# works for the bowl's cylinder and for boxes, spheres and hulls alike.
		var bounds: AABB = shape.shape.get_debug_mesh().get_aabb()
		lowest = minf(lowest, shape.position.y + bounds.position.y)
	return -lowest


func _on_phase_changed(new_phase: int) -> void:
	_apply_phase(new_phase)


## PREPARATION owns this camera and a free cursor; ACTION hands both back to the
## first-person controller.
func _apply_phase(new_phase: int) -> void:
	if new_phase == GameState.Phase.PREPARATION:
		make_current()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		_drop()
		clear_current()
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
