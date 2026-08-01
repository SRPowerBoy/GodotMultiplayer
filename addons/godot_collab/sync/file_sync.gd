@tool
extends RefCounted
## Watches the project for saved changes and applies remote changes to disk.
##
## Detection is by modification-time + content-hash polling (cheap, reliable,
## and it never fires per-keystroke -- only after a real save/import). Files
## written by an incoming remote update are marked as "known" so they are not
## echoed back onto the network.

signal local_change(path: String, bytes: PackedByteArray)
signal local_delete(path: String)
signal deferred_write(path: String)
signal deferred_applied(path: String)
signal file_too_large(path: String, size: int)
signal local_rename(from_path: String, to_path: String)

const ResourceSync := preload("res://addons/godot_collab/sync/resource_sync.gd")
const SceneSync := preload("res://addons/godot_collab/sync/scene_sync.gd")
const Protocol := preload("res://addons/godot_collab/network/protocol.gd")

const BACKUP_DIR := "res://.collab_backup"
## Scanning is normally driven by the editor's filesystem-changed signal (see
## request_scan). This slow tick is only a safety net for changes the editor
## does not report, so it can be cheap -- a full walk every second was the
## dominant cost on large projects.
const SCAN_INTERVAL := 5.0
## Small delay after a change notification so a burst of saves coalesces into
## one scan instead of one per file.
const SCAN_DEBOUNCE := 0.25
const MAX_SYNC_BYTES := 12 * 1024 * 1024  # skip huge files to protect the socket

# Extensions we care about. Everything is transported as raw bytes/base64.
const TRACKED_EXT := {
	"gd": true, "gdshader": true, "shader": true,
	"tscn": true, "scn": true, "tres": true, "res": true,
	# NOTE: .import files are deliberately NOT tracked. They are generated per
	# machine by the importer and carry local absolute paths and UIDs; syncing
	# them fights each editor's own reimport and causes churn.
	"cfg": true, "json": true, "md": true, "txt": true,
	"png": true, "jpg": true, "jpeg": true, "webp": true, "svg": true, "bmp": true,
	"wav": true, "ogg": true, "mp3": true,
	"glb": true, "gltf": true, "obj": true, "fbx": true,
	"ttf": true, "otf": true, "fnt": true,
}
const SKIP_DIRS := {".godot": true, ".collab_backup": true, ".git": true, ".import": true}

## Addon folders are excluded by default and syncing them is opt-in, because
## overwriting a plugin's scripts while Godot is running them forces a
## hot-reload mid-execution and can kill the session for whoever receives it.
## This addon's own folder is excluded unconditionally, whatever the setting.
static var sync_addons := false
const OWN_ADDON_PREFIX := "res://addons/godot_collab"
const SKIP_PREFIXES := [
	"res://addons",
]

## Individual files that must never be synchronised.
##
## project.godot carries the engine version, enabled plugins, autoloads and
## input maps -- all of which are per-machine. Overwriting it can leave a
## collaborator with a project that will not open, especially when the two
## editors are different Godot versions.
const SKIP_FILES := {
	"res://project.godot": true,
	"res://override.cfg": true,
}

## User-supplied ignore rules, read from res://.collabignore.
## One glob per line; "#" starts a comment. Matched against the project-relative
## path, so both "assets/raw/*" and "*.psd" work.
const IGNORE_FILE := "res://.collabignore"
static var _ignore_globs: Array = []

static func load_ignore_rules() -> Array:
	_ignore_globs = []
	var f := FileAccess.open(IGNORE_FILE, FileAccess.READ)
	if f == null:
		return _ignore_globs
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line == "" or line.begins_with("#"):
			continue
		_ignore_globs.append(line)
	f.close()
	return _ignore_globs

static func matches_ignore(path: String) -> bool:
	if _ignore_globs.is_empty():
		return false
	var rel := path.replace("res://", "")
	for glob in _ignore_globs:
		var g := str(glob)
		if rel.match(g) or rel.get_file().match(g):
			return true
		# A bare directory name ignores everything beneath it.
		if not g.contains("*") and rel.begins_with(g.rstrip("/") + "/"):
			return true
	return false

