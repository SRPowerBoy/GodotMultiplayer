@tool
extends VBoxContainer
## Built-in session chat with join/leave notices.

signal submitted(text: String)

var _log: RichTextLabel
var _entry: LineEdit

func _ready() -> void:
	var header := Label.new()
	header.text = "Chat"
	header.add_theme_font_size_override("font_size", 12)
	header.modulate = Color(1, 1, 1, 0.6)
	add_child(header)

	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_active = true
	_log.scroll_following = true
	_log.selection_enabled = true
	# Keep this modest: the dock lives in a ScrollContainer, and a tall minimum
	# here would push the editor's bottom panel out of the layout.
	_log.custom_minimum_size = Vector2(0, 90)
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.add_theme_constant_override("line_separation", 2)
	add_child(_log)

	var row := HBoxContainer.new()
	add_child(row)
	_entry = LineEdit.new()
	_entry.placeholder_text = "Message…"
	_entry.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_entry.text_submitted.connect(_on_submit)
	row.add_child(_entry)
	var send := Button.new()
	send.text = "Send"
	send.pressed.connect(func(): _on_submit(_entry.text))
	row.add_child(send)

func _on_submit(text: String) -> void:
	var t := text.strip_edges()
	if t == "":
		return
	_entry.clear()
	submitted.emit(t)

func add_line(user_name: String, color: String, text: String) -> void:
	_log.append_text("[color=%s]%s[/color]: %s\n" % [color, _esc(user_name), _esc(text)])

func add_system(text: String) -> void:
	_log.append_text("[color=#8a8f98][i]%s[/i][/color]\n" % _esc(text))

func clear() -> void:
	_log.clear()

func set_enabled(enabled: bool) -> void:
	_entry.editable = enabled

func _esc(s: String) -> String:
	return s.replace("[", "[lb]")
