@tool
extends EditorPlugin
## Godot Collab Host — peer-hosted real-time collaboration.
##
## The session creator's editor becomes the authoritative server. This script
## is the glue: it owns the dock, the host server / client connection, the file
## watcher and the presence trackers, and routes messages between them.

const Protocol := preload("res://addons/godot_collab/network/protocol.gd")
const HostServer := preload("res://addons/godot_collab/network/host_server.gd")
const ClientConnection := preload("res://addons/godot_collab/network/client_connection.gd")
const FileSync := preload("res://addons/godot_collab/sync/file_sync.gd")
const SelectionSync := preload("res://addons/godot_collab/presence/selection_sync.gd")
const CursorSync := preload("res://addons/godot_collab/presence/cursor_sync.gd")
const LanDiscovery := preload("res://addons/godot_collab/network/lan_discovery.gd")
const FocusTracker := preload("res://addons/godot_collab/presence/focus_tracker.gd")
const ReconnectPolicy := preload("res://addons/godot_collab/network/reconnect_policy.gd")
const BackupStore := preload("res://addons/godot_collab/sync/backup_store.gd")
const SessionLog := preload("res://addons/godot_collab/sync/session_log.gd")
const PortMapper := preload("res://addons/godot_collab/network/port_mapper.gd")
const CollabPanel := preload("res://addons/godot_collab/ui/collab_panel.gd")

enum Mode { IDLE, HOST, CLIENT }

var _mode: int = Mode.IDLE
var _panel                 # CollabPanel (VBoxContainer)
var _host: HostServer
var _client: ClientConnection
var _files: FileSync
var _selection: SelectionSync
var _cursors: CursorSync

var _my_id := -1
var _roster: Array = []
var _self_data := {"scene": "", "selection": []}
var _client_versions := {}   # path -> int (client-side authoritative mirror)
var _host_ip := ""
var _host_port := Protocol.DEFAULT_PORT
var _session_code := ""
var _snapshot_queues := {}   # peer id -> {paths:Array, index:int, total:int}
var _pending_manifests := {} # peer id -> paths awaiting their review
var _discovery: LanDiscovery
var _focus: FocusTracker
var _ports: PortMapper
var _bottom_button: Button
# Ownership state: my current primary file and the session-wide claim map.
var _my_primary := ""        # path I am allowed to edit ("" = none)
var _focused := ""           # file I am currently looking at
var _claims := {}            # path -> {id, name, color}
var _pending_claim := ""     # claim request awaiting a host reply
var _discovery_port := Protocol.DISCOVERY_PORT
var _external_ip := ""
var _incoming_total := 0     # snapshot size announced by the host (client side)
var _incoming_count := 0

# -- lifecycle -------------------------------------------------------------

func _enter_tree() -> void:
	_host = HostServer.new()
	_client = ClientConnection.new()
	_files = FileSync.new()
	_selection = SelectionSync.new()
	_cursors = CursorSync.new()
	_discovery = LanDiscovery.new()
	_focus = FocusTracker.new()
	_ports = PortMapper.new()
	_ports.finished.connect(_on_port_mapping)
	_focus.focus_changed.connect(_on_focus_changed)

	_panel = CollabPanel.new()
	_panel.name = "Godot Collab"
	# Bottom bar: wide and short, alongside Output/Debugger.
	_bottom_button = add_control_to_bottom_panel(_panel, "Godot Collab")

	# Panel intents
	_panel.host_requested.connect(_on_host_requested)
	_panel.join_requested.connect(_on_join_requested)
	_panel.disconnect_requested.connect(_on_disconnect_requested)
	_panel.chat_submitted.connect(_on_chat_submitted)
	_panel.open_backups_requested.connect(_on_open_backups)
	_panel.self_test_requested.connect(_on_self_test)
	_panel.kick_requested.connect(_on_kick_requested)
	_panel.role_change_requested.connect(_on_role_change_requested)
	_panel.take_file_requested.connect(_on_take_file)
	_panel.release_file_requested.connect(_on_release_file)
	_panel.handover_requested.connect(_on_request_handover)
	_panel.deletes_confirmed.connect(_on_deletes_confirmed)
	_panel.discovery_port_changed.connect(_on_discovery_port_changed)
	_panel.manifest_accepted.connect(_on_manifest_accepted)
	_panel.manifest_declined.connect(_on_manifest_declined)
	_panel.restore_requested.connect(_on_restore_requested)
	_panel.clear_backups_requested.connect(_on_clear_backups)
	_panel.new_code_requested.connect(_on_new_code)
	_panel.jump_to_user_requested.connect(_on_jump_to_user)
	_panel.nickname_changed.connect(_on_nickname_changed)

	# LAN discovery: hosts advertise, idle editors listen.
	_discovery.hosts_changed.connect(func(hosts): _panel.update_discovered(hosts))

	# Local edits + presence
	_files.local_change.connect(_on_local_change)
	_files.local_delete.connect(_on_local_delete)
	_files.deferred_write.connect(_on_deferred_write)
	_files.deferred_applied.connect(_on_deferred_applied)
	_files.file_too_large.connect(_on_file_too_large)
	_files.local_rename.connect(_on_local_rename)
	# Scan on demand instead of polling the whole project constantly.
	var efs := EditorInterface.get_resource_filesystem()
	if efs != null:
		efs.filesystem_changed.connect(func(): _files.request_scan())
	_selection.changed.connect(_on_self_presence)
	_cursors.updated.connect(_refresh_roster)

	# Host events
	_host.log.connect(_log)
	_host.roster_changed.connect(_on_roster_changed)
	_host.peer_joined.connect(_on_peer_joined)
	_host.chat.connect(_on_host_chat)
	_host.presence.connect(_on_remote_presence)
	_host.client_file_change.connect(_on_client_file_change)
	_host.client_file_delete.connect(_on_host_client_delete)
	_host.claims_changed.connect(_on_claims_updated)
	_host.handover_requested.connect(_on_handover_asked)
	_host.snapshot_accepted.connect(_on_snapshot_accepted)
	_host.snapshot_declined.connect(_on_snapshot_declined)

	# Client events
	_client.opened.connect(_on_client_opened)
	_client.closed.connect(_on_client_closed)
	_client.welcomed.connect(_on_client_welcomed)
	_client.rejected.connect(_on_client_rejected)
	_client.connect_failed.connect(_on_connect_failed)
	_client.roster_updated.connect(_on_client_roster)
	_client.chat.connect(func(n, c, t):
		SessionLog.chat(str(n), str(c), str(t))
		_panel.chat_line(n, c, t))
	_client.system.connect(func(t): _panel.chat_system(t))
	_client.presence.connect(_on_client_presence_msg)
	_client.file_update.connect(_on_client_file_update)
	_client.file_delete.connect(_on_client_file_delete_msg)
	_client.file_rejected.connect(_on_client_file_rejected)
	_client.role_changed.connect(_on_my_role_changed)
	_client.kicked.connect(_on_kicked)
	_client.manifest.connect(_on_manifest)
	_client.snapshot_begin.connect(_on_snapshot_begin)
	_client.snapshot_end.connect(_on_snapshot_end)
	_client.claim_result.connect(_on_claim_result)
	_client.claims_updated.connect(_on_claims_updated)
	_client.handover_requested.connect(_on_handover_asked)
	_client.log.connect(_log)

	_load_settings()
	_start_discovery_listening()
	set_process(true)