static func is_excluded(path: String) -> bool:
	# Anything that is not a plain project-relative path is refused outright.
	if not Protocol.is_safe_path(path):
		return true
	if SKIP_FILES.has(path):
		return true
	if path == IGNORE_FILE:
		return true
	# Our own plugin is never syncable, whatever the setting says.
	if path.begins_with(OWN_ADDON_PREFIX):
		return true
	if not sync_addons:
		for prefix in SKIP_PREFIXES:
			if path.begins_with(prefix):
				return true
	return matches_ignore(path)

var _known := {}          # res-path -> {mtime:int, hash:String}
var _muted := {}          # res-path -> true while we apply a remote write
var _seen := {}           # scratch set of paths encountered in the current scan
var _deferred := {}       # path -> {bytes, version} held back from an open scene
var _timer := 0.0
var _pending_scan := -1.0  # >=0 while a debounced scan is queued
var _oversize_warned := {}  # paths we have already reported as too big
var _enabled := false
var _baselining := false  # true during the initial scan: record, never emit

func start() -> void:
	_ensure_backup_dir()
	load_ignore_rules()
	_enabled = true
	_timer = 0.0
	# Baseline the current tree so we do not broadcast the whole project as
	# "changes" the instant a session starts.
	_baselining = true
	_scan()
	_baselining = false

func stop() -> void:
	_enabled = false
	_known.clear()
	# Held-back updates must not land after the session has ended.
	_deferred.clear()
	_new_this_scan.clear()
	_recent_deletes.clear()

## Ask for a scan soon. Called from the editor's filesystem-changed signal so
## saves are picked up immediately without polling the whole tree constantly.
func request_scan() -> void:
	if _enabled and _pending_scan < 0.0:
		_pending_scan = SCAN_DEBOUNCE

func poll(delta: float) -> void:
	if not _enabled:
		return
	flush_deferred()
	_settle_recent_deletes()

	# Debounced scan triggered by an editor notification.
	if _pending_scan >= 0.0:
		_pending_scan -= delta
		if _pending_scan <= 0.0:
			_pending_scan = -1.0
			_timer = 0.0
			_scan()
			return

	# Slow safety-net sweep for anything the editor did not report.
	_timer += delta
	if _timer < SCAN_INTERVAL:
		return
	_timer = 0.0
	_scan()

## Apply any updates that were held back while the user had that scene open.
## Safe to call often: it only acts once the scene is no longer the active one.
func flush_deferred() -> void:
	if _deferred.is_empty():
		return
	for path in _deferred.keys():
		if SceneSync.is_active_scene(path):
			continue
		var held: Dictionary = _deferred[path]
		_deferred.erase(path)
		apply_remote(path, held.bytes, int(held.version))
		deferred_applied.emit(path)

func has_deferred() -> bool:
	return not _deferred.is_empty()

func deferred_paths() -> Array:
	return _deferred.keys()

