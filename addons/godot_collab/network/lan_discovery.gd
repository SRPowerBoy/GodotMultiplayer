@tool
extends RefCounted
## Automatic LAN discovery over UDP broadcast.
##
## The host broadcasts a small JSON beacon a few times a second; anyone on the
## same network listening on the discovery port sees the session appear in their
## dock without typing an IP. The beacon deliberately carries NO session code --
## discovery tells you a session exists, joining it still requires the code.

signal hosts_changed(hosts: Array)

const Protocol := preload("res://addons/godot_collab/network/protocol.gd")

# -- broadcasting (host side) ---------------------------------------------

var _bcast: PacketPeerUDP
var _beacon := {}
var _last_beacon := 0
var _beacon_due := true   # send the first beacon on the very next poll

## `discovery_port` may be overridden so several editors on one machine (or a
## test) can use separate beacon channels -- a single UDP port cannot be shared
## reliably between two processes.
func start_broadcasting(session_name: String, port: int, player_count: int,
		discovery_port: int = Protocol.DISCOVERY_PORT) -> void:
	stop_broadcasting()
	_bcast = PacketPeerUDP.new()
	_bcast.set_broadcast_enabled(true)
	# Destination is the global broadcast address; every LAN peer listening on
	# the discovery port receives it.
	_bcast.set_dest_address("255.255.255.255", discovery_port)
	_beacon = {
		"magic": Protocol.DISCOVERY_MAGIC,
		"name": session_name,
		"port": port,
		"players": player_count,
	}
	_last_beacon = 0
	_beacon_due = true

func update_beacon(player_count: int) -> void:
	if not _beacon.is_empty() and _beacon.get("players") != player_count:
		_beacon["players"] = player_count
		_beacon_due = true   # push the change out right away, don't wait a cycle

func stop_broadcasting() -> void:
	if _bcast:
		_bcast.close()
		_bcast = null
	_beacon.clear()

func poll_broadcast() -> void:
	if _bcast == null or _beacon.is_empty():
		return
	var now := Time.get_ticks_msec()
	if not _beacon_due and now - _last_beacon < Protocol.DISCOVERY_INTERVAL:
		return
	_beacon_due = false
	_last_beacon = now
	_bcast.put_packet(Protocol.stringify(_beacon).to_utf8_buffer())

# -- listening (client side) ----------------------------------------------

var _listen: PacketPeerUDP
var _found := {}      # "ip:port" -> {ip, port, name, players, last_seen}

func start_listening(discovery_port: int = Protocol.DISCOVERY_PORT) -> String:
	stop_listening()
	_listen = PacketPeerUDP.new()
	var err := _listen.bind(discovery_port)
	if err != OK:
		_listen = null
		return "Could not bind discovery port %d (error %d)." % [discovery_port, err]
	_found.clear()
	return ""

func stop_listening() -> void:
	if _listen:
		_listen.close()
		_listen = null
	_found.clear()

func poll_listen() -> void:
	if _listen == null:
		return
	var dirty := false
	while _listen.get_available_packet_count() > 0:
		var text := _listen.get_packet().get_string_from_utf8()
		var ip := _listen.get_packet_ip()
		var msg = Protocol.parse(text)
		if msg == null or str(msg.get("magic", "")) != Protocol.DISCOVERY_MAGIC:
			continue
		var port := int(msg.get("port", Protocol.DEFAULT_PORT))
		var key := "%s:%d" % [ip, port]
		var entry := {
			"ip": ip, "port": port,
			"name": str(msg.get("name", "Session")),
			"players": int(msg.get("players", 1)),
			"last_seen": Time.get_ticks_msec(),
		}
		if not _found.has(key) or _found[key].players != entry.players \
				or _found[key].name != entry.name:
			dirty = true
		_found[key] = entry

	# Expire hosts that stopped beaconing.
	var now := Time.get_ticks_msec()
	for key in _found.keys():
		if now - int(_found[key].last_seen) > Protocol.DISCOVERY_EXPIRY:
			_found.erase(key)
			dirty = true

	if dirty:
		hosts_changed.emit(get_hosts())

func get_hosts() -> Array:
	var out: Array = []
	for key in _found:
		out.append(_found[key].duplicate())
	out.sort_custom(func(a, b): return str(a.name) < str(b.name))
	return out
