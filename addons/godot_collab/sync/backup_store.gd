@tool
extends RefCounted
## Reads and restores the snapshots written to .collab_backup/.
##
## Backup files are named:  <flattened path>__v<version>__<timestamp>.bak
## e.g. scenes__level.tscn__v12__2026-08-01T13-40-02.bak
## Flattening is reversible because "__" only ever replaces a directory
## separator, so the original res:// path can be recovered exactly.

const BACKUP_DIR := "res://.collab_backup"

## Every backup on disk, newest first:
## [{file, path, version, stamp, size}]
static func list_all() -> Array:
	var out: Array = []
	var dir := DirAccess.open(BACKUP_DIR)
	if dir == null:
		return out
	for name in dir.get_files():
		if not name.ends_with(".bak"):
			continue
		var parsed := parse_name(name)
		if parsed.is_empty():
			continue
		parsed["file"] = name
		parsed["size"] = _size_of(BACKUP_DIR + "/" + name)
		out.append(parsed)
	# Timestamps are lexically sortable, so this is a true chronological sort.
	out.sort_custom(func(a, b): return str(a.stamp) > str(b.stamp))
	return out

## Distinct original paths that have at least one backup.
static func list_paths() -> Array:
	var seen := {}
	for b in list_all():
		seen[b.path] = true
	var paths := seen.keys()
	paths.sort()
	return paths

## Backups for one original path, newest first.
static func list_for(path: String) -> Array:
	var out: Array = []
	for b in list_all():
		if b.path == path:
			out.append(b)
	return out

## Decode "scenes__level.tscn__v12__STAMP.bak" -> {path, version, stamp}.
static func parse_name(name: String) -> Dictionary:
	if not name.ends_with(".bak"):
		return {}
	var body := name.substr(0, name.length() - 4)
	var marker := body.rfind("__v")
	if marker == -1:
		return {}
	var flat := body.substr(0, marker)
	var rest := body.substr(marker + 3)          # "12__STAMP"
	var split := rest.find("__")
	if split == -1:
		return {}
	var version := int(rest.substr(0, split))
	var stamp := rest.substr(split + 2)
	return {
		"path": "res://" + flat.replace("__", "/"),
		"version": version,
		"stamp": stamp,
	}

## Restore a backup over its original path. Returns "" on success.
## The current contents are themselves backed up first, so a restore is
## always undoable.
static func restore(backup_file: String) -> String:
	var meta := parse_name(backup_file)
	if meta.is_empty():
		return "Unrecognised backup name: %s" % backup_file
	var src := BACKUP_DIR + "/" + backup_file
	var f := FileAccess.open(src, FileAccess.READ)
	if f == null:
		return "Could not read %s" % backup_file
	var bytes := f.get_buffer(f.get_length())
	f.close()

	var dest: String = meta.path
	# Snapshot what is there now so restoring is itself reversible.
	if FileAccess.file_exists(dest):
		var cur := FileAccess.open(dest, FileAccess.READ)
		if cur:
			var before := cur.get_buffer(cur.get_length())
			cur.close()
			var stamp := Time.get_datetime_string_from_system().replace(":", "-")
			var flat := dest.replace("res://", "").replace("/", "__")
			var undo := FileAccess.open(
				"%s/%s__v0__%s.bak" % [BACKUP_DIR, flat, stamp], FileAccess.WRITE)
			if undo:
				undo.store_buffer(before)
				undo.close()

	var parent := dest.get_base_dir()
	var abs_parent := ProjectSettings.globalize_path(parent)
	if not DirAccess.dir_exists_absolute(abs_parent):
		DirAccess.make_dir_recursive_absolute(abs_parent)
	var out := FileAccess.open(dest, FileAccess.WRITE)
	if out == null:
		return "Could not write %s" % dest
	out.store_buffer(bytes)
	out.close()
	return ""

# -- removal ---------------------------------------------------------------
# Backups are the only safety net for an overwritten file, so every removal
# path here is explicit: nothing is ever pruned as a side effect of these.

## Delete one backup file. Returns true if it went.
static func delete_one(backup_file: String) -> bool:
	var abs := ProjectSettings.globalize_path(BACKUP_DIR + "/" + backup_file)
	if not FileAccess.file_exists(BACKUP_DIR + "/" + backup_file):
		return false
	return DirAccess.remove_absolute(abs) == OK

## Delete every backup belonging to one original path. Returns how many went.
static func clear_for(path: String) -> int:
	var removed := 0
	for b in list_for(path):
		if delete_one(str(b.file)):
			removed += 1
	return removed

## Delete every backup in the project. Returns how many went.
static func clear_all() -> int:
	var removed := 0
	for b in list_all():
		if delete_one(str(b.file)):
			removed += 1
	return removed

## Total bytes currently held in the backup folder.
static func total_size() -> int:
	var total := 0
	for b in list_all():
		total += int(b.size)
	return total

static func _size_of(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var n := f.get_length()
	f.close()
	return n
