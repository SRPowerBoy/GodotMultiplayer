@tool
extends RefCounted
## Embedded, host-authoritative collaboration server.
##
## Godot 4 has no high-level WebSocket *server* class, so we accept raw TCP
## connections with TCPServer and upgrade each one with WebSocketPeer.accept_stream().
## The host runs this inside its editor; it owns the authoritative project state
## and per-file version numbers. Clients never talk to each other directly.

signal log(text: String)
signal roster_changed(roster: Array)
signal peer_joined(user: Dictionary)
signal peer_left(user: Dictionary)
signal chat(user_id: int, text: String)
signal presence(user_id: int, data: Dictionary)
signal client_file_change(user_id: int, path: String, base_version: int, bytes: PackedByteArray)
signal client_file_delete(user_id: int, path: String)
signal claims_changed(claims: Dictionary)
signal handover_requested(path: String, from_name: String)
signal snapshot_accepted(user_id: int)
signal snapshot_declined(user_id: int)

const Protocol := preload("res://addons/godot_collab/network/protocol.gd")
const BUFFER := 16 * 1024 * 1024

var running := false
var host_user := {}            # the host's own roster entry (id 0)

var _tcp := TCPServer.new()
var _records: Array = []       # [{ws:WebSocketPeer, user:Dictionary|null, last_seen:int}]
var _versions := {}            # res-path -> int
var _code := ""
var _default_role := Protocol.ROLE_EDITOR
var _next_id := 1
var _last_ping := 0
var bytes_in := 0
var bytes_out := 0

# -- lifecycle -------------------------------------------------------------

func start(port: int, host_name: String, code: String, default_role: String = Protocol.ROLE_EDITOR) -> String:
	if running:
		return "Already hosting."
	var err := _tcp.listen(port)
	if err != OK:
		return "Could not listen on port %d (error %d). Is it already in use?" % [port, err]
	_code = code
	_default_role = default_role
	host_user = {
		"id": 0, "name": host_name, "color": Protocol.color_for_id(0),
		"role": Protocol.ROLE_HOST, "scene": "", "selection": [],
	}
	running = true
	_next_id = 1
	_records.clear()
	log.emit("Hosting on port %d. Session code: %s" % [port, code])
	return ""

func stop() -> void:
	if not running:
		return
	for r in _records:
		if r.ws:
			r.ws.close(1000, "Host ended the session")
	_records.clear()
	_tcp.stop()
	_versions.clear()
	running = false
	roster_changed.emit(get_roster())
	log.emit("Session closed.")

func poll(_delta: float) -> void:
	if not running:
		return
	# Accept any pending TCP connections and wrap them in a WebSocketPeer.
	while _tcp.is_connection_available():
		var conn := _tcp.take_connection()
		var ws := WebSocketPeer.new()
		ws.inbound_buffer_size = BUFFER
		ws.outbound_buffer_size = BUFFER
		ws.max_queued_packets = 4096
		ws.accept_stream(conn)
		_records.append({"ws": ws, "user": null, "last_seen": Time.get_ticks_msec()})

	var now := Time.get_ticks_msec()

	# Heartbeat: ping authenticated peers so both ends can detect a silent drop.
	if now - _last_ping >= Protocol.HEARTBEAT_INTERVAL:
		_last_ping = now
		broadcast({"type": Protocol.T_PING})
		expire_idle_claims()
		expire_manifest_waits()

	# Service every connection.
	var dead: Array = []
	for r in _records:
		var ws: WebSocketPeer = r.ws
		ws.poll()
		var st := ws.get_ready_state()
		if st == WebSocketPeer.STATE_OPEN or st == WebSocketPeer.STATE_CLOSING:
			while ws.get_available_packet_count() > 0:
				var packet := ws.get_packet()
				bytes_in += packet.size()
				r.last_seen = now
				# Refuse absurd frames rather than parsing them into memory.
				if packet.size() > Protocol.MAX_MESSAGE_BYTES:
					log.emit("Dropped oversized message (%d bytes)." % packet.size())
					continue
				if not _allow_rate(r, now):
					continue
				_handle(r, packet.get_string_from_utf8())
			# Deferred close: give poll() a few ticks to flush a rejection frame
			# before we actually close, otherwise the client never sees it.
			if r.get("close_in", -1) >= 0:
				r.close_in -= 1
				if r.close_in < 0:
					ws.close(1000, r.get("close_reason", ""))
			# Drop peers that have gone silent past the timeout.
			elif now - int(r.last_seen) > Protocol.CONNECTION_TIMEOUT:
				if r.user != null:
					log.emit("%s timed out." % r.user.name)
				ws.close(1001, "timeout")
				dead.append(r)
		elif st == WebSocketPeer.STATE_CLOSED:
			dead.append(r)

	for r in dead:
		_drop(r)

