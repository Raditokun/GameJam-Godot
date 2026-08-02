class_name Obstacle
extends RigidBody3D
## A piece of workbench clutter the player repositions to build their maze.
##
## Obstacles are frozen rigid bodies, not static bodies: frozen means enemies
## and bullets collide with a body that never gets shoved out of the maze the
## player carefully built, while still leaving a real RigidBody3D that
## BuildMode can pick up and fly around by writing its transform. FREEZE_MODE_
## KINEMATIC is what makes that transform-writing legal -- the physics server
## tracks the motion instead of ignoring it.
##
## Every obstacle joins the "obstacles" group so spawners and the enemy AI can
## find the current layout without any node paths.

## Colour the obstacle flashes when the crosshair is over it in PREPARATION.
@export var highlight_color := Color(1.0, 0.85, 0.35, 1.0)
## Emission energy used while held, so a carried piece reads clearly against
## the clutter behind it.
@export var held_energy := 0.6

## True while BuildMode is flying this obstacle around.
var held := false

var _mesh: MeshInstance3D
var _material: StandardMaterial3D
var _shape: CollisionShape3D
var _highlighted := false


func _ready() -> void:
	add_to_group("obstacles")
	# Frozen + kinematic: immovable by the simulation, movable by us.
	freeze = true
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC

	_mesh = _find_child_of_type(self, MeshInstance3D) as MeshInstance3D
	_shape = _find_child_of_type(self, CollisionShape3D) as CollisionShape3D
	if _mesh != null:
		# The scene shares one material across all the obstacles, so highlight
		# on a private copy or hovering one piece would light up every piece.
		var source := _mesh.get_surface_override_material(0)
		if source is StandardMaterial3D:
			_material = (source as StandardMaterial3D).duplicate()
		else:
			_material = StandardMaterial3D.new()
		_mesh.set_surface_override_material(0, _material)


## Half the obstacle's height, so a placement can sit its base on a surface.
## Read off the collision box rather than the mesh -- the collider is what the
## enemies and the player will actually walk into.
func base_offset() -> float:
	if _shape != null and _shape.shape is BoxShape3D:
		return (_shape.shape as BoxShape3D).size.y * 0.5 * scale.y
	return 0.5


## Widest horizontal half-extent, used to keep a placement clear of walls.
func radius() -> float:
	if _shape != null and _shape.shape is BoxShape3D:
		var size := (_shape.shape as BoxShape3D).size
		return maxf(size.x, size.z) * 0.5 * maxf(scale.x, scale.z)
	return 0.5


## Lights the piece up while the crosshair rests on it, so the player can tell
## what they are about to grab out of a cluttered bench.
func set_highlighted(on: bool) -> void:
	if _highlighted == on or _material == null:
		return
	_highlighted = on
	_material.emission_enabled = on
	if on:
		_material.emission = highlight_color
		_material.emission_energy_multiplier = held_energy


## Picked up: stop colliding so the piece can be flown through the clutter and
## so its own body can't block the placement ray.
func grab() -> void:
	held = true
	set_highlighted(true)
	# Deferred: collision state cannot be changed during physics resolution.
	set_deferred("collision_layer", 0)
	set_deferred("collision_mask", 0)


## Dropped into place -- collision comes back so it becomes maze geometry again.
func release(layer: int, mask: int) -> void:
	held = false
	set_highlighted(false)
	set_deferred("collision_layer", layer)
	set_deferred("collision_mask", mask)


func _find_child_of_type(node: Node, type: Variant) -> Node:
	for child in node.get_children():
		if is_instance_of(child, type):
			return child
		var found := _find_child_of_type(child, type)
		if found != null:
			return found
	return null