func _exit_tree() -> void:
	_teardown()
	if _discovery:
		_discovery.stop_broadcasting()
		_discovery.stop_listening()
	if _panel:
		remove_control_from_bottom_panel(_panel)
		_panel.free()
		_panel = null
	_bottom_button = null

func _process(delta: float) -> void:
	match _mode:
		Mode.IDLE:
			_discovery.poll_listen()      # show nearby sessions in the dock
		Mode.HOST:
			_host.poll(delta)
			_files.poll(delta)
			_selection.poll(delta)
			_focus.poll(delta)
			_pump_snapshots()
			_tick_delete_prompt(delta)
			_tick_stats(delta)
			_discovery.poll_broadcast()   # advertise this session on the LAN
			_ports.poll(delta)            # keep the UPnP lease alive
		Mode.CLIENT:
			_tick_reconnect(delta)
			_tick_delete_prompt(delta)
			_tick_stats(delta)
			_client.poll(delta)
			_files.poll(delta)
			_selection.poll(delta)
			_focus.poll(delta)

# -- hosting ---------------------------------------------------------------

func _on_host_requested(user_name: String, port: int, default_role: String) -> void:
	if _mode != Mode.IDLE:
		return
	if user_name == "":
		user_name = "Host"
	_session_code = _generate_code()
	_host_ip = _local_ip()
	_host_port = port
	_host.bytes_in = 0
	_host.bytes_out = 0
	_host.load_state()   # keep file versions stable across host restarts
	var err := _host.start(port, user_name, _session_code, default_role)
	if err != "":
		_panel.set_status("Host failed: " + err)
		return
	_mode = Mode.HOST
	_my_id = 0
	_files.start()
	_selection.start()
	_focus.start()
	_apply_session_editor_settings()
	_roster = _host.get_roster()
	_cursors.clear()
	_save_settings({"name": user_name, "port": port, "role": default_role})
	# Stop listening for other sessions; start advertising ours instead.
	_discovery.stop_listening()
	_discovery.start_broadcasting("%s's project" % user_name, port, 1, _discovery_port)
	_panel.set_mode_hosting(_session_code, _host_ip, port)
	_panel.set_status("Hosting. Share the IP + code with your collaborators.")
	_panel.chat_system("Session started. You are the host.")
	SessionLog.activity("Started hosting on port %d." % port)
	_ports.map_port_async(port)
	_restore_chat_history()
	_refresh_roster()

func _on_peer_joined(user: Dictionary) -> void:
	# Queue the whole project for the newcomer. Sending it all in one frame
	# would blow past the socket buffer on a real project, so the queue is
	# drained a few files per frame in _process.
	var id := int(user.id)
	# Tell them what we are about to send and let them review it. Nothing is
	# transferred until they accept.
	var paths := _files.collect_all()
	_pending_manifests[id] = paths
	# Send hashes too, so the joiner can tell a real overwrite from a file that
	# already matches.
	_host.send_to(id, {"type": Protocol.T_MANIFEST, "paths": paths,
		"hashes": _files.hash_manifest()})
	_host.expect_manifest_reply(id)
	_panel.chat_system("%s is reviewing the project (%d files)…" % [user.name, paths.size()])

func _on_snapshot_accepted(id: int) -> void:
	var paths: Array = _pending_manifests.get(id, [])
	_pending_manifests.erase(id)
	if paths.is_empty():
		paths = _files.collect_all()
	_host.send_to(id, {"type": Protocol.T_SNAPSHOT_BEGIN})
	_snapshot_queues[id] = {"paths": paths, "index": 0, "total": paths.size()}
	var u = _host.find_user(id)
	_panel.chat_system("Sending project to %s (%d files)…"
		% [str(u.name) if u else id, paths.size()])

func _on_snapshot_declined(id: int) -> void:
	_pending_manifests.erase(id)
	var u = _host.find_user(id)
	_panel.chat_system("%s declined the project transfer and left."
		% (str(u.name) if u else id))
	_host.kick_user(id, "You declined the project transfer.")

# Files pushed per frame during a snapshot. Small enough to stay responsive,
# large enough that a few-thousand-file project transfers in seconds.
const SNAPSHOT_FILES_PER_FRAME := 6

func _pump_snapshots() -> void:
	if _snapshot_queues.is_empty():
		return
	for id in _snapshot_queues.keys():
		var q: Dictionary = _snapshot_queues[id]
		# Peer vanished mid-transfer.
		if not _host.is_peer_open(id):
			_snapshot_queues.erase(id)
			continue
		var sent := 0
		while sent < SNAPSHOT_FILES_PER_FRAME and q.index < q.paths.size():
			var path: String = q.paths[q.index]
			q.index += 1
			sent += 1
			var v := _host.get_version(path)
			if v == 0:
				v = _host.bump_version(path)   # first reference -> version 1
			var msg := {
				"type": Protocol.T_FILE_UPDATE, "path": path,
				"version": v, "source": "host",
			}
			msg.merge(Protocol.encode_payload(_files.read_bytes(path)))
			_host.send_to(id, msg)
		if q.index >= q.paths.size():
			_host.send_to(id, {"type": Protocol.T_SNAPSHOT_END, "total": q.total})
			_snapshot_queues.erase(id)
			var u = _host.find_user(id)
			if u:
				_panel.chat_system("%s is fully synced (%d files)." % [u.name, q.total])
		else:
			_panel.set_status("Sending project… %d/%d files" % [q.index, q.total])