## Simple fixed-window rate limit per connection. A peer stuck in a loop can
## otherwise saturate the host; we drop the excess and say so once per window
## rather than disconnecting, since a brief burst of saves is legitimate.
func _allow_rate(r: Dictionary, now: int) -> bool:
	var start := int(r.get("rate_start", 0))
	if now - start >= Protocol.RATE_LIMIT_WINDOW:
		r["rate_start"] = now
		r["rate_count"] = 0
		r["rate_warned"] = false
	var count := int(r.get("rate_count", 0)) + 1
	r["rate_count"] = count
	if count <= Protocol.RATE_LIMIT_MESSAGES:
		return true
	if not bool(r.get("rate_warned", false)):
		r["rate_warned"] = true
		var who := str(r.user.name) if r.user != null else "A peer"
		log.emit("%s is sending too fast - throttling." % who)
	return false

# -- versioning (authoritative) -------------------------------------------

func get_version(path: String) -> int:
	return int(_versions.get(path, 0))

func bump_version(path: String) -> int:
	var v := get_version(path) + 1
	_versions[path] = v
	return v

## Version numbers survive a host restart, so a returning collaborator is not
## silently told their up-to-date file is stale (or vice versa).
const STATE_PATH := "user://godot_collab_versions.cfg"

func save_state() -> void:
	var cfg := ConfigFile.new()
	for path in _versions:
		cfg.set_value("versions", path.md5_text(), [path, _versions[path]])
	cfg.save(STATE_PATH)

func load_state() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(STATE_PATH) != OK:
		return
	if not cfg.has_section("versions"):
		return
	for key in cfg.get_section_keys("versions"):
		var entry = cfg.get_value("versions", key, null)
		if typeof(entry) == TYPE_ARRAY and entry.size() == 2:
			_versions[str(entry[0])] = int(entry[1])

# -- messaging -------------------------------------------------------------

func send_to(id: int, msg: Dictionary) -> void:
	for r in _records:
		if r.user != null and r.user.id == id and r.ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			r.ws.send_text(Protocol.stringify(msg))
			return

func broadcast(msg: Dictionary, except_id: int = -1) -> void:
	var text := Protocol.stringify(msg)
	for r in _records:
		if r.user != null and r.user.id != except_id and r.ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			bytes_out += text.length()
			r.ws.send_text(text)

func get_roster() -> Array:
	var roster: Array = []
	if running:
		roster.append(host_user.duplicate())
	for r in _records:
		if r.user != null:
			roster.append(r.user.duplicate())
	return roster

func find_user(id: int):
	if id == 0:
		return host_user
	for r in _records:
		if r.user != null and r.user.id == id:
			return r.user
	return null

# -- moderation (host only) ------------------------------------------------

## Remove a collaborator from the session.
func kick_user(id: int, reason: String = "Removed by the host") -> void:
	for r in _records:
		if r.user != null and r.user.id == id:
			r.ws.send_text(Protocol.stringify({"type": Protocol.T_KICK, "reason": reason}))
			_schedule_close(r, "kicked")
			log.emit("%s was removed from the session." % r.user.name)
			return

## Promote/demote a collaborator between editor and viewer.
func set_user_role(id: int, role: String) -> void:
	for r in _records:
		if r.user != null and r.user.id == id:
			r.user.role = role
			r.ws.send_text(Protocol.stringify({"type": Protocol.T_ROLE, "role": role}))
			broadcast({"type": Protocol.T_SYSTEM,
				"text": "%s is now a %s." % [r.user.name, role]})
			roster_changed.emit(get_roster())
			broadcast({"type": Protocol.T_ROSTER, "roster": get_roster()})
			return

## True when the given peer's socket is still writable.
func is_peer_open(id: int) -> bool:
	for r in _records:
		if r.user != null and r.user.id == id:
			return r.ws.get_ready_state() == WebSocketPeer.STATE_OPEN
	return false

