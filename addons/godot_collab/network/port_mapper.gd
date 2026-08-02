@tool
extends RefCounted
## Optional UPnP port forwarding so a host can be reached from the internet
## without configuring the router by hand.
##
## This is best-effort by design: many routers have UPnP disabled, and plenty of
## networks (university, corporate, mobile) will never work. Discovery is slow
## and blocking, so it runs on a thread and the session never waits for it.

signal finished(success: bool, external_ip: String, message: String)

## Mappings are leased so they expire on their own if the router will not let
## us delete them. Refreshed well before expiry while a session is running.
const LEASE_SECONDS := 3600
const REFRESH_AFTER := 2700.0     # renew at 45 minutes
const MAPPING_NAME := "GodotCollab"

var _thread: Thread
var _upnp: UPNP
var _port := 0
var _mapped := false
var _permanent := false           # router only supports non-expiring mappings
var _since_refresh := 0.0

func is_mapped() -> bool:
	return _mapped

## Kick off discovery + mapping in the background. Safe to call and ignore.
func map_port_async(port: int) -> void:
	if _thread != null:
		return
	_port = port
	_thread = Thread.new()
	_thread.start(_worker)

func _worker() -> void:
	_upnp = UPNP.new()
	var discover := _upnp.discover()
	if discover != UPNP.UPNP_RESULT_SUCCESS:
		call_deferred("_done", false, "", "No UPnP router found (code %d)." % discover)
		return
	var gateway := _upnp.get_gateway()
	if gateway == null or not gateway.is_valid_gateway():
		call_deferred("_done", false, "", "Router does not support UPnP forwarding.")
		return
	# TCP only: the collaboration socket is WebSocket over TCP.
	#
	# Always ask for a LEASED mapping rather than a permanent one. Plenty of
	# routers happily accept AddPortMapping but reject DeletePortMapping, and a
	# permanent mapping we cannot delete would leave the port open forever. A
	# lease expires on its own, so the worst case is self-healing. We refresh it
	# while the session is alive (see poll()).
	var res := _upnp.add_port_mapping(_port, _port, MAPPING_NAME, "TCP", LEASE_SECONDS)
	if res == UPNP.UPNP_RESULT_ONLY_PERMANENT_LEASE_SUPPORTED:
		# Older routers only support permanent mappings; take it, but remember
		# that expiry will not save us if delete also fails.
		_permanent = true
		res = _upnp.add_port_mapping(_port, _port, MAPPING_NAME, "TCP", 0)
	if res != UPNP.UPNP_RESULT_SUCCESS:
		call_deferred("_done", false, "", "Router refused the port mapping (code %d)." % res)
		return
	call_deferred("_done", true, _upnp.query_external_address(),
		"Port %d forwarded." % _port)

func _done(success: bool, external_ip: String, message: String) -> void:
	_mapped = success
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	# The session ended while we were still discovering -- undo immediately.
	if _unmap_wanted:
		_release_mapping()
		return
	finished.emit(success, external_ip, message)

## Remove the mapping again. Called when the session ends.
##
## Discovery can take many seconds, so we never block the editor waiting for it:
## if the worker is still running we just flag the intent and let _done() clean
## up when it finishes.
var _unmap_wanted := false

func unmap() -> void:
	if _thread != null and _thread.is_alive():
		_unmap_wanted = true
		return
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	_release_mapping()

## Renew the lease so a long session does not lose its forwarding. Cheap and
## safe to call every frame; it only acts once the interval has elapsed.
func poll(delta: float) -> void:
	if not _mapped or _permanent or _upnp == null:
		return
	_since_refresh += delta
	if _since_refresh < REFRESH_AFTER:
		return
	_since_refresh = 0.0
	_upnp.add_port_mapping(_port, _port, MAPPING_NAME, "TCP", LEASE_SECONDS)

## True when the mapping could not be removed and is not on a lease -- the only
## case where something is left open after the session ends.
var left_open := false

func _release_mapping() -> void:
	left_open = false
	if _upnp != null and _mapped:
		var res := _upnp.delete_port_mapping(_port, "TCP")
		if res != UPNP.UPNP_RESULT_SUCCESS:
			# Some routers accept AddPortMapping but refuse to delete. The lease
			# will clear it; a permanent mapping will not, so say so.
			left_open = _permanent
	_mapped = false
	_upnp = null
	_unmap_wanted = false