func _on_client_file_change(uid: int, path: String, base_version: int, bytes: PackedByteArray) -> void:
	if _mode != Mode.HOST:
		return
	# A resync request: resend the authoritative copy.
	if base_version == -999:
		_host.send_to(uid, _authoritative_msg(path))
		return
	var cur := _host.get_version(path)
	if base_version == cur:
		var v := _host.bump_version(path)
		_files.apply_remote(path, bytes, v)     # write to host disk (echo-muted)
		var user = _host.find_user(uid)
		var src := str(user.name) if user else "?"
		var msg := {"type": Protocol.T_FILE_UPDATE, "path": path,
			"version": v, "source": src}
		msg.merge(Protocol.encode_payload(bytes))
		_host.broadcast(msg)
		_panel.set_status("Applied %s from %s (v%d)." % [path.get_file(), src, v])
	else:
		# Conflict: reject and force the client back to the authoritative copy.
		_host.send_to(uid, {"type": Protocol.T_FILE_REJECT, "path": path,
			"your_version": base_version, "host_version": cur})
		_host.send_to(uid, _authoritative_msg(path))

func _authoritative_msg(path: String) -> Dictionary:
	var msg := {
		"type": Protocol.T_FILE_UPDATE, "path": path,
		"version": _host.get_version(path), "source": "host",
	}
	msg.merge(Protocol.encode_payload(_files.read_bytes(path)))
	return msg

func _on_host_chat(user_id: int, text: String) -> void:
	var u = _host.find_user(user_id)
	if u:
		SessionLog.chat(str(u.name), str(u.color), text)
		_panel.chat_line(u.name, u.color, text)

func _on_roster_changed(roster: Array) -> void:
	_roster = roster
	_cursors.sync_roster(roster, _my_id)
	if _mode == Mode.HOST:
		_discovery.update_beacon(roster.size())
	_refresh_roster()

# -- file ownership ("primary") -------------------------------------------
# You may hold exactly one primary file. Switching files moves the claim; if
# someone already holds the file you switched to, you become view-only on it.

func _on_focus_changed(path: String) -> void:
	if _mode == Mode.IDLE:
		return
	_focused = path
	# Never try to claim our own addon or an untracked file.
	if path == "" or FileSync.is_excluded(path):
		_set_primary("")
		_refresh_primary_banner()
		return
	match _mode:
		Mode.HOST:
			var res := _host.claim_file(0, path)
			if res.granted:
				_set_primary(path)
			else:
				_set_primary("")
				_panel.chat_system("%s is the primary of %s — you are view-only here."
					% [res.owner_name, path.get_file()])
			_refresh_primary_banner()
		Mode.CLIENT:
			if _client.my_role == Protocol.ROLE_VIEWER:
				_set_primary("")
				_refresh_primary_banner()
				return
			_pending_claim = path
			_client.send({"type": Protocol.T_CLAIM, "path": path})

func _on_claim_result(path: String, granted: bool, owner_name: String) -> void:
	if path != _focused:
		return   # we already moved on
	_pending_claim = ""
	if granted:
		_set_primary(path)
	else:
		_set_primary("")
		_panel.chat_system("%s is the primary of %s — you are view-only here."
			% [owner_name, path.get_file()])
	_refresh_primary_banner()

func _set_primary(path: String) -> void:
	_my_primary = path
	# Lock the script editor when we do not own the script we are looking at.
	if _focused != "" and _focused.get_extension().to_lower() == "gd":
		FocusTracker.set_script_readonly(path != _focused)

func _on_claims_updated(claims: Dictionary) -> void:
	_claims = claims
	# The claims map is authoritative, so always re-derive our own primary from
	# it. The host can assign us a file we never explicitly asked for (editing
	# an unclaimed file auto-claims it), and that arrives only via this map.
	var mine := ""
	for path in _claims:
		if int(_claims[path].get("id", -1)) == _my_id:
			mine = path
			break
	if mine != _my_primary:
		_set_primary(mine)
	_refresh_primary_banner()
	_refresh_roster()

func _refresh_primary_banner() -> void:
	if _mode == Mode.IDLE or _panel == null:
		return
	if _focused == "":
		_panel.set_primary_state("", false, "", _my_primary)
		return
	var owned := _my_primary == _focused
	var owner_name := ""
	if not owned:
		var entry = _claims.get(_focused)
		owner_name = str(entry.name) if entry != null else "another collaborator"
	_panel.set_primary_state(_focused, owned, owner_name, _my_primary)

## True when we are allowed to publish changes for `path`.
func _may_edit(path: String) -> bool:
	return path == _my_primary

# -- manual claim control --------------------------------------------------

func _on_take_file() -> void:
	if _mode == Mode.IDLE or _focused == "":
		return
	match _mode:
		Mode.HOST:
			var res := _host.claim_file(0, _focused)
			if res.granted:
				_set_primary(_focused)
				_panel.set_status("You are now primary of %s." % _focused.get_file())
			else:
				_panel.set_status("%s still holds %s." % [res.owner_name, _focused.get_file()])
			_refresh_primary_banner()
		Mode.CLIENT:
			_client.send({"type": Protocol.T_CLAIM, "path": _focused})

func _on_release_file() -> void:
	if _my_primary == "":
		return
	var was := _my_primary
	match _mode:
		Mode.HOST:
			_host.release_claim(0)
		Mode.CLIENT:
			_client.send({"type": Protocol.T_RELEASE})
	_set_primary("")
	_panel.set_status("Released %s." % was.get_file())
	_refresh_primary_banner()

func _on_request_handover() -> void:
	if _focused == "" or _may_edit(_focused):
		return
	match _mode:
		Mode.HOST:
			var holder := _host.owner_of(_focused)
			if holder > 0:
				_host.send_to(holder, {"type": Protocol.T_HANDOVER, "path": _focused,
					"from_name": str(_host.host_user.name)})
				_panel.set_status("Asked for %s." % _focused.get_file())
		Mode.CLIENT:
			_client.send({"type": Protocol.T_HANDOVER, "path": _focused})
			_panel.set_status("Asked for %s." % _focused.get_file())

## Someone wants the file we are holding.
func _on_handover_asked(path: String, from_name: String) -> void:
	_panel.chat_system("%s is asking for %s — press Release to hand it over."
		% [from_name, path.get_file()])
	_panel.set_status("%s wants %s." % [from_name, path.get_file()])

# -- moderation (host only) ------------------------------------------------

func _on_kick_requested(user_id: int) -> void:
	if _mode == Mode.HOST and user_id != 0:
		_host.kick_user(user_id)
		_snapshot_queues.erase(user_id)

func _on_role_change_requested(user_id: int, role: String) -> void:
	if _mode == Mode.HOST and user_id != 0:
		_host.set_user_role(user_id, role)

func _on_my_role_changed(role: String) -> void:
	_panel.chat_system("The host changed your role to %s." % role)
	_panel.set_status("Your role is now: %s." % role)

func _on_kicked(reason: String) -> void:
	_panel.set_status("Removed from the session: %s" % reason)
	_panel.chat_system("You were removed from the session (%s)." % reason)

# -- joining ---------------------------------------------------------------

