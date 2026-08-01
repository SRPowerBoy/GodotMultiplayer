extends SceneTree
## Headless test for file sync: transport round-trip, apply_remote write,
## backup creation, and local-change detection.

const FileSync := preload("res://addons/godot_collab/sync/file_sync.gd")

var results: Array = []
func ok(c: bool, l: String) -> void:
	results.append(c); print(("PASS " if c else "FAIL ") + l)

func _init() -> void:
	var dir := "res://_synctest"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var path := dir + "/foo.gd"

	# seed an initial file
	_write(path, "print('A')")

	var fs := FileSync.new()
	var changes: Array = []
	fs.local_change.connect(func(p, b): changes.append(p))
	fs.start()  # baseline (should NOT emit for existing file)
	ok(changes.is_empty(), "baseline emits nothing (got %d)" % changes.size())

	# --- base64 transport round-trip on binary-ish bytes ---
	var raw := PackedByteArray([0, 1, 2, 255, 128, 10, 13, 0, 200])
	var back := Marshalls.base64_to_raw(Marshalls.raw_to_base64(raw))
	ok(back == raw, "base64 round-trip preserves bytes")

	# --- apply_remote writes new content + makes a backup ---
	fs.apply_remote(path, "print('B')".to_utf8_buffer(), 1)
	ok(_read(path) == "print('B')", "apply_remote wrote new content (got '%s')" % _read(path))
	ok(_has_backup("foo.gd"), "backup created in .collab_backup")

	# apply_remote must NOT trigger a local-change echo
	_scan_now(fs)
	ok(changes.is_empty(), "remote write does not echo as local change (got %d)" % changes.size())

	# --- local edit is detected after mtime advances ---
	OS.delay_msec(1100)  # let the mtime second tick over
	_write(path, "print('C')")
	_scan_now(fs)
	ok(changes.size() == 1 and changes[0] == path, "local edit detected (got %s)" % str(changes))

	# --- an identical remote copy must not touch the file at all ---
	# Rewriting it would bump mtime and make Godot prompt "reload from disk?".
	var mtime_before := FileAccess.get_modified_time(path)
	OS.delay_msec(1100)
	fs.apply_remote(path, "print('C')".to_utf8_buffer(), 7)   # same as on disk
	ok(FileAccess.get_modified_time(path) == mtime_before,
		"identical remote copy leaves the file untouched (no reload prompt)")
	ok(_read(path) == "print('C')", "content still correct after skipped write")

	# --- remote delete removes the file + backs it up, no echo ---
	fs.apply_remote_delete(path)
	ok(not FileAccess.file_exists(path), "apply_remote_delete removed the file")
	_scan_now(fs)
	ok(changes.size() == 1, "remote delete does not echo (still %d change events)" % changes.size())

	# --- local delete is detected and emitted ---
	var deletes: Array = []
	fs.local_delete.connect(func(p): deletes.append(p))
	var path2 := dir + "/bar.gd"
	_write(path2, "print('bar')")
	_scan_now(fs)                 # register bar.gd as known
	OS.delay_msec(50)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path2))
	_scan_now(fs)                 # scan notices it vanished
	# A delete is held briefly in case a matching create arrives (a rename).
	# Wait out that window, then poll so it settles as a real delete.
	OS.delay_msec(FileSync.RENAME_PAIR_WINDOW + 200)
	fs.poll(0.1)
	ok(deletes.size() == 1 and deletes[0] == path2, "local delete detected (got %s)" % str(deletes))

	# cleanup
	_rm_dir(dir)
	_rm_dir("res://.collab_backup")

	var passed := 0
	for r in results:
		if r: passed += 1
	print("\n==== %d/%d passed ====" % [passed, results.size()])
	quit(0 if passed == results.size() else 1)

## Mirror the editor path: notify, then poll past the debounce window.
func _scan_now(fs) -> void:
	fs.request_scan()
	fs.poll(FileSync.SCAN_DEBOUNCE + 0.05)

func _write(path: String, s: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(s); f.close()

func _read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return "<none>"
	var s := f.get_as_text(); f.close(); return s

func _has_backup(stem: String) -> bool:
	var d := DirAccess.open("res://.collab_backup")
	if d == null: return false
	for name in d.get_files():
		if name.contains(stem):
			return true
	return false

func _rm_dir(path: String) -> void:
	var abs := ProjectSettings.globalize_path(path)
	var d := DirAccess.open(abs)
	if d == null: return
	for f in d.get_files():
		d.remove(f)
	for sub in d.get_directories():
		_rm_dir(path + "/" + sub)
	DirAccess.remove_absolute(abs)