## Rotate the join code. Existing peers stay connected -- the code only gates
## new joins -- so this is a cheap way to stop further arrivals.
func set_code(new_code: String) -> void:
	_code = new_code
	broadcast({"type": Protocol.T_SYSTEM,
		"text": "The host changed the session code. The old one no longer works."})

## The host renaming itself follows the same path as anyone else.
func set_host_name(new_name: String) -> void:
	var wanted := Protocol.clean_nickname(new_name)
	if wanted == "" or wanted == host_user.name:
		return
	var was: String = host_user.name
	host_user.name = wanted
	broadcast({"type": Protocol.T_SYSTEM,
		"text": "%s is now known as %s." % [was, wanted]})
	roster_changed.emit(get_roster())
	broadcast({"type": Protocol.T_ROSTER, "roster": get_roster()})
	_publish_claims()

## Peers who never answer the project review would otherwise sit connected
## forever holding a slot. Give them a generous window, then drop them.
const MANIFEST_TIMEOUT := 180000

var _manifest_deadlines := {}   # user_id -> ticks when we give up

func expect_manifest_reply(user_id: int) -> void:
	_manifest_deadlines[user_id] = Time.get_ticks_msec() + MANIFEST_TIMEOUT

func clear_manifest_deadline(user_id: int) -> void:
	_manifest_deadlines.erase(user_id)

func expire_manifest_waits() -> void:
	var now := Time.get_ticks_msec()
	for uid in _manifest_deadlines.keys():
		if now > int(_manifest_deadlines[uid]):
			_manifest_deadlines.erase(uid)
			log.emit("Peer %d never answered the project review." % uid)
			kick_user(uid, "You did not respond to the project review.")

func peer_count() -> int:
	var n := 0
	for r in _records:
		if r.user != null:
			n += 1
	return n

# -- file ownership ("primary") -------------------------------------------
# One primary file per user; one owner per file. First come, first served.

var _claims := {}        # res-path -> user_id
var _user_claim := {}    # user_id  -> res-path
var _claim_touch := {}   # user_id  -> ticks of their last real edit

## Record that a user actually edited their primary, keeping the claim alive.
func touch_claim(user_id: int) -> void:
	_claim_touch[user_id] = Time.get_ticks_msec()

## Release claims held by people who have not edited for a while. Having a file
## merely open must never lock it away from the rest of the session.
func expire_idle_claims() -> void:
	var now := Time.get_ticks_msec()
	var expired: Array = []
	for uid in _user_claim.keys():
		var last := int(_claim_touch.get(uid, 0))
		if last == 0:
			_claim_touch[uid] = now   # first sight; start the clock
			continue
		if now - last > Protocol.CLAIM_IDLE_RELEASE:
			expired.append(uid)
	for uid in expired:
		var path: String = _user_claim.get(uid, "")
		release_claim(uid, false)
		_claim_touch.erase(uid)
		var u = find_user(uid)
		log.emit("%s released %s (idle)." % [str(u.name) if u else uid, path.get_file()])
	if not expired.is_empty():
		_publish_claims()

## Returns the owner id of a path, or -1 when unclaimed.
func owner_of(path: String) -> int:
	return int(_claims.get(path, -1))

func claim_of(user_id: int) -> String:
	return str(_user_claim.get(user_id, ""))

## True when `user_id` may write `path`.
func can_edit(user_id: int, path: String) -> bool:
	var owner := owner_of(path)
	return owner == -1 or owner == user_id

## Try to make `user_id` the primary of `path`. Releases their previous claim.
## Returns {granted:bool, owner_id:int, owner_name:String}.
func claim_file(user_id: int, path: String) -> Dictionary:
	if path == "":
		release_claim(user_id)
		return {"granted": true, "owner_id": user_id, "owner_name": ""}
	var current := owner_of(path)
	if current != -1 and current != user_id:
		var other = find_user(current)
		return {
			"granted": false, "owner_id": current,
			"owner_name": str(other.name) if other else "someone else",
		}
	# Drop whatever they held before -- one primary per person.
	release_claim(user_id, false)
	_claims[path] = user_id
	_user_claim[user_id] = path
	_claim_touch[user_id] = Time.get_ticks_msec()
	_publish_claims()
	var me = find_user(user_id)
	return {"granted": true, "owner_id": user_id,
		"owner_name": str(me.name) if me else ""}

func release_claim(user_id: int, publish: bool = true) -> void:
	if not _user_claim.has(user_id):
		return
	var path: String = _user_claim[user_id]
	_user_claim.erase(user_id)
	if _claims.get(path) == user_id:
		_claims.erase(path)
	if publish:
		_publish_claims()