func _on_join_requested(ip: String, port: int, user_name: String, code: String) -> void:
	# The panel only offers a Join button while it believes we are disconnected,
	# so getting here in another mode means the two disagree. Never return
	# silently -- that turns the button into a dead control with no explanation.
	if _mode == Mode.HOST:
		_panel.set_status("You are hosting. End your session before joining another.")
		_panel.show_notice("Already hosting",
			"You are currently hosting a session on this computer.",
			["Press End Session first, then join."],
			"Nothing was changed.")
		return
	if _mode == Mode.CLIENT:
		# Stale client state (an attempt that never finished). Recover and
		# continue with what the user actually asked for.
		_log("Join requested while still in CLIENT mode - clearing stale session.")
		_leaving = true
		_teardown()
	if user_name == "":
		user_name = "Guest"
	if ip == "":
		_panel.set_status("Enter the host's IP address.")
		return
	if _host != null and _host.running and port == _host_port:
		_panel.set_status("You are hosting on that port — end your session first.")
		return
	_host_ip = ip
	_host_port = port
	_session_code = code
	var err := _client.connect_to_host(ip, port, user_name, code)
	if err != "":
		_panel.set_status("Join failed: " + err)
		return
	_client.bytes_in = 0
	_client.bytes_out = 0
	_mode = Mode.CLIENT
	_leaving = false
	_reconnect.reset()
	_last_join = {"ip": ip, "port": port, "name": user_name, "code": code}
	_discovery.stop_listening()
	_save_settings({"name": user_name, "join_ip": ip, "join_port": port})
	_panel.set_status("Connecting to %s:%d…" % [ip, port])

func _on_client_opened() -> void:
	_panel.set_status("Connected. Waiting for the host…")

func _on_client_welcomed(id: int, role: String, color: String, roster: Array) -> void:
	# Two editors on ONE folder are the same files: syncing them is meaningless
	# and destructive. Detect it and stop before anything is written.
	if _client.host_project != "" and _client.host_project == Protocol.project_fingerprint():
		_panel.set_status("Refused — that session is hosting THIS same project folder.")
		_panel.show_notice("Cannot join this session",
			"The host is using this exact project folder on this computer.",
			[
				"Both editors would be reading and writing the same files.",
				"Nothing has been changed on disk.",
			],
			"To test on one machine, make a second copy of the project and open "
			+ "that copy in the other editor. On two machines this does not "
			+ "happen at all.")
		_leaving = true
		_client.disconnect_from_host()
		_teardown()
		return

	var was_reconnecting := _reconnect.on_connected()
	if was_reconnecting:
		_panel.chat_system("Reconnected.")
	_my_id = id
	_roster = roster
	# Only reset the version mirror on a FRESH join. Wiping it on reconnect made
	# the next edit to every file arrive as base_version 0 and get rejected.
	if not was_reconnecting:
		_client_versions.clear()
	_cursors.sync_roster(roster, id)
	_files.start()            # baseline local files; snapshot writes are echo-muted
	_selection.start()
	_focus.start()
	_apply_session_editor_settings()
	_panel.set_mode_client(_host_ip, _host_port, _session_code)
	_panel.set_status("Joined as %s (%s)." % [roster_name(id), role])
	_panel.chat_system("You joined the session as %s." % role)
	SessionLog.activity("Joined %s:%d as %s." % [_host_ip, _host_port, role])
	_restore_chat_history()
	_flush_offline_queue()
	_refresh_roster()

func roster_name(id: int) -> String:
	for u in _roster:
		if int(u.get("id", -1)) == id:
			return str(u.get("name", "you"))
	return "you"

func _on_client_roster(roster: Array) -> void:
	_roster = roster
	_cursors.sync_roster(roster, _my_id)
	_refresh_roster()

func _on_client_presence_msg(data: Dictionary) -> void:
	_cursors.apply(int(data.get("user_id", -1)), data)

## A remote update arrived for the scene the user is standing in. We hold it
## rather than yanking the file out from under them.
func _on_deferred_write(path: String) -> void:
	_panel.set_status("Update for %s held — close or switch scenes to apply it."
		% path.get_file())
	_panel.chat_system("An update to %s is waiting until you leave that scene."
		% path.get_file())

func _on_deferred_applied(path: String) -> void:
	_panel.set_status("Applied the held update to %s." % path.get_file())

## The host has told us what it wants to send. Compare it against this project
## and let the user see exactly what would be overwritten before we accept.
func _on_manifest(paths: Array, hashes: Dictionary) -> void:
	var overwrites: Array = []
	var additions: Array = []
	var identical := 0
	for p in paths:
		var path := str(p)
		if FileSync.is_excluded(path):
			continue
		if not FileAccess.file_exists(path):
			additions.append(path)
			continue
		# A file we already have byte-for-byte is not an overwrite -- saying so
		# would make an already-synced project look catastrophic.
		var theirs := str(hashes.get(path, ""))
		if theirs != "" and theirs == _files.hash_of(path):
			identical += 1
			continue
		overwrites.append(path)
	overwrites.sort()
	additions.sort()
	_panel.set_status("Reviewing %d incoming file(s)…" % paths.size())
	_panel.show_manifest(overwrites, additions, identical)

func _on_manifest_accepted() -> void:
	if _mode == Mode.CLIENT:
		_client.send({"type": Protocol.T_SNAPSHOT_ACCEPT})
		_panel.set_status("Receiving the project…")

func _on_manifest_declined() -> void:
	if _mode != Mode.CLIENT:
		return
	_client.send({"type": Protocol.T_SNAPSHOT_DECLINE})
	_leaving = true                      # a decline is deliberate: do not retry
	_panel.chat_system("You declined the transfer. Nothing was changed.")
	_panel.set_status("Declined — your project was left untouched.")
	_teardown()

# -- backups ---------------------------------------------------------------

## Delete backups. `path` empty means all of them.
func _on_clear_backups(path: String) -> void:
	var removed := BackupStore.clear_all() if path == "" else BackupStore.clear_for(path)
	var what := "all backups" if path == "" else "backups of %s" % path.get_file()
	_panel.set_status("Deleted %d backup file(s)." % removed)
	if _mode != Mode.IDLE:
		_panel.chat_system("Cleared %s (%d file(s))." % [what, removed])
	SessionLog.activity("Cleared %s (%d files)." % [what, removed])
	# Refresh the browser so it reflects what is actually left.
	_panel.show_backups(BackupStore.list_all(), BackupStore.total_size())

func _on_restore_requested(backup_file: String) -> void:
	var err := BackupStore.restore(backup_file)
	if err != "":
		_panel.set_status("Restore failed: " + err)
		return
	var meta := BackupStore.parse_name(backup_file)
	var path := str(meta.get("path", ""))
	_panel.set_status("Restored %s from backup." % path.get_file())
	_panel.chat_system("Restored %s from a backup (the previous contents were "
		% path.get_file() + "saved too, so this is reversible).")
	# Let the editor notice, and share it if we are allowed to.
	if _files:
		_files.request_scan()

