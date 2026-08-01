extends SceneTree
## Exercises the full join handshake the way plugin.gd drives it:
## hello -> welcome -> manifest -> accept -> snapshot -> end.
## This is the path that broke; it had no end-to-end coverage before.

const HostServer := preload("res://addons/godot_collab/network/host_server.gd")
const ClientConnection := preload("res://addons/godot_collab/network/client_connection.gd")
const Protocol := preload("res://addons/godot_collab/network/protocol.gd")

var results: Array = []
func ok(c: bool, l: String) -> void:
	results.append(c); print(("PASS " if c else "FAIL ") + l)

func _pump(h, c, n: int) -> void:
	for i in n:
		if h: h.poll(0.016)
		if c: c.poll(0.016)
		OS.delay_msec(8)

func _init() -> void:
	var port := 8987
	var host := HostServer.new()
	ok(host.start(port, "H", "JOIN-TEST") == "", "host started")

	# Mirror plugin.gd: on join, send a manifest and wait for the go-ahead.
	var state := {"manifest_sent": false, "accepted": false, "snapshot_sent": false}
	var files := {"res://a.gd": "aaa", "res://b.tscn": "bbb"}
	host.peer_joined.connect(func(u):
		var paths := files.keys()
		var hashes := {}
		for p in paths:
			hashes[p] = str(files[p]).md5_text()
		host.send_to(int(u.id), {"type": Protocol.T_MANIFEST,
			"paths": paths, "hashes": hashes})
		host.expect_manifest_reply(int(u.id))
		state.manifest_sent = true)
	host.snapshot_accepted.connect(func(uid):
		state.accepted = true
		host.send_to(uid, {"type": Protocol.T_SNAPSHOT_BEGIN})
		for p in files:
			var msg := {"type": Protocol.T_FILE_UPDATE, "path": p,
				"version": host.bump_version(p), "source": "host"}
			msg.merge(Protocol.encode_payload(str(files[p]).to_utf8_buffer()))
			host.send_to(uid, msg)
		host.send_to(uid, {"type": Protocol.T_SNAPSHOT_END, "total": files.size()})
		state.snapshot_sent = true)

	var client := ClientConnection.new()
	var got := {"welcomed": false, "manifest": -1, "hashes": 0, "files": 0,
		"begin": false, "end": -1, "project": ""}
	client.welcomed.connect(func(id, role, color, roster):
		got.welcomed = true
		got.project = client.host_project)
	client.manifest.connect(func(paths, hashes):
		got.manifest = paths.size()
		got.hashes = hashes.size())
	client.snapshot_begin.connect(func(): got.begin = true)
	client.file_update.connect(func(p, b, v): got.files += 1)
	client.snapshot_end.connect(func(total): got.end = total)

	client.connect_to_host("127.0.0.1", port, "C", "JOIN-TEST")
	_pump(host, client, 150)

	ok(got.welcomed, "client was welcomed")
	ok(str(got.project) != "", "welcome carries the host's project fingerprint")
	ok(state.manifest_sent, "host sent a manifest")
	ok(got.manifest == 2, "client received the manifest (%d paths)" % got.manifest)
	ok(got.hashes == 2, "manifest carried hashes (%d)" % got.hashes)

	# Nothing must be transferred until the client accepts.
	ok(not got.begin, "no snapshot before the client accepts")
	ok(got.files == 0, "no files before the client accepts")

	# Accept, exactly as the review dialog does.
	client.send({"type": Protocol.T_SNAPSHOT_ACCEPT})
	_pump(host, client, 120)

	ok(state.accepted, "host saw the acceptance")
	ok(got.begin, "snapshot started after acceptance")
	ok(got.files == 2, "all files arrived (%d)" % got.files)
	ok(got.end == 2, "snapshot end reported the total (%d)" % got.end)

	# A declining client must not receive anything either.
	var d := ClientConnection.new()
	var dgot := {"begin": false}
	d.snapshot_begin.connect(func(): dgot.begin = true)
	d.manifest.connect(func(p, h): d.send({"type": Protocol.T_SNAPSHOT_DECLINE}))
	d.connect_to_host("127.0.0.1", port, "D", "JOIN-TEST")
	_pump(host, d, 150)
	ok(not dgot.begin, "declining prevents any transfer")

	host.stop()
	var passed := 0
	for r in results:
		if r: passed += 1
	print("\n==== %d/%d passed ====" % [passed, results.size()])
	quit(0 if passed == results.size() else 1)
