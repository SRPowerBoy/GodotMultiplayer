@tool
extends RefCounted
## Client end of the connection. Talks only to the host.

signal opened()
signal closed()
signal welcomed(id: int, role: String, color: String, roster: Array)
signal rejected(reason: String)
signal connect_failed(reason: String)
signal roster_updated(roster: Array)
signal chat(name: String, color: String, text: String)
signal system(text: String)
signal file_update(path: String, bytes: PackedByteArray, version: int)
signal file_delete(path: String)
signal file_rejected(path: String, your_version: int, host_version: int)
signal presence(data: Dictionary)
signal role_changed(role: String)
signal kicked(reason: String)
signal manifest(paths: Array, hashes: Dictionary)
signal snapshot_begin()
signal snapshot_end(total: int)
signal claim_result(path: String, granted: bool, owner_name: String)
signal claims_updated(claims: Dictionary)
signal handover_requested(path: String, from_name: String)
signal log(text: String)

const Protocol := preload("res://addons/godot_collab/network/protocol.gd")
const BUFFER := 16 * 1024 * 1024

var connected := false
var my_id := -1
var my_role := Protocol.ROLE_EDITOR
var my_color := "#ffffff"
var was_kicked := false
## Rough traffic + latency figures for the UI.
var bytes_in := 0
var bytes_out := 0
var latency_ms := -1
## Where the host keeps its project, used to detect a shared folder.
var host_project := ""

var _ws := WebSocketPeer.new()
var _name := ""
var _code := ""
var _hello_sent := false
var _active := false
var _last_ping := 0
var _last_heard := 0
var _timed_out := false
var _connect_started := 0
var _target := ""
var _ping_sent_at := 0

func connect_to_host(ip: String, port: int, user_name: String, code: String) -> String:
	_ws = WebSocketPeer.new()
	_ws.inbound_buffer_size = BUFFER
	_ws.outbound_buffer_size = BUFFER
	_ws.max_queued_packets = 4096
	_name = user_name
	_code = code
	_hello_sent = false
	_active = true
	connected = false
	_timed_out = false
	was_kicked = false
	_last_ping = Time.get_ticks_msec()
	_last_heard = Time.get_ticks_msec()
	_connect_started = Time.get_ticks_msec()
	_target = "%s:%d" % [ip, port]
	var url := "ws://" + _target
	var err := _ws.connect_to_url(url)
	if err != OK:
		_active = false
		return "Could not start connection to %s (error %d)." % [url, err]
	log.emit("Connecting to %s ..." % url)
	return ""

func disconnect_from_host() -> void:
	if _active:
		_ws.close(1000, "left")
	_active = false
	connected = false

func was_timed_out() -> bool:
	return _timed_out

func send(msg: Dictionary) -> void:
	if connected and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		var text := Protocol.stringify(msg)
		bytes_out += text.length()
		_ws.send_text(text)

func poll(_delta: float) -> void:
	if not _active:
		return
	_ws.poll()
	var st := _ws.get_ready_state()

	# Give up if the connect or handshake never completes. Covers an unreachable
	# host, a wrong port, a firewall silently dropping packets, and a host that
	# accepts the socket but never answers.
	if not connected and st != WebSocketPeer.STATE_CLOSED:
		if Time.get_ticks_msec() - _connect_started > Protocol.CONNECT_TIMEOUT:
			var why := ""
			if st == WebSocketPeer.STATE_OPEN:
				# Socket opened, so something is there -- it just never replied.
				why = ("Reached the host, but it never answered. Check that the "
					+ "other side is actually hosting a session.")
			else:
				why = ("Could not reach %s. Nothing is listening on that address "
					+ "and port, or a firewall is blocking it.") % _target
			_active = false
			_ws.close(1001, "connect timeout")
			log.emit("Connection attempt timed out.")
			connect_failed.emit(why)
			return

	# Send our handshake as soon as the socket opens.
	if st == WebSocketPeer.STATE_OPEN and not _hello_sent:
		_hello_sent = true
		_ws.send_text(Protocol.stringify({
			"type": Protocol.T_HELLO,
			"protocol": Protocol.PROTOCOL_VERSION,
			"name": _name, "code": _code,
			"engine": Protocol.engine_version(),
		}))
	# Drain buffered packets while OPEN *or* CLOSING -- a rejection frame can
	# arrive on the same tick the host starts closing the connection.
	if st == WebSocketPeer.STATE_OPEN or st == WebSocketPeer.STATE_CLOSING:
		while _ws.get_available_packet_count() > 0:
			_last_heard = Time.get_ticks_msec()
			var pkt := _ws.get_packet()
			bytes_in += pkt.size()
			_handle(pkt.get_string_from_utf8())
		# Heartbeat + silent-drop detection once we are in a live session.
		if connected:
			var now := Time.get_ticks_msec()
			if now - _last_ping >= Protocol.HEARTBEAT_INTERVAL:
				_last_ping = now
				_ping_sent_at = now
				_ws.send_text(Protocol.stringify({"type": Protocol.T_PING}))
			if now - _last_heard > Protocol.CONNECTION_TIMEOUT:
				_timed_out = true
				log.emit("Host stopped responding.")
				_ws.close(1001, "timeout")
	elif st == WebSocketPeer.STATE_CLOSED:
		if _active:
			_active = false
			connected = false
			var code := _ws.get_close_code()
			var reason := _ws.get_close_reason()
			log.emit("Disconnected (%d %s)." % [code, reason])
			closed.emit()