## Content hash of a file on disk, or "" when it does not exist. Used to tell
## a real overwrite from an identical copy.
func hash_of(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return _hash(read_bytes(path))

## Hash of every tracked file, for the join manifest.
func hash_manifest() -> Dictionary:
	var out := {}
	for path in _known:
		out[path] = _known[path].hash
	return out

## Read a single file's bytes (res path). Returns empty array if unreadable.
func read_bytes(path: String) -> PackedByteArray:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var data := f.get_buffer(f.get_length())
	f.close()
	return data

## Apply an authoritative copy from the network to disk, then refresh the
## editor. Suppresses the resulting local-change echo.
func apply_remote(path: String, bytes: PackedByteArray, version: int) -> void:
	# Defence in depth: never let a peer overwrite the running plugin.
	if is_excluded(path):
		push_warning("[Collab] Refused remote write to excluded path %s" % path)
		return
	# If our copy is already byte-identical, do nothing. Rewriting it would
	# bump the mtime, make the editor think the file changed underneath the
	# user, and trigger a needless "reload from disk?" prompt.
	var incoming_hash := _hash(bytes)
	if FileAccess.file_exists(path) and _hash(read_bytes(path)) == incoming_hash:
		_known[path] = {"mtime": FileAccess.get_modified_time(path), "hash": incoming_hash}
		_deferred.erase(path)
		return
	# Never overwrite the scene the user is standing in. Writing it would yank
	# the file out from under them and discard anything unsaved. Hold the update
	# and apply it once they move away.
	if SceneSync.is_active_scene(path):
		_deferred[path] = {"bytes": bytes, "version": version}
		deferred_write.emit(path)
		return
	_muted[path] = true
	_snapshot_existing(path, version)  # back up what is there before we clobber it
	_ensure_parent_dir(path)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[Collab] Could not write %s" % path)
		_muted.erase(path)
		return
	f.store_buffer(bytes)
	f.close()
	# Record new state so the next scan treats this as already-known.
	_known[path] = {"mtime": FileAccess.get_modified_time(path), "hash": _hash(bytes)}
	# Refresh editor: reimport assets, reload the scene if it is open.
	ResourceSync.notify_changed(path)
	SceneSync.reload_if_open(path)
	_muted.erase(path)

## Apply a remote deletion to disk (with a backup), suppressing the echo.
func apply_remote_delete(path: String) -> void:
	if is_excluded(path):
		push_warning("[Collab] Refused remote delete of excluded path %s" % path)
		return
	if not FileAccess.file_exists(path):
		_known.erase(path)
		return
	_muted[path] = true
	_snapshot_existing(path, get_version_hint(path))  # keep a restorable copy
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	# Remove the .import sidecar for assets so the editor forgets it too.
	var sidecar := path + ".import"
	if FileAccess.file_exists(sidecar):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(sidecar))
	_known.erase(path)
	ResourceSync.notify_removed(path)
	_muted.erase(path)

# Deletions are versioned loosely; this is only used to tag the backup name.
func get_version_hint(_path: String) -> int:
	return 0

## Full list of every tracked file, for the initial snapshot to a joining peer.
## Paths only -- the caller reads bytes lazily as it paces the transfer, so a
## large project is never loaded into memory all at once.
func collect_all() -> Array:
	var out: Array = []
	for path in _known.keys():
		if FileAccess.file_exists(path):
			out.append(path)
	out.sort()
	return out

# -- internals -------------------------------------------------------------

func _scan() -> void:
	_seen.clear()
	_walk("res://")
	# Anything we knew about but did not encounter this pass has been deleted.
	if not _baselining:
		for path in _known.keys():
			if not _seen.has(path) and not _muted.has(path):
				_pending_deletes.append(path)
		# A file that vanished while an identical one appeared in the same scan
		# is a rename, not a delete + create. Reporting it as such avoids a
		# scary delete prompt and keeps the far side's history sane.
		for path in _pending_deletes:
			var gone_hash: String = _known[path].hash
			var moved_to := _find_moved(gone_hash)
			_known.erase(path)
			if moved_to != "":
				_new_this_scan.erase(moved_to)
				local_rename.emit(path, moved_to)
			else:
				# Hold it briefly: the matching create may land in a later scan.
				_recent_deletes.append({
					"path": path, "hash": gone_hash,
					"expires": Time.get_ticks_msec() + RENAME_PAIR_WINDOW,
				})
		_pending_deletes.clear()
		_settle_recent_deletes()
	_new_this_scan.clear()

var _pending_deletes: Array = []
var _new_this_scan: Array = []
## Deletes waiting to see if a matching create shows up (a rename split across
## two scans). Anything still here when the window closes was a real delete.
const RENAME_PAIR_WINDOW := 2000
var _recent_deletes: Array = []

func _find_moved(gone_hash: String) -> String:
	for candidate in _new_this_scan:
		if _known.has(candidate) and _known[candidate].hash == gone_hash:
			return candidate
	return ""

