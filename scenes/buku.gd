extends Node3D
## The cursed book. Walk into its zone, press E, and the prologue turns.
##
## Deliberately knows nothing about the player or the curse: it reports that it
## was inspected and says whether someone is standing close enough to read it.
## Whatever listens to `book_inspected` owns what happens next, and the prompt
## label lives in `Main.tscn` rather than here -- see `Player._update_book_prompt`.
##
## Input is read in **`_input`, not `_unhandled_input`**, and the press is
## consumed. `Player._unhandled_input()` binds the same `interact` action to prop
## pickup, so without consuming it first one press would both open the book and
## grab whatever is under the crosshair. Handling it here makes the outcome
## deterministic instead of dependent on tree order -- the same reason `Coin.gd`
## does it this way.

## Emitted once, when the player inspects the book.
signal book_inspected

## Group identifying the player, so this needs no node path out of itself.
@export var player_group := "player"

@onready var area: Area3D = get_node_or_null("InteractArea") as Area3D

## The player, while they are standing in the zone. Null means out of range.
var _player: Node3D = null
## Latches after the first inspection so a second press cannot re-fire it.
var _used := false


func _ready() -> void:
	if area == null:
		push_warning("[Buku] no InteractArea -- the book cannot be inspected")
		return
	area.body_entered.connect(_on_body_entered)
	area.body_exited.connect(_on_body_exited)


func _input(event: InputEvent) -> void:
	if _used or _player == null or not event.is_action_pressed("interact"):
		return
	_used = true
	get_viewport().set_input_as_handled()
	book_inspected.emit()


func _on_body_entered(body: Node3D) -> void:
	if _used or not body.is_in_group(player_group):
		return
	_player = body


func _on_body_exited(body: Node3D) -> void:
	if body != _player:
		return
	_player = null


## Whether someone is close enough to read the book and has not already done so.
## This is what drives the floating prompt in Main.tscn.
func is_player_near() -> bool:
	return _player != null and not _used


## Whether the book has already been read. Public so a saved game or a retry can
## ask without poking at the private latch.
func is_used() -> bool:
	return _used
