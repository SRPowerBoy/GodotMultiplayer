@tool
extends RefCounted
## Optional UPnP port forwarding so a host can be reached from the internet
## without configuring the router by hand.
##
## This is best-effort by design: many routers have UPnP disabled, and plenty of
## networks (university, corporate, mobile) will never work. Discovery is slow
## and blocking, so it runs on a thread and the session never waits for it.

signal finished(success: bool, external_ip: String, message: String)

var _thread: Thread
var _upnp: UPNP
var _port := 0
var _mapped := false

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
	var res := _upnp.add_port_mapping(_port, _port, "GodotCollab", "TCP", 0)
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

func _release_mapping() -> void:
	if _upnp != null and _mapped:
		_upnp.delete_port_mapping(_port, "TCP")
	_mapped = false
	_upnp = null
	_unmap_wanted = false