func _settle_recent_deletes() -> void:
	var now := Time.get_ticks_msec()
	var still: Array = []
	for entry in _recent_deletes:
		var moved := _find_moved(str(entry.hash))
		if moved != "":
			_new_this_scan.erase(moved)
			local_rename.emit(str(entry.path), moved)
		elif now < int(entry.expires):
			still.append(entry)     # keep waiting
		else:
			local_delete.emit(str(entry.path))
	_recent_deletes = still

func _walk(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		# Skip hidden entries and our own control directories.
		if name.begins_with(".") or SKIP_DIRS.has(name):
			name = dir.get_next()
			continue
		var full := dir_path.path_join(name)
		if dir.current_is_dir():
			_walk(full)
		else:
			_consider(full)
		name = dir.get_next()
	dir.list_dir_end()

func _consider(path: String) -> void:
	var ext := path.get_extension().to_lower()
	if not TRACKED_EXT.has(ext):
		return
	if is_excluded(path):
		return
	_seen[path] = true
	if _muted.has(path):
		return
	var mtime := FileAccess.get_modified_time(path)
	var prev = _known.get(path)
	# Fast path: mtime unchanged -> assume unchanged.
	if prev != null and prev.mtime == mtime:
		return
	var bytes := read_bytes(path)
	if bytes.size() > MAX_SYNC_BYTES:
		# Tell the user once per file, rather than silently never syncing it.
		if not _oversize_warned.has(path):
			_oversize_warned[path] = true
			file_too_large.emit(path, bytes.size())
		return
	var h := _hash(bytes)
	if prev != null and prev.hash == h:
		_known[path].mtime = mtime  # touch only; content identical
		return
	var is_new := prev == null
	_known[path] = {"mtime": mtime, "hash": h}
	# During baseline we only record state; real edits emit afterwards.
	if not _baselining:
		if is_new:
			_new_this_scan.append(path)
		local_change.emit(path, bytes)

# -- backups ---------------------------------------------------------------

## Public: snapshot the current on-disk content of `path` into the backup dir.
func backup(path: String, version: int) -> void:
	_snapshot_existing(path, version)

func _snapshot_existing(path: String, version: int) -> void:
	if not FileAccess.file_exists(path):
		return
	var bytes := read_bytes(path)
	if bytes.is_empty():
		return
	_ensure_backup_dir()
	var flat := path.replace("res://", "").replace("/", "__")
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var dest := "%s/%s__v%d__%s.bak" % [BACKUP_DIR, flat, version, stamp]
	var f := FileAccess.open(dest, FileAccess.WRITE)
	if f:
		f.store_buffer(bytes)
		f.close()
	_prune_backups(flat)

## Keep only the most recent backups per file. Without this the backup folder
## grows without bound for the whole session and eventually fills the disk.
const MAX_BACKUPS_PER_FILE := 10

func _prune_backups(flat_name: String) -> void:
	var dir := DirAccess.open(BACKUP_DIR)
	if dir == null:
		return
	var mine: Array = []
	for name in dir.get_files():
		if name.begins_with(flat_name + "__v"):
			mine.append(name)
	if mine.size() <= MAX_BACKUPS_PER_FILE:
		return
	# Names embed a sortable timestamp, so lexical order is chronological.
	mine.sort()
	var excess := mine.size() - MAX_BACKUPS_PER_FILE
	for i in excess:
		DirAccess.remove_absolute(
			ProjectSettings.globalize_path(BACKUP_DIR + "/" + str(mine[i])))

func _ensure_backup_dir() -> void:
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(BACKUP_DIR)):
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(BACKUP_DIR))

func _ensure_parent_dir(path: String) -> void:
	var parent := path.get_base_dir()
	var abs := ProjectSettings.globalize_path(parent)
	if not DirAccess.dir_exists_absolute(abs):
		DirAccess.make_dir_recursive_absolute(abs)

func _hash(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(bytes)
	return ctx.finish().hex_encode()