func _on_snapshot_begin() -> void:
	_incoming_count = 0
	_panel.set_status("Receiving project from the host…")

func _on_snapshot_end(total: int) -> void:
	_incoming_total = total
	_panel.set_status("Project synced (%d files). You're live." % _incoming_count)
	_panel.chat_system("Project received — %d files in sync." % _incoming_count)

## Surface remote changes that touch what the user is working on, rather than
## letting files silently change under them.
func _notify_relevant_change(path: String, source: String) -> void:
	if path == _focused:
		_panel.chat_system("%s updated %s — the file you have open."
			% [source, path.get_file()])
	elif path == _my_primary:
		_panel.chat_system("%s updated %s, which you hold." % [source, path.get_file()])

func _on_client_file_update(path: String, bytes: PackedByteArray, version: int) -> void:
	if bytes.is_empty() and version > 0 and not FileAccess.file_exists(path):
		# A payload that failed to decompress would otherwise truncate the file.
		_log("Skipped corrupt payload for %s" % path)
		return
	_files.apply_remote(path, bytes, version)
	_client_versions[path] = version
	_incoming_count += 1
	# Only chatter about files the user actually cares about, and never during
	# the initial bulk transfer.
	if _incoming_total > 0:
		_notify_relevant_change(path, "Someone")

func _on_client_file_rejected(path: String, your_version: int, host_version: int) -> void:
	_panel.chat_system("Your change to %s was rejected (you had v%d, host has v%d). Reloading the latest." %
		[path.get_file(), your_version, host_version])

## The connect attempt never completed. Say why, and say it where it will be
## seen -- a status line on an unfocused tab is not enough after an 8s wait.
func _on_connect_failed(reason: String) -> void:
	_leaving = true          # a failed first connect must not start retrying
	_panel.set_status("Could not connect.")
	_panel.show_notice("Could not connect", reason,
		[
			"Check the host has clicked Host Session and is still running.",
			"Check the IP and port match what the host is showing.",
			"Over the internet the host needs their EXTERNAL address, not a "
			+ "192.168.x or 10.x one.",
		],
		"Nothing on this computer was changed.")
	_teardown()

func _on_client_rejected(reason: String) -> void:
	_panel.set_status("Rejected: " + reason)
	_panel.chat_system("Connection rejected: " + reason)
	_teardown()

func _on_client_closed() -> void:
	if _mode != Mode.CLIENT:
		_teardown()
		return
	# A deliberate exit (kick, or we pressed Leave) must not reconnect.
	_reconnect.deliberate = _client.was_kicked or _leaving
	if _reconnect.on_disconnected():
		_begin_reconnect()
	else:
		if not _reconnect.deliberate:
			_panel.set_status("Lost connection to the host — gave up after %d attempts."
				% ReconnectPolicy.MAX_ATTEMPTS)
			_panel.chat_system("Could not reconnect. Session ended.")
		else:
			_panel.set_status("Disconnected.")
		_teardown()

# -- reconnect -------------------------------------------------------------
# The decision logic lives in ReconnectPolicy so it can be tested headlessly.

var _reconnect := ReconnectPolicy.new()
var _last_join := {}
var _leaving := false        # true when the user chose to disconnect

func _begin_reconnect() -> void:
	_files.stop()
	_selection.stop()
	_focus.stop()
	_panel.set_status("Connection lost — reconnecting in %.0fs (attempt %d/%d)…"
		% [_reconnect.delay_left, _reconnect.attempt, ReconnectPolicy.MAX_ATTEMPTS])
	_panel.chat_system("Connection lost. Retrying…")

func _tick_reconnect(delta: float) -> void:
	if not _reconnect.tick(delta):
		return
	var j := _last_join
	if j.is_empty():
		_teardown()
		return
	_panel.set_status("Reconnecting to %s:%d…" % [j.ip, j.port])
	var err := _client.connect_to_host(str(j.ip), int(j.port), str(j.name), str(j.code))
	if err != "":
		if _reconnect.on_disconnected():
			_begin_reconnect()
		else:
			_teardown()

# -- shared: local edits + presence ---------------------------------------

## Edits made while the connection is down are remembered and replayed once we
## are back, instead of being silently lost.
var _offline_queue := {}   # path -> true

func _queue_offline(path: String) -> void:
	_offline_queue[path] = true
	_panel.set_status("Offline — %d change(s) will be sent when you reconnect."
		% _offline_queue.size())

func _flush_offline_queue() -> void:
	if _offline_queue.is_empty():
		return
	var paths := _offline_queue.keys()
	_offline_queue.clear()
	var sent := 0
	var blocked: Array = []
	for path in paths:
		if not FileAccess.file_exists(path):
			continue
		# Someone else may have taken the file while we were away.
		var holder = _claims.get(path)
		if holder != null and int(holder.get("id", -1)) != _my_id:
			blocked.append(str(path))
			continue
		# Re-read from disk: what matters is the current content, not whatever
		# it was when the connection dropped.
		_on_local_change(str(path), _files.read_bytes(str(path)))
		sent += 1
	if sent > 0:
		_panel.chat_system("Sent %d change(s) made while you were disconnected." % sent)
	if not blocked.is_empty():
		_panel.chat_system("%d offline change(s) were NOT sent — someone else now "
			% blocked.size() + "holds those files: %s"
			% ", ".join(PackedStringArray(blocked)))

## A rename shows up as "old path gone, identical new path appeared". Sending
## it as delete+add (rather than a scary delete confirmation) keeps everyone in
## step without prompting.
func _on_local_rename(from_path: String, to_path: String) -> void:
	if _mode == Mode.IDLE:
		return
	if FileSync.is_excluded(from_path) or FileSync.is_excluded(to_path):
		return
	SessionLog.activity("Renamed %s -> %s" % [from_path, to_path])
	_panel.chat_system("Renamed %s to %s." % [from_path.get_file(), to_path.get_file()])
	# The new file was already published by the normal change path; we only need
	# to retire the old one.
	_publish_delete(from_path)

func _on_file_too_large(path: String, size: int) -> void:
	_panel.chat_system("%s is %.1f MB and was NOT synced (limit %.0f MB)."
		% [path.get_file(), size / 1048576.0, FileSync.MAX_SYNC_BYTES / 1048576.0])

