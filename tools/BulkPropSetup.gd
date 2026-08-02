@tool
extends EditorScript
## Editor entry point for the bulk prop conversion. Run this one.
##
## HOW TO RUN
##   1. Open Main.tscn and save it, so there is a copy to fall back on.
##   2. Open this file in the script editor.
##   3. File -> Run  (Ctrl+Shift+X).
##   4. Read the output panel, then save the scene to keep the changes.
##
## Running it twice is safe: anything already converted is skipped. All the
## actual work lives in PropConverter.gd -- see that file for what each prop
## turns into and why.

const PropConverter := preload("res://tools/PropConverter.gd")


func _run() -> void:
	var root := get_scene()
	if root == null:
		push_error("BulkPropSetup: no scene is open in the editor.")
		return

	var report = PropConverter.new().convert_scene(root)
	print_rich(
		"[b]BulkPropSetup[/b]: converted %d prop(s), skipped %d node(s)."
		% [report.converted.size(), report.skipped.size()]
	)
	for line in report.log:
		print("  ", line)
	if report.converted.is_empty():
		print_rich("[color=orange]Nothing to convert -- are the props direct children of the scene root?[/color]")
	else:
		print_rich("[color=yellow]Save the scene (Ctrl+S) to keep these changes.[/color]")