## Ownership map for the UI: path -> {id, name, color}.
func get_claims() -> Dictionary:
	var out := {}
	for path in _claims:
		var uid: int = _claims[path]
		var u = find_user(uid)
		out[path] = {
			"id": uid,
			"name": str(u.name) if u else "?",
			"color": str(u.color) if u else "#ffffff",
		}
	return out

func _publish_claims() -> void:
	var payload := get_claims()
	claims_changed.emit(payload)
	broadcast({"type": Protocol.T_CLAIMS, "claims": payload})

# -- inbound handling ------------------------------------------------------

func _handle(r: Dictionary, text: String) -> void:
	var msg = Protocol.parse(text)
	if msg == null:
		return
	var type := str(msg.get("type", ""))

	# Until a peer has completed the handshake, only HELLO is accepted.
	if r.user == null:
		if type == Protocol.T_HELLO:
			_do_handshake(r, msg)
		return

	var uid: int = r.user.id
	match type:
		Protocol.T_CHAT:
			var line := str(msg.get("text", ""))
			r.user["active_at"] = Time.get_ticks_msec()
			chat.emit(uid, line)
			# Echo to everyone EXCEPT the sender -- the sender already showed
			# their own line locally, so including them duplicates it.
			broadcast({"type": Protocol.T_CHAT, "user_id": uid,
				"name": r.user.name, "color": r.user.color, "text": line}, uid)
		Protocol.T_PRESENCE:
			r.user.scene = str(msg.get("scene", ""))
			r.user.selection = msg.get("selection", [])
			presence.emit(uid, msg)
			broadcast({"type": Protocol.T_PRESENCE, "user_id": uid,
				"name": r.user.name, "color": r.user.color,
				"scene": r.user.scene, "selection": r.user.selection}, uid)
			roster_changed.emit(get_roster())
		Protocol.T_FILE_CHANGE:
			if r.user.role == Protocol.ROLE_VIEWER:
				send_to(uid, {"type": Protocol.T_SYSTEM,
					"text": "You are a viewer and cannot edit files."})
				return
			var path := str(msg.get("path", ""))
			if not Protocol.is_safe_path(path):
				log.emit("Rejected unsafe path from %s: %s" % [r.user.name, path])
				return
			if not can_edit(uid, path):
				var holder = find_user(owner_of(path))
				send_to(uid, {"type": Protocol.T_SYSTEM,
					"text": "%s is the primary of %s - your change was not shared." %
					[str(holder.name) if holder else "Someone else", path.get_file()]})
				return
			# Editing an unclaimed file makes you its primary automatically.
			if owner_of(path) == -1:
				claim_file(uid, path)
			touch_claim(uid)
			r.user["active_at"] = Time.get_ticks_msec()
			var base_version := int(msg.get("base_version", 0))
			var bytes := Protocol.decode_payload(msg)
			client_file_change.emit(uid, path, base_version, bytes)
		Protocol.T_FILE_REQUEST:
			# The plugin owns disk access; re-emit as a change request with
			# version -1 so it resends the authoritative copy.
			client_file_change.emit(uid, str(msg.get("path", "")), -999, PackedByteArray())
		Protocol.T_FILE_DELETE:
			if r.user.role == Protocol.ROLE_VIEWER:
				return
			if not can_edit(uid, str(msg.get("path", ""))):
				return
			client_file_delete.emit(uid, str(msg.get("path", "")))
		Protocol.T_CLAIM:
			var want := str(msg.get("path", ""))
			var res := claim_file(uid, want)
			send_to(uid, {"type": Protocol.T_CLAIM_RESULT, "path": want,
				"granted": res.granted, "owner_id": res.owner_id,
				"owner_name": res.owner_name})
		Protocol.T_RELEASE:
			release_claim(uid)
		Protocol.T_NICKNAME:
			var wanted := Protocol.clean_nickname(str(msg.get("name", "")))
			if wanted == "" or wanted == r.user.name:
				return
			var was: String = r.user.name
			r.user.name = wanted
			broadcast({"type": Protocol.T_SYSTEM,
				"text": "%s is now known as %s." % [was, wanted]})
			log.emit("%s renamed to %s." % [was, wanted])
			roster_changed.emit(get_roster())
			broadcast({"type": Protocol.T_ROSTER, "roster": get_roster()})
			_publish_claims()   # the claims map carries names too
		Protocol.T_SNAPSHOT_ACCEPT:
			clear_manifest_deadline(uid)
			snapshot_accepted.emit(uid)
		Protocol.T_SNAPSHOT_DECLINE:
			clear_manifest_deadline(uid)
			var u = find_user(uid)
			log.emit("%s declined the project transfer." % (str(u.name) if u else uid))
			snapshot_declined.emit(uid)
		Protocol.T_HANDOVER:
			# Ask whoever holds this file to hand it over. The owner decides.
			var want_path := str(msg.get("path", ""))
			var holder := owner_of(want_path)
			if holder == -1:
				return
			var asker = find_user(uid)
			var note := {"type": Protocol.T_HANDOVER, "path": want_path,
				"from_name": str(asker.name) if asker else "Someone"}
			if holder == 0:
				handover_requested.emit(want_path, str(asker.name) if asker else "Someone")
			else:
				send_to(holder, note)
		Protocol.T_PING:
			send_to(uid, {"type": Protocol.T_PONG})
		Protocol.T_PONG:
			pass

