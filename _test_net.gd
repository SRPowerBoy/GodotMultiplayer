extends SceneTree
## Headless integration test for the networking layer (no editor needed).

const HostServer := preload("res://addons/godot_collab/network/host_server.gd")
const ClientConnection := preload("res://addons/godot_collab/network/client_connection.gd")
const Protocol := preload("res://addons/godot_collab/network/protocol.gd")

var results: Array = []

func ok(cond: bool, label: String) -> void:
	results.append([cond, label])
	print(("PASS " if cond else "FAIL ") + label)

func _pump(host, client, frames: int) -> void:
	for i in frames:
		if host: host.poll(0.016)
		if client: client.poll(0.016)
		OS.delay_msec(10)

func _init() -> void:
	var port := 8977
	var code := "TEST-0001"

	# --- Host starts ---
	var host := HostServer.new()
	var err := host.start(port, "HostGuy", code)
	ok(err == "", "host starts (err='%s')" % err)

	var chat_got := {"v": ""}
	host.chat.connect(func(uid, t): chat_got.v = t)
	var joined := {"n": 0}
	host.peer_joined.connect(func(u): joined.n += 1)

	# --- Good client joins ---
	var client := ClientConnection.new()
	var welcomed := {"id": -1, "role": "", "roster": []}
	client.welcomed.connect(func(id, role, color, roster):
		welcomed.id = id; welcomed.role = role; welcomed.roster = roster)
	var rejected := {"reason": ""}
	client.rejected.connect(func(r): rejected.reason = r)
	client.connect_to_host("127.0.0.1", port, "Alice", code)

	_pump(host, client, 120)

	ok(welcomed.id == 1, "client welcomed with id 1 (got %d)" % welcomed.id)
	ok(welcomed.role == Protocol.ROLE_EDITOR, "client role is editor (got '%s')" % welcomed.role)
	ok(joined.n == 1, "host saw 1 join (got %d)" % joined.n)
	ok(host.get_roster().size() == 2, "roster has 2 (got %d)" % host.get_roster().size())

	# --- Chat round trip client -> host ---
	# The sender must NOT get their own line echoed back (it would duplicate,
	# because the sender already printed it locally).
	var echoed := {"n": 0}
	client.chat.connect(func(_n, _c, _t): echoed.n += 1)
	client.send({"type": Protocol.T_CHAT, "text": "hello host"})
	_pump(host, client, 40)
	ok(chat_got.v == "hello host", "host received chat (got '%s')" % chat_got.v)
	ok(echoed.n == 0, "sender does NOT receive their own chat back (got %d echoes)" % echoed.n)

	# --- Version bookkeeping ---
	ok(host.get_version("res://a.gd") == 0, "unknown file version is 0")
	ok(host.bump_version("res://a.gd") == 1, "first bump -> 1")
	ok(host.bump_version("res://a.gd") == 2, "second bump -> 2")

	# --- Invite link round-trip ---
	var invite := Protocol.make_invite("192.168.1.20", 8890, "ABCD-4829")
	var parsed = Protocol.parse_invite(invite)
	ok(parsed != null and parsed.ip == "192.168.1.20" and parsed.port == 8890
		and parsed.code == "ABCD-4829", "invite round-trips (%s)" % invite)
	ok(Protocol.parse_invite("not a link") == null, "garbage invite rejected")

	# --- Compression round-trips (large compressible + small + binary) ---
	var big := ("extends Node\nfunc _ready(): print('hi')\n".repeat(200)).to_utf8_buffer()
	var enc := Protocol.encode_payload(big)
	ok(enc.enc == "gzip", "large text payload is gzipped (enc=%s)" % enc.enc)
	var dec := Protocol.decode_payload(enc)
	ok(dec == big, "gzip payload round-trips exactly (%d -> %d b64)" % [big.size(), str(enc.data).length()])
	ok(str(enc.data).length() < big.size(), "compressed payload is smaller than raw")

	var small := "tiny".to_utf8_buffer()
	var senc := Protocol.encode_payload(small)
	ok(senc.enc == "raw", "small payload stays raw (enc=%s)" % senc.enc)
	ok(Protocol.decode_payload(senc) == small, "raw payload round-trips")

	var bin := PackedByteArray()
	for i in 5000:
		bin.append(i % 256)
	ok(Protocol.decode_payload(Protocol.encode_payload(bin)) == bin, "binary payload round-trips")

	# --- Role change reaches the client ---
	var role_now := {"v": ""}
	client.role_changed.connect(func(r): role_now.v = r)
	host.set_user_role(1, Protocol.ROLE_VIEWER)
	_pump(host, client, 40)
	ok(role_now.v == Protocol.ROLE_VIEWER, "role change delivered (got '%s')" % role_now.v)
	ok(client.my_role == Protocol.ROLE_VIEWER, "client applied new role")

	# --- Viewer edits are refused by the host ---
	var refused := {"hit": false}
	host.client_file_change.connect(func(_u, _p, _b, _by): refused.hit = true)
	var vmsg := {"type": Protocol.T_FILE_CHANGE, "path": "res://x.gd", "base_version": 0}
	vmsg.merge(Protocol.encode_payload("blocked".to_utf8_buffer()))
	client.send(vmsg)
	_pump(host, client, 40)
	ok(not refused.hit, "viewer file edit rejected by host")

	# --- Kick removes the peer ---
	host.set_user_role(1, Protocol.ROLE_EDITOR)
	_pump(host, client, 20)
	var kick_reason := {"v": ""}
	client.kicked.connect(func(r): kick_reason.v = r)
	host.kick_user(1, "test kick")
	_pump(host, client, 80)
	ok(kick_reason.v == "test kick", "kick delivered to client (got '%s')" % kick_reason.v)
	ok(client.was_kicked, "client recorded the kick")
	_pump(host, client, 60)
	ok(host.get_roster().size() == 1, "kicked peer left the roster (got %d)" % host.get_roster().size())

	# Re-join a fresh client so the later disconnect assertions still hold.
	client = ClientConnection.new()
	client.connect_to_host("127.0.0.1", port, "Alice2", code)
	_pump(host, client, 120)
	ok(host.get_roster().size() == 2, "second client joined (got %d)" % host.get_roster().size())

	# --- Wrong-code client is rejected ---
	var bad := ClientConnection.new()
	var bad_reject := {"reason": ""}
	bad.rejected.connect(func(r): bad_reject.reason = r)
	bad.connect_to_host("127.0.0.1", port, "Mallory", "WRONG-9999")
	_pump(host, bad, 120)
	ok(bad_reject.reason != "", "wrong code rejected (reason='%s')" % bad_reject.reason)
	ok(host.get_roster().size() == 2, "roster still 2 after bad join (got %d)" % host.get_roster().size())

	# --- Client disconnect is noticed ---
	client.disconnect_from_host()
	_pump(host, null, 60)
	ok(host.get_roster().size() == 1, "roster back to 1 after leave (got %d)" % host.get_roster().size())

	host.stop()

	# --- Summary ---
	var passed := 0
	for r in results:
		if r[0]: passed += 1
	print("\n==== %d/%d passed ====" % [passed, results.size()])
	quit(0 if passed == results.size() else 1)