func _on_local_change(path: String, bytes: PackedByteArray) -> void:
	# Disconnected client: stash it rather than dropping it.
	if _mode == Mode.CLIENT and not _client.connected:
		_queue_offline(path)
		return
	# Publish only files you may write. Someone else's primary is never sent,
	# which keeps traffic to what you actually edited and stops two editors
	# ping-ponging the same file. An *unclaimed* file is fair game -- editing it
	# is what makes you its primary.
	if not _may_edit(path):
		var holder = _claims.get(path)
		if holder != null:
			_panel.set_status("Not shared — %s is the primary of %s."
				% [str(holder.name), path.get_file()])
			return
		# Unclaimed: take it by editing it.
		if _mode == Mode.HOST:
			if not _host.claim_file(0, path).granted:
				return
		_set_primary(path)
	if _mode == Mode.HOST:
		_host.touch_claim(0)
	match _mode:
		Mode.HOST:
			var v := _host.bump_version(path)
			_files.backup(path, v)
			var msg := {"type": Protocol.T_FILE_UPDATE, "path": path,
				"version": v, "source": "host"}
			msg.merge(Protocol.encode_payload(bytes))
			_host.broadcast(msg)
			_panel.set_status("Shared %s (v%d)." % [path.get_file(), v])
		Mode.CLIENT:
			if _client.my_role == Protocol.ROLE_VIEWER:
				return
			var base := int(_client_versions.get(path, 0))
			var out := {"type": Protocol.T_FILE_CHANGE, "path": path,
				"base_version": base}
			out.merge(Protocol.encode_payload(bytes))
			_client.send(out)

## Local deletions are queued and confirmed before they hit anyone else --
## an accidental delete would otherwise propagate instantly and irreversibly.
func _on_local_delete(path: String) -> void:
	if _mode == Mode.IDLE or FileSync.is_excluded(path):
		return
	# Never propagate a delete of a file someone else holds.
	var holder = _claims.get(path)
	if holder != null and int(holder.get("id", -1)) != _my_id:
		return
	if not _delete_queue.has(path):
		_delete_queue.append(path)
	_delete_prompt_in = 0.6   # coalesce a burst of deletes into one prompt

var _delete_queue: Array = []
var _delete_prompt_in := 0.0

func _tick_delete_prompt(delta: float) -> void:
	if _delete_prompt_in <= 0.0:
		return
	_delete_prompt_in -= delta
	if _delete_prompt_in > 0.0 or _delete_queue.is_empty():
		return
	var batch := _delete_queue.duplicate()
	_delete_queue.clear()
	_offline_queue.clear()
	_panel.confirm_deletes(batch)

func _on_deletes_confirmed(paths: Array) -> void:
	for path in paths:
		_publish_delete(str(path))

func _publish_delete(path: String) -> void:
	match _mode:
		Mode.HOST:
			_host.bump_version(path)
			_host.broadcast({"type": Protocol.T_FILE_DELETE, "path": path, "source": "host"})
			_panel.set_status("Removed %s (synced)." % path.get_file())
		Mode.CLIENT:
			if _client.my_role == Protocol.ROLE_VIEWER:
				return
			_client.send({"type": Protocol.T_FILE_DELETE, "path": path})

# Host received a delete from a client: apply it and fan out to everyone else.
func _on_host_client_delete(uid: int, path: String) -> void:
	if _mode != Mode.HOST:
		return
	_host.bump_version(path)
	_files.apply_remote_delete(path)   # backs up, removes, echo-muted
	_host.broadcast({"type": Protocol.T_FILE_DELETE, "path": path, "source": "peer"}, uid)
	_panel.set_status("Removed %s (from a collaborator)." % path.get_file())

func _on_client_file_delete_msg(path: String) -> void:
	_files.apply_remote_delete(path)
	_client_versions.erase(path)

func _on_self_presence(data: Dictionary) -> void:
	_self_data = data
	match _mode:
		Mode.HOST:
			_host.host_user.scene = data.scene
			_host.host_user.selection = data.selection
			_host.broadcast({"type": Protocol.T_PRESENCE, "user_id": 0,
				"name": _host.host_user.name, "color": _host.host_user.color,
				"scene": data.scene, "selection": data.selection})
			_refresh_roster()
		Mode.CLIENT:
			_client.send({"type": Protocol.T_PRESENCE,
				"scene": data.scene, "selection": data.selection})

func _on_remote_presence(user_id: int, data: Dictionary) -> void:
	_cursors.apply(user_id, data)

# -- roster rendering ------------------------------------------------------

func _refresh_roster() -> void:
	if _mode == Mode.IDLE:
		return
	var entries: Array = []
	for u in _roster:
		var id := int(u.get("id", -1))
		var is_self := id == _my_id
		var activity := _self_activity() if is_self else _cursors.describe(id)
		# Which file this person currently holds as primary.
		var primary := ""
		for path in _claims:
			if int(_claims[path].get("id", -1)) == id:
				primary = path
				break
		entries.append({
			"id": id,
			"name": u.get("name", "?"), "color": u.get("color", "#ffffff"),
			"role": u.get("role", "editor"), "is_self": is_self,
			"activity": activity, "primary": primary,
			"idle_for": _idle_seconds(u),
		})
	_panel.update_roster(entries, _mode == Mode.HOST)

## Seconds since this user last did something, or -1 when unknown.
## Only meaningful on the host, which is where activity is stamped.
func _idle_seconds(u: Dictionary) -> int:
	var at := int(u.get("active_at", 0))
	if at <= 0 or _mode != Mode.HOST:
		return -1
	return int((Time.get_ticks_msec() - at) / 1000.0)

func _self_activity() -> String:
	var scene := str(_self_data.get("scene", ""))
	if scene == "":
		return "idle"
	var label := scene.get_file()
	var sel: Array = _self_data.get("selection", [])
	if sel.size() > 0:
		label += " ▸ " + str(sel[0])
	return label

# -- teardown / misc -------------------------------------------------------

func _on_disconnect_requested() -> void:
	_leaving = true
	_teardown()

func _teardown() -> void:
	if _host and _host.running:
		_host.save_state()
		_host.stop()
	if _client:
		_client.disconnect_from_host()
	if _files:
		_files.stop()
	if _selection:
		_selection.stop()
	if _focus:
		_focus.stop()
	if _cursors:
		_cursors.clear()
	if _discovery:
		_discovery.stop_broadcasting()
	if _ports:
		_ports.unmap()
		if _ports.left_open and _panel:
			_panel.chat_system("Note: your router would not remove the port "
				+ "forwarding for port %d and does not support expiring leases. "
				% _host_port
				+ "Remove it from your router's UPnP list if you want it closed.")
	_mode = Mode.IDLE
	_my_id = -1
	_roster.clear()
	_client_versions.clear()
	_snapshot_queues.clear()
	_delete_queue.clear()
	_delete_prompt_in = 0.0
	_reconnect.reset()
	_leaving = false
	_last_join.clear()
	_my_primary = ""
	_focused = ""
	_claims.clear()
	_pending_claim = ""
	FocusTracker.set_script_readonly(false)   # never leave the editor locked
	_restore_editor_settings()
	_incoming_total = 0
	_incoming_count = 0
	if _panel:
		_panel.set_mode_disconnected()
		_panel.set_status("Not connected.")
	_start_discovery_listening()   # go back to watching for nearby sessions

