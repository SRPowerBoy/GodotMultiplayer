@tool
extends RefCounted
## Editor-side refresh for non-scene resources and imported assets.
## Called after a remote file has been written to disk so the editor picks it
## up without a manual "Reimport".

static func notify_changed(path: String) -> void:
	if not Engine.is_editor_hint():
		return
	var efs := EditorInterface.get_resource_filesystem()
	if efs == null:
		return
	# Tell the filesystem this specific file changed.
	efs.update_file(path)

	var ext := path.get_extension().to_lower()
	var importable := ["png", "jpg", "jpeg", "webp", "svg", "bmp",
		"wav", "ogg", "mp3", "glb", "gltf", "obj", "fbx", "ttf", "otf"]
	if importable.has(ext):
		# Reimport the asset so the imported cache matches the new source.
		if efs.has_method("reimport_files"):
			efs.reimport_files(PackedStringArray([path]))

	# If it is a loaded resource (.tres/.res), drop it from the cache so the
	# next load returns fresh data.
	if (ext == "tres" or ext == "res") and ResourceLoader.has_cached(path):
		# Re-loading with IGNORE cache mode refreshes the in-memory copy.
		ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)

## Tell the editor a file was removed so it drops from the FileSystem dock.
static func notify_removed(path: String) -> void:
	if not Engine.is_editor_hint():
		return
	var efs := EditorInterface.get_resource_filesystem()
	if efs == null:
		return
	efs.update_file(path)   # update_file on a now-missing path removes it
	efs.scan()
