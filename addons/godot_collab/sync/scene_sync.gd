@tool
extends RefCounted
## Editor-side refresh for scenes.
##
## Whole-scene sync: when a remote peer saves a .tscn, the file is written to
## disk by file_sync and this helper reloads it in the editor if it happens to
## be the scene currently open, so the change is visible immediately.
##
## NOTE: Godot's editor exposes no stable API for injecting another user's
## *live* per-node edits into an open scene, so co-editing is at save
## granularity, not per-keystroke. See README for details.

## True when `path` is the scene the user is actively editing right now.
## Overwriting that file underneath them is what produces Godot's
## "this scene was modified externally" prompt, so callers use this to hold
## the write back instead.
static func is_active_scene(path: String) -> bool:
	if not Engine.is_editor_hint():
		return false
	var root := EditorInterface.get_edited_scene_root()
	return root != null and root.scene_file_path == path

static func reload_if_open(path: String) -> void:
	if not Engine.is_editor_hint():
		return
	if path.get_extension().to_lower() != "tscn" and path.get_extension().to_lower() != "scn":
		return
	var open_scenes := EditorInterface.get_open_scenes()
	if not open_scenes.has(path):
		return
	# Reload the scene from disk. Guarded because the exact method name has
	# varied across 4.x point releases.
	if EditorInterface.has_method("reload_scene_from_path"):
		EditorInterface.call("reload_scene_from_path", path)
	else:
		# Fallback: close+reopen via the filesystem tree.
		EditorInterface.open_scene_from_path(path)