func _start_discovery_listening() -> void:
	if _discovery == null:
		return
	var err := _discovery.start_listening(_discovery_port)
	if err != "":
		# Not fatal: another editor on this machine may already hold the port.
		_log("LAN discovery unavailable — " + err)

func _on_chat_submitted(text: String) -> void:
	match _mode:
		Mode.HOST:
			SessionLog.chat(str(_host.host_user.name), str(_host.host_user.color), text)
			_panel.chat_line(_host.host_user.name, _host.host_user.color, text)
			_host.broadcast({"type": Protocol.T_CHAT, "user_id": 0,
				"name": _host.host_user.name, "color": _host.host_user.color, "text": text})
		Mode.CLIENT:
			SessionLog.chat(roster_name(_my_id), _client.my_color, text)
			_panel.chat_line(roster_name(_my_id), _client.my_color, text)
			_client.send({"type": Protocol.T_CHAT, "text": text})

func _on_discovery_port_changed(port: int) -> void:
	_discovery_port = port
	_save_settings({"discovery_port": port})
	if _mode == Mode.IDLE:
		_start_discovery_listening()   # rebind on the new channel immediately

## #14 Rotate the join code. Existing collaborators are unaffected.
func _on_new_code() -> void:
	if _mode != Mode.HOST:
		return
	_session_code = _generate_code()
	_host.set_code(_session_code)
	_panel.set_mode_hosting(_session_code, _host_ip, _host_port)
	if _external_ip != "":
		_panel.set_external_invite(Protocol.make_invite(
			_external_ip, _host_port, _session_code))
	_panel.chat_system("New session code: %s (the old one no longer works)." % _session_code)

## #23 Open whatever file a collaborator is working in.
func _on_jump_to_user(user_id: int) -> void:
	var target := ""
	# Prefer the file they hold, fall back to the scene they are viewing.
	for path in _claims:
		if int(_claims[path].get("id", -1)) == user_id:
			target = path
			break
	if target == "":
		var entry = _cursors.remote.get(user_id)
		if entry != null:
			target = str(entry.get("scene", ""))
	if target == "" or not FileAccess.file_exists(target):
		_panel.set_status("That person is not in a file that exists here yet.")
		return
	var ext := target.get_extension().to_lower()
	if ext == "tscn" or ext == "scn":
		EditorInterface.open_scene_from_path(target)
	else:
		var res := load(target)
		if res is Script:
			EditorInterface.edit_script(res)
		else:
			EditorInterface.select_file(target)
	_panel.set_status("Jumped to %s." % target.get_file())

## Change the name everyone else sees, mid-session or before connecting.
func _on_nickname_changed(new_name: String) -> void:
	var clean := Protocol.clean_nickname(new_name)
	if clean == "":
		return
	_save_settings({"name": clean})
	_panel.set_nickname(clean)
	match _mode:
		Mode.HOST:
			_host.set_host_name(clean)
			_panel.set_status("You are now known as %s." % clean)
		Mode.CLIENT:
			_client.send({"type": Protocol.T_NICKNAME, "name": clean})
			_panel.set_status("Asked the host to call you %s." % clean)
		_:
			# Not connected yet: just remember it for the next session.
			_panel.set_status("Nickname saved — you will join as %s." % clean)

func _on_open_backups() -> void:
	var abs := ProjectSettings.globalize_path(FileSync.BACKUP_DIR)
	if not DirAccess.dir_exists_absolute(abs):
		DirAccess.make_dir_recursive_absolute(abs)
	_panel.show_backups(BackupStore.list_all(), BackupStore.total_size())

var _stats_in := 0.0

func _tick_stats(delta: float) -> void:
	_stats_in -= delta
	if _stats_in > 0.0:
		return
	_stats_in = 0.5
	match _mode:
		Mode.HOST:
			_panel.set_stats(_host.bytes_out, _host.bytes_in, -1)
		Mode.CLIENT:
			_panel.set_stats(_client.bytes_out, _client.bytes_in, _client.latency_ms)

## Replay recent chat so a session does not start with an empty window.
## UPnP result. Success upgrades the invite link to the internet-reachable
## address; failure is informational only -- LAN play is unaffected.
func _on_port_mapping(success: bool, external_ip: String, message: String) -> void:
	if _mode != Mode.HOST:
		return
	_external_ip = external_ip if success else ""
	if success and external_ip != "":
		_panel.chat_system("Internet access ready — external address %s. %s"
			% [external_ip, message])
		_panel.set_external_invite(Protocol.make_invite(
			external_ip, _host_port, _session_code))
		SessionLog.activity("UPnP mapped port %d (external %s)." % [_host_port, external_ip])
	else:
		_panel.chat_system("Internet forwarding unavailable (%s). LAN play still works."
			% message)

func _restore_chat_history() -> void:
	var history := SessionLog.read_chat(25)
	if history.is_empty():
		return
	_panel.chat_system("— %d earlier message(s) —" % history.size())
	for entry in history:
		_panel.chat_line(str(entry.name), str(entry.color), str(entry.text))

func _log(text: String) -> void:
	print("[Collab] ", text)

# -- editor settings while a session is live -------------------------------
# Collaboration means files change on disk constantly. Godot would otherwise
# prompt "this file was modified externally, reload?" for every incoming edit,
# which is unusable. We flip auto-reload on for the duration of the session and
# put the user's own preference back afterwards.

const AUTO_RELOAD_SETTING := "text_editor/behavior/files/auto_reload_scripts_on_external_change"

var _saved_auto_reload = null

func _apply_session_editor_settings() -> void:
	if not Engine.is_editor_hint():
		return
	var es := EditorInterface.get_editor_settings()
	if es == null or not es.has_setting(AUTO_RELOAD_SETTING):
		return
	if _saved_auto_reload == null:
		_saved_auto_reload = es.get_setting(AUTO_RELOAD_SETTING)
		# Persist it: if the editor crashes mid-session we can still put the
		# user's own preference back the next time the plugin loads.
		_save_settings({"saved_auto_reload": _saved_auto_reload, "session_dirty": true})
	es.set_setting(AUTO_RELOAD_SETTING, true)

