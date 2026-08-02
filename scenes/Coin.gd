extends Area3D
## A collectible coin. Walking over it does nothing -- the player has to stand in range
## and press the interact key, so collecting is a deliberate act that costs time while
## the enemy waves close in.
##
## The node is an Area3D on layer 0 / mask 1: it senses the player and can never push
## them around. Collision layers matter here, an Area3D that shares the world layer would
## still show up in the player's own pickup queries.

## Emitted once, when the player collects this coin. The coin frees itself straight after.
signal collected(coin: Node3D)

@export_group("Interaction")
## Group identifying the player.
@export var player_group := "player"
## Only collectable during ACTION. A coin picked up while building would be free money.
@export var action_phase_only := true

@export_group("Presentation")
## Degrees per second the coin spins, so it catches the eye across the bench.
@export var spin_speed_deg := 90.0
## How far the coin rises and falls, in metres.
@export var bob_height := 0.12
## Bob cycles per second.
@export var bob_speed := 1.5

# Child lookups use $ rather than exported node references: both live inside this scene,
# and a typed node export silently resolves to null unless the .tscn also carries a
# node_paths=PackedStringArray(...) marker.
@onready var model: Node3D = $Model
@onready var prompt: Label3D = $Prompt
@onready var glow: OmniLight3D = $Glow

var _in_range := false
var _collected := false
var _time := 0.0
var _model_rest_y := 0.0


func _ready() -> void:
	# Sense the player, collide with nothing.
	collision_layer = 0
	collision_mask = 1
	monitoring = true

	_model_rest_y = model.position.y
	prompt.visible = false

	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _process(delta: float) -> void:
	_time += delta
	model.rotate_y(deg_to_rad(spin_speed_deg) * delta)
	model.position.y = _model_rest_y + sin(_time * bob_speed * TAU) * bob_height


## Handled in _input rather than _unhandled_input so the coin always sees the interact
## key before Player._unhandled_input does. Without that, one press would both collect
## the coin and trigger the player's prop grab; consuming the event here makes the
## outcome deterministic instead of dependent on tree order.
func _input(event: InputEvent) -> void:
	if _collected or not _in_range:
		return
	if not event.is_action_pressed("interact"):
		return
	if action_phase_only and not GameState.is_action():
		return
	get_viewport().set_input_as_handled()
	_collect()


func _collect() -> void:
	if _collected:
		return
	_collected = true
	prompt.visible = false
	collected.emit(self)
	queue_free()


func _on_body_entered(body: Node3D) -> void:
	if _collected or not body.is_in_group(player_group):
		return
	_in_range = true
	prompt.visible = true


func _on_body_exited(body: Node3D) -> void:
	if not body.is_in_group(player_group):
		return
	_in_range = false
	prompt.visible = false


## True while the player is close enough to press the key.
func is_in_range() -> bool:
	return _in_range
