@tool
extends RefCounted
## Tracks THIS editor's current scene + selected nodes and reports changes,
## so collaborators can see "who is looking at what". Polled at ~2 Hz, which
## covers both selection changes and switching between open scenes without
## depending on editor-version-specific signals.

signal changed(data: Dictionary)

var enabled := false
var _timer := 0.0
var _last := ""

func start() -> void:
	enabled = true
	_last = ""
	_timer = 0.0

func stop() -> void:
	enabled = false

func poll(delta: float) -> void:
	if not enabled:
		return
	_timer += delta
	if _timer < 0.5:
		return
	_timer = 0.0
	var data := _current()
	var key := JSON.stringify(data)
	if key != _last:
		_last = key
		changed.emit(data)

func _current() -> Dictionary:
	var scene := ""
	var selection: Array = []
	var root := EditorInterface.get_edited_scene_root()
	if root != null:
		scene = root.scene_file_path
		var es := EditorInterface.get_selection()
		if es != null:
			for n in es.get_selected_nodes():
				if is_instance_valid(n):
					selection.append(str(root.get_path_to(n)))
	return {"scene": scene, "selection": selection}
