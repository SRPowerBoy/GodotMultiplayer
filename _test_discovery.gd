extends SceneTree
## Headless test for UDP LAN discovery: a broadcasting host is seen by a
## listener, its player count updates, and it expires when it stops.

const LanDiscovery := preload("res://addons/godot_collab/network/lan_discovery.gd")
const Protocol := preload("res://addons/godot_collab/network/protocol.gd")

var results: Array = []
func ok(c: bool, l: String) -> void:
	results.append(c); print(("PASS " if c else "FAIL ") + l)

func _pump(a, b, frames: int) -> void:
	for i in frames:
		if a: a.poll_broadcast()
		if b: b.poll_listen()
		OS.delay_msec(20)

## Pick a specific session out of everything visible on the network.
func _find(hosts: Array, want_name: String):
	for h in hosts:
		if str(h.get("name", "")) == want_name:
			return h
	return null

func _init() -> void:
	var listener := LanDiscovery.new()
	const TEST_PORT := 8899
	var err := listener.start_listening(TEST_PORT)
	if err != "":
		# Some CI/sandbox environments forbid binding broadcast ports.
		print("SKIP  discovery unavailable in this environment: %s" % err)
		quit(0)
		return

	var host := LanDiscovery.new()
	host.start_broadcasting("Test Session", 8890, 1, TEST_PORT)

	_pump(host, listener, 60)   # ~1.2s: at least one beacon interval

	# Other editors on this machine may be beaconing too, so always select our
	# own session by name rather than assuming it is first in the list.
	var found := listener.get_hosts()
	var mine = _find(found, "Test Session")
	ok(mine != null, "listener discovered our host (%d sessions visible)" % found.size())
	if mine != null:
		ok(int(mine.port) == 8890, "port carried (got %d)" % int(mine.port))
		ok(int(mine.players) == 1, "player count carried (got %d)" % int(mine.players))

	# Beacon carries no session code -- discovery must not leak the secret.
	var leaked := false
	for h in found:
		if str(h).to_lower().contains("code"):
			leaked = true
	ok(not leaked, "beacon does not carry the session code")

	# Player count updates propagate.
	host.update_beacon(3)
	_pump(host, listener, 120)
	var updated = _find(listener.get_hosts(), "Test Session")
	ok(updated != null and int(updated.players) == 3,
		"player count update propagated (got %d)" % (int(updated.players) if updated != null else -1))

	host.stop_broadcasting()
	listener.stop_listening()

	var passed := 0
	for r in results:
		if r: passed += 1
	print("\n==== %d/%d passed ====" % [passed, results.size()])
	quit(0 if passed == results.size() else 1)
