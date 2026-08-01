@tool
extends RefCounted
## Durable session record: what happened, and what was said.
##
## Both live in user:// so they are per-machine and never sync back into the
## project. Each is trimmed so a long-running session cannot grow without bound.

## Logs are per-project. A single shared file meant joining a session on one
## project replayed chat from a completely different one.
const MAX_LINES := 500

static func _project_key() -> String:
	return ProjectSettings.globalize_path("res://").to_lower().md5_text().substr(0, 12)

static func activity_path() -> String:
	return "user://godot_collab_%s_activity.log" % _project_key()

static func chat_path() -> String:
	return "user://godot_collab_%s_chat.log" % _project_key()

static func _append(path: String, line: String) -> void:
	var lines := read(path)
	lines.append(line)
	# Keep only the tail once we exceed the cap.
	if lines.size() > MAX_LINES:
		lines = lines.slice(lines.size() - MAX_LINES, lines.size())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	for l in lines:
		f.store_line(str(l))
	f.close()

static func read(path: String) -> Array:
	var out: Array = []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	while not f.eof_reached():
		var line := f.get_line()
		if line != "":
			out.append(line)
	f.close()
	return out

static func stamp() -> String:
	return Time.get_datetime_string_from_system(false, true).replace("T", " ")

## Record something that happened (joins, edits, claims, restores).
static func activity(text: String) -> void:
	_append(activity_path(), "[%s] %s" % [stamp(), text])

static func read_activity(limit: int = 200) -> Array:
	var lines := read(activity_path())
	if lines.size() > limit:
		lines = lines.slice(lines.size() - limit, lines.size())
	return lines

## Record a chat line so history survives a restart.
static func chat(user_name: String, color: String, text: String) -> void:
	# Tab-separated; the message is always the last field, so tabs inside it
	# are harmless.
	_append(chat_path(), "%s\t%s\t%s\t%s" % [stamp(), user_name, color, text])

## Parsed chat history, most recent `limit` entries:
## [{stamp, name, color, text}]
static func read_chat(limit: int = 50) -> Array:
	var out: Array = []
	var lines := read(chat_path())
	if lines.size() > limit:
		lines = lines.slice(lines.size() - limit, lines.size())
	for line in lines:
		var parts := str(line).split("\t")
		if parts.size() >= 4:
			var rest := PackedStringArray(Array(parts).slice(3))
			out.append({
				"stamp": parts[0],
				"name": parts[1],
				"color": parts[2],
				"text": "\t".join(rest),
			})
	return out

static func clear_all() -> void:
	for p in [activity_path(), chat_path()]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
