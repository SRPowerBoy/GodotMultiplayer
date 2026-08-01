extends SceneTree
## Tests file ownership ("primary") rules and the self-sync exclusion that
## previously let the addon overwrite itself and kill the joining editor.

const HostServer := preload("res://addons/godot_collab/network/host_server.gd")
const ClientConnection := preload("res://addons/godot_collab/network/client_connection.gd")
const Protocol := preload("res://addons/godot_collab/network/protocol.gd")
const FileSync := preload("res://addons/godot_collab/sync/file_sync.gd")

var results: Array = []
func ok(c: bool, l: String) -> void:
	results.append(c); print(("PASS " if c else "FAIL ") + l)

func _pump(h, c, frames: int) -> void:
	for i in frames:
		if h: h.poll(0.016)
		if c: c.poll(0.016)
		OS.delay_msec(10)

func _init() -> void:
	# ---------- self-sync exclusion (the crash fix) ----------
	ok(FileSync.is_excluded("res://addons/godot_collab/plugin.gd"),
		"addon's own scripts are excluded from sync")
	ok(FileSync.is_excluded("res://addons/godot_collab/ui/collab_panel.gd"),
		"nested addon files excluded too")
	ok(not FileSync.is_excluded("res://player.gd"), "normal scripts still sync")
	ok(not FileSync.is_excluded("res://scenes/level.tscn"), "normal scenes still sync")
	# Every addon is excluded: overwriting a running plugin hot-reloads and
	# crashes it, so addons are never session content.
	ok(FileSync.is_excluded("res://addons/claudot/plugin.gd"),
		"other addons are excluded too (no mid-run hot-reload crashes)")

	var fs := FileSync.new()
	fs.apply_remote("res://addons/godot_collab/plugin.gd", "MALICIOUS".to_utf8_buffer(), 9)
	var f := FileAccess.open("res://addons/godot_collab/plugin.gd", FileAccess.READ)
	var head := f.get_as_text().substr(0, 5) if f else ""
	if f: f.close()
	ok(head == "@tool", "remote write to the addon is refused (head='%s')" % head)

	# ---------- claim rules ----------
	var port := 8979
	var host := HostServer.new()
	ok(host.start(port, "Host", "C") == "", "host started")

	var a := ClientConnection.new()
	a.connect_to_host("127.0.0.1", port, "Alice", "C")
	_pump(host, a, 120)
	var b := ClientConnection.new()
	b.connect_to_host("127.0.0.1", port, "Bob", "C")
	_pump(host, b, 120)
	_pump(host, a, 30)
	ok(host.get_roster().size() == 3, "host + 2 clients (got %d)" % host.get_roster().size())

	# --- chat: relayed to others, never echoed to the sender ---
	var a_got := {"n": 0}
	var b_got := {"n": 0, "text": ""}
	a.chat.connect(func(_n, _c, _t): a_got.n += 1)
	b.chat.connect(func(_n, _c, t): b_got.n += 1; b_got.text = t)
	a.send({"type": Protocol.T_CHAT, "text": "ping from Alice"})
	for i in 6:
		_pump(host, a, 10)
		_pump(host, b, 10)
	ok(b_got.n == 1 and b_got.text == "ping from Alice",
		"chat relays to other clients (got %d: '%s')" % [b_got.n, b_got.text])
	ok(a_got.n == 0, "sender gets no echo of their own chat (got %d)" % a_got.n)

	# Unclaimed files are editable by anyone.
	ok(host.can_edit(1, "res://a.gd"), "unclaimed file is editable")

	# Alice claims a.gd.
	var r1 := host.claim_file(1, "res://a.gd")
	ok(r1.granted, "first claim granted")
	ok(host.owner_of("res://a.gd") == 1, "owner recorded")
	ok(host.can_edit(1, "res://a.gd"), "owner may edit")
	ok(not host.can_edit(2, "res://a.gd"), "non-owner may NOT edit")

	# Bob is denied the same file and told who holds it.
	var r2 := host.claim_file(2, "res://a.gd")
	ok(not r2.granted, "second claim denied")
	ok(r2.owner_name == "Alice", "denial names the holder (got '%s')" % r2.owner_name)
	ok(host.owner_of("res://a.gd") == 1, "ownership unchanged after denial")

	# One primary per user: Alice switching releases a.gd.
	var r3 := host.claim_file(1, "res://b.tscn")
	ok(r3.granted, "switching to a new file is granted")
	ok(host.claim_of(1) == "res://b.tscn", "claim moved to the new file")
	ok(host.owner_of("res://a.gd") == -1, "previous file released automatically")

	# Now Bob can take the freed file.
	var r4 := host.claim_file(2, "res://a.gd")
	ok(r4.granted, "freed file can be claimed by someone else")

	# Re-claiming your own file is a no-op success.
	ok(host.claim_file(2, "res://a.gd").granted, "re-claiming own file is fine")

	# Claims map is exposed for the UI.
	var claims := host.get_claims()
	ok(claims.has("res://a.gd") and str(claims["res://a.gd"].name) == "Bob",
		"claims map reports the holder")

	# --- editing an unclaimed file auto-assigns it ---
	host.release_claim(1)
	host.release_claim(2)
	ok(host.owner_of("res://fresh.gd") == -1, "fresh file starts unclaimed")
	ok(host.can_edit(1, "res://fresh.gd"), "anyone may edit an unclaimed file")
	ok(host.can_edit(2, "res://fresh.gd"), "...including a second person")

	# --- idle claims are released so nobody hoards a file ---
	host.claim_file(1, "res://idle.gd")
	ok(host.owner_of("res://idle.gd") == 1, "claim held while active")
	host.touch_claim(1)
	host.expire_idle_claims()
	ok(host.owner_of("res://idle.gd") == 1, "recent activity keeps the claim")
	# Backdate the activity clock past the idle window.
	host._claim_touch[1] = Time.get_ticks_msec() - (Protocol.CLAIM_IDLE_RELEASE + 1000)
	host.expire_idle_claims()
	ok(host.owner_of("res://idle.gd") == -1, "idle claim auto-released")
	ok(host.claim_file(2, "res://idle.gd").granted,
		"someone else can take a released file")

	# Disconnect frees the claim.
	b.disconnect_from_host()
	_pump(host, null, 80)
	ok(host.owner_of("res://a.gd") == -1, "claim released when the owner disconnects")

	host.stop()

	var passed := 0
	for r in results:
		if r: passed += 1
	print("\n==== %d/%d passed ====" % [passed, results.size()])
	quit(0 if passed == results.size() else 1)
