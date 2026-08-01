@tool
extends RefCounted
## Aggregates every collaborator's presence (current scene + selected nodes).
##
## Godot's editor exposes no reliable way to draw another user's live mouse
## cursor over the 2D/3D viewport, so "collaborator cursors" are realised as
## selection presence: for each user we know their color, the scene they are
## in, and the node they have selected. The dock renders this as annotations
## such as "Alex is editing Player" next to the user list.

signal updated()

# user_id -> {name, color, scene, selection:Array}
var remote := {}

func clear() -> void:
	remote.clear()
	updated.emit()

## Seed from a full roster (used on join and on roster refresh).
func sync_roster(roster: Array, exclude_id: int) -> void:
	var seen := {}
	for u in roster:
		var id := int(u.get("id", -1))
		seen[id] = true
		if id == exclude_id:
			continue
		remote[id] = {
			"name": str(u.get("name", "?")),
			"color": str(u.get("color", "#ffffff")),
			"scene": str(u.get("scene", "")),
			"selection": u.get("selection", []),
		}
	# Forget anyone no longer in the roster.
	for id in remote.keys():
		if not seen.has(id):
			remote.erase(id)
	updated.emit()

func apply(user_id: int, data: Dictionary) -> void:
	var entry: Dictionary = remote.get(user_id, {})
	entry["name"] = str(data.get("name", entry.get("name", "?")))
	entry["color"] = str(data.get("color", entry.get("color", "#ffffff")))
	entry["scene"] = str(data.get("scene", ""))
	entry["selection"] = data.get("selection", [])
	remote[user_id] = entry
	updated.emit()

func remove(user_id: int) -> void:
	if remote.erase(user_id):
		updated.emit()

## Short human label for what a user is doing, e.g. "editing res://player.tscn ▸ Enemy".
func describe(user_id: int) -> String:
	var e = remote.get(user_id)
	if e == null:
		return ""
	var scene := str(e.get("scene", ""))
	if scene == "":
		return "idle"
	var label := scene.get_file()
	var sel: Array = e.get("selection", [])
	if sel.size() > 0:
		label += " ▸ " + str(sel[0])
		if sel.size() > 1:
			label += " (+%d)" % (sel.size() - 1)
	return label
