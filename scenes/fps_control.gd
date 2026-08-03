extends CheckButton

func _on_toggled(toggled_on: bool) -> void:
	FPSOverlay.visible = toggled_on
