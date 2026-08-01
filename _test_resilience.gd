extends SceneTree
## Covers the pieces that only matter when something goes wrong:
## reconnect backoff, oversized-message rejection, engine-version handshake,
## backup pruning, and deferred writes.

const ReconnectPolicy := preload("res://addons/godot_collab/network/reconnect_policy.gd")
const Protocol := preload("res://addons/godot_collab/network/protocol.gd")
const FileSync := preload("res://addons/godot_collab/sync/file_sync.gd")
const HostServer := preload("res://addons/godot_collab/network/host_server.gd")
const BackupStore := preload("res://addons/godot_collab/sync/backup_store.gd")

var results: Array = []
func ok(c: bool, l: String) -> void:
	results.append(c); print(("PASS " if c else "FAIL ") + l)

func _init() -> void:
	# ---------- reconnect policy ----------
	var rp := ReconnectPolicy.new()
	ok(rp.attempt == 0, "policy starts idle")
	ok(rp.on_disconnected(), "first drop schedules a retry")
	ok(rp.attempt == 1, "attempt counted")
	ok(is_equal_approx(rp.delay_left, 1.5), "first delay is the base (got %.2f)" % rp.delay_left)

	# Backoff grows, then caps.
	ok(is_equal_approx(ReconnectPolicy.next_delay(1), 1.5), "delay #1 = 1.5")
	ok(is_equal_approx(ReconnectPolicy.next_delay(2), 3.0), "delay #2 = 3.0")
	ok(is_equal_approx(ReconnectPolicy.next_delay(3), 6.0), "delay #3 = 6.0")
	ok(ReconnectPolicy.next_delay(20) == ReconnectPolicy.MAX_DELAY,
		"delay caps at %.0fs" % ReconnectPolicy.MAX_DELAY)

	# The timer only fires once, at zero.
	var rp2 := ReconnectPolicy.new()
	rp2.on_disconnected()
	ok(not rp2.tick(0.5), "does not fire early")
	ok(not rp2.tick(0.5), "still not firing")
	ok(rp2.tick(1.0), "fires when the delay elapses")
	ok(not rp2.tick(1.0), "does not fire again afterwards")

	# Give up after MAX_ATTEMPTS.
	var rp3 := ReconnectPolicy.new()
	var scheduled := 0
	for i in 20:
		if rp3.on_disconnected():
			scheduled += 1
	ok(scheduled == ReconnectPolicy.MAX_ATTEMPTS,
		"retries stop after %d attempts (got %d)" % [ReconnectPolicy.MAX_ATTEMPTS, scheduled])
	ok(rp3.exhausted(), "policy reports exhaustion")

	# A deliberate exit must never reconnect.
	var rp4 := ReconnectPolicy.new()
	rp4.deliberate = true
	ok(not rp4.on_disconnected(), "leaving on purpose does not reconnect")

	# Reconnecting successfully resets everything.
	var rp5 := ReconnectPolicy.new()
	rp5.on_disconnected()
	ok(rp5.on_connected(), "on_connected reports we had been retrying")
	ok(rp5.attempt == 0 and rp5.delay_left == 0.0, "counters reset after success")
	ok(not rp5.on_connected(), "a clean connect is not reported as a reconnect")

	# ---------- message size cap ----------
	ok(Protocol.MAX_MESSAGE_BYTES > 0, "a message size cap is defined")
	ok(Protocol.MAX_MESSAGE_BYTES < 64 * 1024 * 1024, "the cap is actually restrictive")

	# ---------- engine version handshake ----------
	var v := Protocol.engine_version()
	ok(v.begins_with("4."), "engine version reported (got '%s')" % v)
	ok(Protocol.versions_compatible("4.4", "4.4"), "same versions are compatible")
	ok(not Protocol.versions_compatible("4.4", "4.7"),
		"4.4 and 4.7 are flagged incompatible (scene format differs)")

	# ---------- project config is never synced ----------
	ok(FileSync.is_excluded("res://project.godot"),
		"project.godot is excluded (engine version / autoloads are per-machine)")
	ok(FileSync.is_excluded("res://override.cfg"), "override.cfg is excluded")
	ok(not FileSync.is_excluded("res://scenes/main.tscn"), "normal content still syncs")

	# ---------- path validation (untrusted input) ----------
	ok(Protocol.is_safe_path("res://scenes/level.tscn"), "normal res:// path accepted")
	ok(not Protocol.is_safe_path("res://../../secrets.txt"), "parent traversal refused")
	ok(not Protocol.is_safe_path("res://a/../../b.gd"), "embedded traversal refused")
	ok(not Protocol.is_safe_path("/etc/passwd"), "absolute unix path refused")
	ok(not Protocol.is_safe_path("C:/Windows/system32/x.dll"), "windows path refused")
	ok(not Protocol.is_safe_path("res://C:/x.gd"), "drive letter inside res refused")
	ok(not Protocol.is_safe_path("res://a\\..\\b.gd"), "backslash traversal refused")
	ok(not Protocol.is_safe_path("user://save.dat"), "non-res scheme refused")
	ok(not Protocol.is_safe_path("res://"), "empty res path refused")
	# The sync layer must refuse them too, not just the validator.
	ok(FileSync.is_excluded("res://../evil.gd"), "file sync refuses traversal paths")

	# ---------- rate limiting ----------
	ok(Protocol.RATE_LIMIT_MESSAGES > 0 and Protocol.RATE_LIMIT_WINDOW > 0,
		"a rate limit is configured")
	var rl_host := HostServer.new()
	var rec := {"user": {"id": 1, "name": "Flooder"}, "ws": null}
	var t0 := 10000
	var allowed := 0
	for i in Protocol.RATE_LIMIT_MESSAGES + 50:
		if rl_host._allow_rate(rec, t0):
			allowed += 1
	ok(allowed == Protocol.RATE_LIMIT_MESSAGES,
		"flood clamped to %d msgs/window (got %d)" % [Protocol.RATE_LIMIT_MESSAGES, allowed])
	# A new window lets traffic through again.
	ok(rl_host._allow_rate(rec, t0 + Protocol.RATE_LIMIT_WINDOW + 1),
		"limit resets on the next window")

	# ---------- scan scheduling ----------
	ok(FileSync.SCAN_INTERVAL >= 5.0,
		"fallback sweep is slow (%.0fs) now that scans are signal-driven"
			% FileSync.SCAN_INTERVAL)

	# ---------- protocol fuzzing: malformed input must never crash ----------
	var junk := [
		"", "   ", "null", "true", "42", "\"a string\"", "[]", "[1,2,3]",
		"{", "}", "{]", "{\"type\":}", "{\"type\":\"chat\"",
		"{\"type\":null}", "{\"type\":123}", "{\"type\":{\"nested\":1}}",
		"\u0000\u0001binary", "{\"data\":\"!!!not base64!!!\"}",
		"{\"type\":\"file_update\",\"path\":null,\"data\":null}",
		"<html></html>", "%s" % String.chr(0xFFFD),
	]
	var survived := 0
	for j in junk:
		var parsed = Protocol.parse(str(j))
		# Anything that is not a JSON object must come back as null, never crash.
		if parsed == null or typeof(parsed) == TYPE_DICTIONARY:
			survived += 1
	ok(survived == junk.size(),
		"all %d malformed messages handled safely (got %d)" % [junk.size(), survived])
	ok(Protocol.parse("[1,2,3]") == null, "a JSON array is not accepted as a message")
	ok(Protocol.parse("{\"type\":\"chat\"}") != null, "a valid object still parses")

	# Payload decoding must survive garbage rather than returning junk bytes.
	ok(Protocol.decode_payload({"data": "!!!!", "enc": "raw"}) is PackedByteArray,
		"bad base64 decodes to a PackedByteArray, not a crash")
	ok(Protocol.decode_payload({"data": "abcd", "enc": "gzip"}).is_empty(),
		"undecompressable gzip payload yields empty, not corruption")
	ok(Protocol.decode_payload({"data": "abcd", "enc": "gzip", "raw_size": -5}).is_empty(),
		"negative raw_size refused")
	ok(Protocol.decode_payload({}).is_empty(), "missing payload fields handled")

	# ---------- .collabignore ----------
	var ig := FileAccess.open(FileSync.IGNORE_FILE, FileAccess.WRITE)
	ig.store_string("# comment\n*.psd\nassets/raw\nsecret.txt\n")
	ig.close()
	FileSync.load_ignore_rules()
	ok(FileSync.matches_ignore("res://art/logo.psd"), "*.psd glob ignored")
	ok(FileSync.matches_ignore("res://assets/raw/big.blend"), "directory rule ignored")
	ok(FileSync.matches_ignore("res://secret.txt"), "exact name ignored")
	ok(not FileSync.matches_ignore("res://art/logo.png"), "unlisted files still sync")
	ok(FileSync.is_excluded("res://art/logo.psd"), "ignore rules feed into is_excluded")
	ok(FileSync.is_excluded(FileSync.IGNORE_FILE), "the ignore file itself is not synced")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(FileSync.IGNORE_FILE))
	FileSync.load_ignore_rules()
	ok(not FileSync.matches_ignore("res://art/logo.psd"), "rules clear when the file is gone")

	# ---------- .import files are never synced ----------
	ok(not FileSync.TRACKED_EXT.has("import"),
		".import files are not tracked (they are per-machine)")

	# ---------- session code rotation ----------
	var ch := HostServer.new()
	ok(ch.start(8981, "H", "OLD-1111") == "", "host started for code rotation")
	ch.set_code("NEW-2222")
	ok(ch._code == "NEW-2222", "code rotated")
	ch.stop()

	# ---------- same-folder detection (two editors, one project) ----------
	var fp := Protocol.project_fingerprint()
	ok(fp != "", "project fingerprint is produced (%s)" % fp)
	ok(fp == Protocol.project_fingerprint(), "fingerprint is stable")
	ok(fp == fp.to_lower(), "fingerprint is case-normalised for Windows")

	# ---------- deferred writes do not outlive the session ----------
	var ddir := "res://_defertest"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ddir))
	var dpath := ddir + "/scene_stub.tscn"
	var dfs := FileSync.new()
	_write(dpath, "stub")
	dfs.start()
	dfs.stop()
	ok(not dfs.has_deferred(), "stopping the sync clears any held-back writes")
	_rm_dir(ddir)

	# ---------- content hashing for the join review ----------
	var hdir := "res://_hashtest"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(hdir))
	var hpath := hdir + "/same.gd"
	_write(hpath, "identical")
	var hfs := FileSync.new()
	hfs.start()
	var h1 := hfs.hash_of(hpath)
	ok(h1 != "", "hash_of returns a hash for an existing file")
	ok(hfs.hash_of("res://does_not_exist.gd") == "", "missing file hashes to empty")
	_write(hpath, "different")
	ok(hfs.hash_of(hpath) != h1, "hash changes when content changes")
	var manifest := hfs.hash_manifest()
	ok(manifest.has(hpath), "hash manifest lists tracked files")
	_rm_dir(hdir)

	# ---------- manifest wait has a deadline ----------
	ok(HostServer.MANIFEST_TIMEOUT > 0, "a manifest reply timeout is configured")

	# ---------- backup naming round-trips ----------
	var meta := BackupStore.parse_name("scenes__level.tscn__v12__2026-08-01T13-40-02.bak")
	ok(str(meta.get("path", "")) == "res://scenes/level.tscn",
		"backup name decodes to the original path (got '%s')" % meta.get("path", ""))
	ok(int(meta.get("version", -1)) == 12, "version decoded (got %s)" % meta.get("version"))
	ok(str(meta.get("stamp", "")) == "2026-08-01T13-40-02", "timestamp decoded")
	ok(BackupStore.parse_name("garbage.txt").is_empty(), "non-backup names rejected")

	# ---------- backup restore ----------
	var rdir := "res://_restoretest"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(rdir))
	var rpath := rdir + "/hero.gd"
	var rfs := FileSync.new()
	_write(rpath, "ORIGINAL")
	rfs.start()
	rfs.apply_remote(rpath, "REPLACED".to_utf8_buffer(), 3)   # backs up ORIGINAL
	ok(_read(rpath) == "REPLACED", "file was replaced")

	var backups := BackupStore.list_for(rpath)
	ok(backups.size() >= 1, "a backup exists for the replaced file (%d)" % backups.size())
	if backups.size() >= 1:
		var rerr := BackupStore.restore(str(backups[0].file))
		ok(rerr == "", "restore reported success (err='%s')" % rerr)
		ok(_read(rpath) == "ORIGINAL", "original content restored (got '%s')" % _read(rpath))
		# Restoring must itself be reversible.
		ok(BackupStore.list_for(rpath).size() > backups.size(),
			"restoring saved the replaced contents too (undoable)")
	ok(BackupStore.restore("not_a_backup.bak") != "", "restoring garbage fails cleanly")

	_rm_dir(rdir)
	_rm_dir("res://.collab_backup")

	# ---------- clearing backups ----------
	var cdir := "res://_cleartest"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(cdir))
	var ca := cdir + "/a.gd"
	var cb := cdir + "/b.gd"
	var cfs := FileSync.new()
	_write(ca, "a0"); _write(cb, "b0")
	cfs.start()
	for i in range(1, 4):
		cfs.apply_remote(ca, ("a%d" % i).to_utf8_buffer(), i)
		cfs.apply_remote(cb, ("b%d" % i).to_utf8_buffer(), i)
	ok(BackupStore.list_for(ca).size() > 0, "backups exist for a.gd")
	ok(BackupStore.list_for(cb).size() > 0, "backups exist for b.gd")
	ok(BackupStore.total_size() > 0, "total_size reports bytes held")

	# Clearing one file must leave the other alone.
	var removed_a := BackupStore.clear_for(ca)
	ok(removed_a > 0, "clear_for removed a.gd backups (%d)" % removed_a)
	ok(BackupStore.list_for(ca).is_empty(), "a.gd backups are gone")
	ok(not BackupStore.list_for(cb).is_empty(), "b.gd backups are untouched")

	# Clearing everything empties the folder.
	var removed_all := BackupStore.clear_all()
	ok(removed_all > 0, "clear_all removed the rest (%d)" % removed_all)
	ok(BackupStore.list_all().is_empty(), "no backups remain")
	ok(BackupStore.total_size() == 0, "total_size is zero when empty")
	ok(BackupStore.clear_all() == 0, "clearing an empty folder is a no-op")
	ok(not BackupStore.delete_one("nope.bak"), "deleting a missing backup fails safely")

	_rm_dir(cdir)
	_rm_dir("res://.collab_backup")

	# ---------- backup pruning ----------
	var dir := "res://_pruneteset"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var path := dir + "/thing.gd"
	var fs := FileSync.new()
	_write(path, "v0")
	fs.start()
	# Write many revisions; each apply_remote backs up the previous contents.
	for i in range(1, 20):
		fs.apply_remote(path, ("v%d" % i).to_utf8_buffer(), i)
	var flat := path.replace("res://", "").replace("/", "__")
	var count := 0
	var d := DirAccess.open(FileSync.BACKUP_DIR)
	if d:
		for name in d.get_files():
			if name.begins_with(flat + "__v"):
				count += 1
	ok(count <= FileSync.MAX_BACKUPS_PER_FILE,
		"backups pruned to <= %d per file (got %d)" % [FileSync.MAX_BACKUPS_PER_FILE, count])
	ok(count > 0, "some backups are still kept (got %d)" % count)

	_rm_dir(dir)
	_rm_dir("res://.collab_backup")

	var passed := 0
	for r in results:
		if r: passed += 1
	print("\n==== %d/%d passed ====" % [passed, results.size()])
	quit(0 if passed == results.size() else 1)

func _read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return "<none>"
	var t := f.get_as_text(); f.close(); return t

func _write(path: String, s: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(s); f.close()

func _rm_dir(path: String) -> void:
	var abs := ProjectSettings.globalize_path(path)
	var d := DirAccess.open(abs)
	if d == null: return
	for f in d.get_files():
		d.remove(f)
	for sub in d.get_directories():
		_rm_dir(path + "/" + sub)
	DirAccess.remove_absolute(abs)