func _handle(text: String) -> void:
	var msg = Protocol.parse(text)
	if msg == null:
		return
	match str(msg.get("type", "")):
		Protocol.T_WELCOME:
			my_id = int(msg.get("id", -1))
			my_role = str(msg.get("role", Protocol.ROLE_EDITOR))
			my_color = str(msg.get("color", "#ffffff"))
			host_project = str(msg.get("project", ""))
			connected = true
			opened.emit()
			welcomed.emit(my_id, my_role, my_color, msg.get("roster", []))
		Protocol.T_REJECT:
			var reason := str(msg.get("reason", "Connection rejected."))
			rejected.emit(reason)
			_active = false
			connected = false
		Protocol.T_ROSTER:
			roster_updated.emit(msg.get("roster", []))
		Protocol.T_SYSTEM:
			system.emit(str(msg.get("text", "")))
		Protocol.T_CHAT:
			chat.emit(str(msg.get("name", "?")), str(msg.get("color", "#ffffff")),
				str(msg.get("text", "")))
		Protocol.T_PRESENCE:
			presence.emit(msg)
		Protocol.T_FILE_UPDATE:
			var path := str(msg.get("path", ""))
			var version := int(msg.get("version", 0))
			var bytes := Protocol.decode_payload(msg)
			file_update.emit(path, bytes, version)
		Protocol.T_FILE_DELETE:
			file_delete.emit(str(msg.get("path", "")))
		Protocol.T_FILE_REJECT:
			file_rejected.emit(str(msg.get("path", "")),
				int(msg.get("your_version", 0)), int(msg.get("host_version", 0)))
		Protocol.T_CLAIM_RESULT:
			claim_result.emit(str(msg.get("path", "")),
				bool(msg.get("granted", false)), str(msg.get("owner_name", "")))
		Protocol.T_CLAIMS:
			claims_updated.emit(msg.get("claims", {}))
		Protocol.T_HANDOVER:
			handover_requested.emit(str(msg.get("path", "")),
				str(msg.get("from_name", "Someone")))
		Protocol.T_MANIFEST:
			manifest.emit(msg.get("paths", []), msg.get("hashes", {}))
		Protocol.T_SNAPSHOT_BEGIN:
			snapshot_begin.emit()
		Protocol.T_SNAPSHOT_END:
			snapshot_end.emit(int(msg.get("total", 0)))
		Protocol.T_ROLE:
			my_role = str(msg.get("role", my_role))
			role_changed.emit(my_role)
		Protocol.T_KICK:
			var why := str(msg.get("reason", "Removed by the host."))
			was_kicked = true
			kicked.emit(why)
		Protocol.T_PING:
			_ws.send_text(Protocol.stringify({"type": Protocol.T_PONG}))
		Protocol.T_PONG:
			if _ping_sent_at > 0:
				latency_ms = Time.get_ticks_msec() - _ping_sent_at
				_ping_sent_at = 0