func _do_handshake(r: Dictionary, msg: Dictionary) -> void:
	var proto := int(msg.get("protocol", -1))
	if proto != Protocol.PROTOCOL_VERSION:
		r.ws.send_text(Protocol.stringify({"type": Protocol.T_REJECT,
			"reason": "Protocol mismatch (host v%d, you v%d). Update the plugin." %
			[Protocol.PROTOCOL_VERSION, proto]}))
		_schedule_close(r, "protocol")
		return
	if _code != "" and str(msg.get("code", "")) != _code:
		r.ws.send_text(Protocol.stringify({"type": Protocol.T_REJECT,
			"reason": "Wrong session code."}))
		_schedule_close(r, "code")
		return

	# Scene/resource text formats differ between engine minor versions. We do
	# not refuse the connection -- scripts and assets are still fine -- but both
	# sides are told loudly, because syncing scenes across versions can produce
	# files the other editor cannot open.
	var peer_engine := str(msg.get("engine", "?"))
	var my_engine := Protocol.engine_version()
	var mismatch := not Protocol.versions_compatible(peer_engine, my_engine)

	var id := _next_id
	_next_id += 1
	var uname := str(msg.get("name", "Guest %d" % id))
	r.user = {
		"id": id, "name": uname, "color": Protocol.color_for_id(id),
		"role": _default_role, "scene": "", "selection": [],
		"active_at": Time.get_ticks_msec(),
	}
	# Welcome the newcomer with their identity and the full roster.
	r.ws.send_text(Protocol.stringify({
		"type": Protocol.T_WELCOME, "id": id, "role": _default_role,
		"color": r.user.color, "roster": get_roster(),
		"engine": my_engine, "engine_mismatch": mismatch,
		"project": Protocol.project_fingerprint(),
	}))
	if mismatch:
		var warning := ("%s is running Godot %s but this session is Godot %s. "
			+ "Scenes and resources may not open correctly on both sides.") % [
			uname, peer_engine, my_engine]
		log.emit(warning)
		send_to(id, {"type": Protocol.T_SYSTEM, "text": warning})
		broadcast({"type": Protocol.T_SYSTEM, "text": warning}, id)
	log.emit("%s joined (id %d)." % [uname, id])
	peer_joined.emit(r.user)          # plugin sends the project snapshot next
	# Tell everyone (including the newcomer) about the updated roster + notice.
	broadcast({"type": Protocol.T_SYSTEM, "text": "%s joined the session." % uname})
	roster_changed.emit(get_roster())
	broadcast({"type": Protocol.T_ROSTER, "roster": get_roster()})

func _schedule_close(r: Dictionary, reason: String) -> void:
	# Flush for a few polls (so the reject frame reaches the client) then close.
	r["close_in"] = 8
	r["close_reason"] = reason

func _drop(r: Dictionary) -> void:
	_records.erase(r)
	if r.user != null:
		# Free whatever file they were primary on so others can take it.
		release_claim(r.user.id)
		log.emit("%s left." % r.user.name)
		peer_left.emit(r.user)
		broadcast({"type": Protocol.T_SYSTEM, "text": "%s left the session." % r.user.name})
		roster_changed.emit(get_roster())
		broadcast({"type": Protocol.T_ROSTER, "roster": get_roster()})
