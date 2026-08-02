class_name Prop
extends RigidBody3D
## A movable physics prop: shove-able by walking into it, hittable by the
## weapons, and pickup-able by the player's carry beam.
##
## The player drives carrying by setting `carried_by` -- the prop then turns off
## its own gravity and lets Player._update_carry() steer it by velocity, which
## keeps it colliding with the world instead of tunnelling through it the way a
## reparented/teleported body would.
##
## Anything that should behave like the table just needs this script on a
## RigidBody3D with collision shapes; Player and the weapons find props by type,
## not by node path.

## Emitted whenever a weapon connects, for hit sounds / effects later.
signal hit(point: Vector3, force: float)

@export_group("Carry")
## False makes the prop shove-able and shootable but refuses pickup -- for
## things too big or too set-dressing to walk off with.
@export var carryable := true
## Spin left over after one second of being carried, 0..1. Well under 1 so a
## prop grabbed by a corner settles to a steady pose instead of pinwheeling.
@export_range(0.0, 1.0, 0.01) var carry_spin_damping := 0.05

@export_group("Hits")
## Multiplies the impulse weapons ask for. Turn down for heavy props that
## shouldn't skate across the room when shot.
@export var hit_force_scale := 1.0
## Longest lever arm, in metres, a hit is allowed to act on. Without this a
## solid whack on the far corner of a 3 m table applies metres of leverage and
## sets it spinning fast enough to tunnel through the floor; clamping the arm
## keeps the tumble to something the solver can handle while still letting
## corner hits spin the prop more than centre hits.
@export var hit_torque_arm := 0.4

## The player currently holding this prop, or null. Set by Player.
var carried_by: Node3D = null:
	set(value):
		carried_by = value
		# Carried props are steered by velocity every physics frame, so engine
		# gravity would just fight that steering; it comes back on release.
		gravity_scale = 0.0 if value != null else _rest_gravity_scale
		# A held prop must never doze off: standing still leaves its velocity
		# near zero, and a sleeping body ignores the velocities the carry spring
		# writes -- it would hang in mid-air, weightless and unresponsive.
		can_sleep = _rest_can_sleep if value == null else false
		wake()

var _rest_gravity_scale := 1.0
var _rest_can_sleep := true


func _ready() -> void:
	_rest_gravity_scale = gravity_scale
	_rest_can_sleep = can_sleep


## Knocks the prop with `force` (newton-seconds) along `direction`, applied at
## `point` so off-centre hits spin it. Weapons call this through has_method(),
## so props stay optional -- shooting the level geometry is still a no-op.
func apply_hit(point: Vector3, direction: Vector3, force: float) -> void:
	if direction.length_squared() < 0.001:
		return
	wake()
	var impulse := direction.normalized() * force * hit_force_scale
	apply_impulse(impulse, (point - global_position).limit_length(hit_torque_arm))
	hit.emit(point, force)


## Brings the prop out of its resting state. apply_impulse() already wakes a
## sleeping body on its own, so this is only needed where the prop is driven by
## writing velocity directly (the carry spring), which a sleeping body ignores.
func wake() -> void:
	if sleeping:
		sleeping = false


## Melee/bullet damage hook. There is no health system yet -- props absorb the
## damage and only the physics knock (apply_hit) shows -- but the method has to
## exist for Sword.gd's has_method("take_damage") probe to route hits here.
func take_damage(_amount: float) -> void:
	pass
