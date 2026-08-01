@tool
extends RefCounted
## Tracks the single file this editor is currently focused on -- the open
## script if the Script editor is in front, otherwise the edited scene.
##
## This drives the "primary file" claim: you hold exactly one at a time, and it
## follows whatever you are actually working in.

signal focus_changed(path: String)

var enabled := false
var current := ""
var _timer := 0.0

func start() -> void:
	enabled = true
	current = ""
	_timer = 0.0

func stop() -> void:
	enabled = false
	current = ""

func poll(delta: float) -> void:
	if not enabled:
		return
	_timer += delta
	if _timer < 0.4:
		return
	_timer = 0.0
	var path := _detect()
	if path != current:
		current = path
		focus_changed.emit(path)

## Best-effort read of "what am I editing right now".
func _detect() -> String:
	if not Engine.is_editor_hint():
		return ""
	# A script open and focused takes priority over the scene behind it.
	var se := EditorInterface.get_script_editor()
	if se != null and se.is_visible_in_tree():
		var scr := se.get_current_script()
		if scr != null and scr.resource_path != "":
			return scr.resource_path
	var root := EditorInterface.get_edited_scene_root()
	if root != null and root.scene_file_path != "":
		return root.scene_file_path
	return ""

## Make the open script read-only (or writable again) when we do not own it.
##
## Every open script editor is unlocked first, then only the current one is
## locked if needed. Touching just the current editor used to leave previously
## locked scripts stuck read-only after switching away from them.
##
## Godot exposes no equivalent lock for the scene editor, so scenes rely on
## refusing to sync plus a clear warning instead.
static func set_script_readonly(readonly: bool) -> void:
	if not Engine.is_editor_hint():
		return
	var se := EditorInterface.get_script_editor()
	if se == null:
		return
	# Unlock everything we may have locked before.
	if se.has_method("get_open_script_editors"):
		for ed in se.get_open_script_editors():
			_set_editable(ed, true)
	else:
		_set_editable(se.get_current_editor(), true)
	if readonly:
		_set_editable(se.get_current_editor(), false)

static func _set_editable(ed, editable: bool) -> void:
	if ed == null or not ed.has_method("get_base_editor"):
		return
	var base = ed.get_base_editor()
	if base is TextEdit:
		base.editable = editable