func _restore_editor_settings() -> void:
	if not Engine.is_editor_hint() or _saved_auto_reload == null:
		return
	var es := EditorInterface.get_editor_settings()
	if es != null and es.has_setting(AUTO_RELOAD_SETTING):
		es.set_setting(AUTO_RELOAD_SETTING, _saved_auto_reload)
	_saved_auto_reload = null
	_save_settings({"session_dirty": false})

# -- settings persistence --------------------------------------------------

const SETTINGS_PATH := "user://godot_collab.cfg"

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	_discovery_port = int(cfg.get_value("collab", "discovery_port", Protocol.DISCOVERY_PORT))
	# A previous session that ended in a crash may have left an editor
	# setting flipped. Put it back before doing anything else.
	if bool(cfg.get_value("collab", "session_dirty", false)):
		_saved_auto_reload = cfg.get_value("collab", "saved_auto_reload", false)
		_restore_editor_settings()
		_log("Restored an editor setting left over from an interrupted session.")
	_panel.set_nickname(str(cfg.get_value("collab", "name", "")))
	_panel.set_defaults({
		"name": cfg.get_value("collab", "name", ""),
		"port": int(cfg.get_value("collab", "port", Protocol.DEFAULT_PORT)),
		"role": cfg.get_value("collab", "role", Protocol.ROLE_EDITOR),
		"join_ip": cfg.get_value("collab", "join_ip", "127.0.0.1"),
		"join_port": int(cfg.get_value("collab", "join_port", Protocol.DEFAULT_PORT)),
		"discovery_port": int(cfg.get_value("collab", "discovery_port", Protocol.DISCOVERY_PORT)),
	})

func _save_settings(values: Dictionary) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)  # keep any existing keys
	for k in values:
		cfg.set_value("collab", k, values[k])
	cfg.save(SETTINGS_PATH)

# -- in-editor self-test ---------------------------------------------------
# Spins up a loopback host + client on an ephemeral port and verifies the full
# handshake without needing a second machine. Only runs while disconnected.

func _on_self_test() -> void:
	if _mode != Mode.IDLE:
		_panel.set_status("Finish the current session before self-testing.")
		return
	_panel.set_status("Self-test: starting loopback host + client…")
	_run_self_test()

func _run_self_test() -> void:
	# Walks the WHOLE join sequence, not just the handshake, and reports which
	# step fails. "Joining does not work" is otherwise impossible to narrow down
	# without two machines.
	var steps: Array = []
	var port := 20000 + (randi() % 20000)

	var host := HostServer.new()
	var err := host.start(port, "SelfTestHost", "SELF-TEST")
	steps.append(["Host starts listening", err == "", err])
	if err != "":
		_report_self_test(steps)
		return

	var client := ClientConnection.new()
	var got := {
		"welcomed": false, "rejected": "", "failed": "",
		"manifest": -1, "snapshot": false, "files": 0, "done": -1,
	}
	client.welcomed.connect(func(_i, _r, _c, _ro): got.welcomed = true)
	client.rejected.connect(func(r): got.rejected = r)
	client.connect_failed.connect(func(r): got.failed = r)
	client.manifest.connect(func(paths, _h):
		got.manifest = paths.size()
		# Answer exactly as the review dialog would.
		client.send({"type": Protocol.T_SNAPSHOT_ACCEPT}))
	client.snapshot_begin.connect(func(): got.snapshot = true)
	client.file_update.connect(func(_p, _b, _v): got.files += 1)
	client.snapshot_end.connect(func(total): got.done = total)

	# Host side: mirror what the real session does on join.
	host.peer_joined.connect(func(u):
		var paths := _files.collect_all() if _files else []
		host.send_to(int(u.id), {"type": Protocol.T_MANIFEST,
			"paths": paths, "hashes": _files.hash_manifest() if _files else {}}))
	host.snapshot_accepted.connect(func(uid):
		host.send_to(uid, {"type": Protocol.T_SNAPSHOT_BEGIN})
		host.send_to(uid, {"type": Protocol.T_SNAPSHOT_END, "total": 0}))

	client.connect_to_host("127.0.0.1", port, "SelfTestClient", "SELF-TEST")

	var deadline := Time.get_ticks_msec() + 12000
	while Time.get_ticks_msec() < deadline:
		host.poll(0.016)
		client.poll(0.016)
		if got.done >= 0 or got.rejected != "" or got.failed != "":
			break
		await get_tree().process_frame

	steps.append(["Client reaches the host", got.failed == "", got.failed])
	steps.append(["Handshake accepted", got.welcomed,
		got.rejected if got.rejected != "" else "no welcome received"])
	steps.append(["Project manifest sent", got.manifest >= 0,
		"host never sent the file list"])
	steps.append(["Transfer starts after accept", got.snapshot,
		"host did not begin sending after the client accepted"])
	steps.append(["Transfer completes", got.done >= 0,
		"snapshot never finished"])

	client.disconnect_from_host()
	host.stop()
	_report_self_test(steps)

## steps: [[label, ok, failure_detail], ...]
func _report_self_test(steps: Array) -> void:
	var bullets: Array = []
	var failed := ""
	for st in steps:
		var mark := "OK  " if st[1] else "FAIL"
		bullets.append("%s  %s" % [mark, st[0]])
		if not st[1] and failed == "":
			failed = "%s - %s" % [st[0], st[2]]
	if failed == "":
		_panel.set_status("Self-test passed - joining works on this machine.")
		_panel.show_notice("Self-test passed",
			"Every step of the join sequence completed locally.", bullets,
			"If joining still fails between two machines, the problem is the "
			+ "network path (address, port, or firewall) rather than the plugin.")
	else:
		_panel.set_status("Self-test failed at: %s" % failed)
		_panel.show_notice("Self-test failed",
			"The join sequence stopped at: %s" % failed, bullets,
			"This ran entirely on this computer, so a failure here is the "
			+ "plugin or this Godot install - not your network.")

func _generate_code() -> String:
	var letters := "ABCDEFGHJKLMNPQRSTUVWXYZ"
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var a := ""
	for i in 4:
		a += letters[rng.randi_range(0, letters.length() - 1)]
	return "%s-%04d" % [a, rng.randi_range(0, 9999)]

func _local_ip() -> String:
	var best := "127.0.0.1"
	for addr in IP.get_local_addresses():
		if not addr.contains("."):   # skip IPv6
			continue
		if addr.begins_with("127."):
			continue
		if addr.begins_with("192.168.") or addr.begins_with("10.") or _is_172_private(addr):
			return addr
		best = addr
	return best

func _is_172_private(addr: String) -> bool:
	if not addr.begins_with("172."):
		return false
	var parts := addr.split(".")
	if parts.size() < 2:
		return false
	var second := int(parts[1])
	return second >= 16 and second <= 31
