extends SceneTree
## Client half of the two-process integration test.

const ClientConnection := preload("res://addons/godot_collab/network/client_connection.gd")
const Protocol := preload("res://addons/godot_collab/network/protocol.gd")

func _init() -> void:
	var port := 8985
	var c := ClientConnection.new()
	var welcomed := {"ok": false, "role": ""}
	var echoed := {"path": "", "text": ""}
	c.welcomed.connect(func(id, role, color, roster):
		welcomed.ok = true
		welcomed.role = role)
	c.file_update.connect(func(path, bytes, version):
		echoed.path = path
		echoed.text = bytes.get_string_from_utf8())

	var err := c.connect_to_host("127.0.0.1", port, "ClientProc", "TWO-PROC")
	if err != "":
		print("CLIENT_FAIL connect: %s" % err)
		quit(1)
		return

	# Wait for the handshake.
	var deadline := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline and not welcomed.ok:
		c.poll(0.016)
		OS.delay_msec(15)
	if not welcomed.ok:
		print("CLIENT_FAIL: never welcomed")
		quit(1)
		return

	# Real traffic across the process boundary.
	c.send({"type": Protocol.T_CHAT, "text": "hello from the other process"})
	var payload := "extends Node\nfunc _ready(): pass\n".repeat(50).to_utf8_buffer()
	var msg := {"type": Protocol.T_FILE_CHANGE, "path": "res://twoproc.gd",
		"base_version": 0}
	msg.merge(Protocol.encode_payload(payload))
	c.send(msg)

	# Wait for the host's echo to come back.
	deadline = Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline and echoed.path == "":
		c.poll(0.016)
		OS.delay_msec(15)

	print("CLIENT_WELCOMED=%s" % welcomed.role)
	print("CLIENT_ECHO=%s" % echoed.path)
	print("CLIENT_BYTES=%d" % echoed.text.length())
	c.disconnect_from_host()
	var ok: bool = welcomed.ok and echoed.path == "res://twoproc.gd" \
		and echoed.text == payload.get_string_from_utf8()
	print("CLIENT_RESULT=%s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)
