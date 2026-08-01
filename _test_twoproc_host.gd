extends SceneTree
## Half of the two-process integration test: a real host in its own Godot
## process, talking over a real socket to a separate client process.
## Run by _test_twoproc.ps1 -- not meaningful on its own.

const HostServer := preload("res://addons/godot_collab/network/host_server.gd")
const Protocol := preload("res://addons/godot_collab/network/protocol.gd")

func _init() -> void:
	var port := 8985
	var host := HostServer.new()
	var err := host.start(port, "HostProc", "TWO-PROC")
	if err != "":
		print("HOST_FAIL start: %s" % err)
		quit(1)
		return
	print("HOST_READY")

	# NOTE: GDScript lambdas capture locals BY VALUE, so results must be
	# collected in reference types (Dictionary/Array) to survive the callback.
	var seen := {"joined": "", "chat": "", "peak_roster": 0}
	var got_file := {"path": "", "bytes": 0}
	host.peer_joined.connect(func(u): seen.joined = str(u.name))
	host.chat.connect(func(uid, t): seen.chat = str(t))
	host.client_file_change.connect(func(uid, path, base, bytes):
		got_file.path = path
		got_file.bytes = bytes.size()
		# Echo it back so the client can prove the round trip.
		var msg := {"type": Protocol.T_FILE_UPDATE, "path": path,
			"version": host.bump_version(path), "source": "host"}
		msg.merge(Protocol.encode_payload(bytes))
		host.broadcast(msg))

	# Run for up to 25 seconds or until the client has finished.
	var deadline := Time.get_ticks_msec() + 25000
	while Time.get_ticks_msec() < deadline:
		host.poll(0.016)
		seen.peak_roster = maxi(int(seen.peak_roster), host.get_roster().size())
		if seen.joined != "" and seen.chat != "" and got_file.path != "":
			break
		OS.delay_msec(15)

	# Give the echo a moment to flush before we tear down.
	for i in 60:
		host.poll(0.016)
		OS.delay_msec(10)

	print("HOST_JOINED=%s" % seen.joined)
	print("HOST_CHAT=%s" % seen.chat)
	print("HOST_FILE=%s:%d" % [got_file.path, got_file.bytes])
	print("HOST_ROSTER=%d" % seen.peak_roster)
	host.stop()
	var ok: bool = seen.joined == "ClientProc" \
		and seen.chat == "hello from the other process" \
		and got_file.path == "res://twoproc.gd" \
		and int(seen.peak_roster) == 2
	print("HOST_RESULT=%s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)
