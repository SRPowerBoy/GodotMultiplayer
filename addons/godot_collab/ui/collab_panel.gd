@tool
extends VBoxContainer
## The "Godot Collab" bottom panel. Pure code UI so the plugin never has to
## sync its own scene files. Emits intent signals; the plugin does the work.
##
## Three tabs -- Session, People, Chat -- each laid out vertically at the full
## width of the panel. Side-by-side columns were too cramped in the bottom bar;
## tabs give each section the whole width and scroll independently, so the panel
## still never demands vertical space from the rest of the editor.

signal host_requested(user_name: String, port: int, default_role: String)
signal join_requested(ip: String, port: int, user_name: String, code: String)
signal disconnect_requested()
signal chat_submitted(text: String)
signal open_backups_requested()
signal self_test_requested()
signal kick_requested(user_id: int)
signal role_change_requested(user_id: int, role: String)
signal take_file_requested()
signal release_file_requested()
signal handover_requested()
signal discovery_port_changed(port: int)
signal deletes_confirmed(paths: Array)
signal manifest_accepted()
signal manifest_declined()
signal restore_requested(backup_file: String)
signal clear_backups_requested(path: String)   # "" means every backup
signal new_code_requested()
signal jump_to_user_requested(user_id: int)
signal nickname_changed(new_name: String)

const Protocol := preload("res://addons/godot_collab/network/protocol.gd")
const ChatPanel := preload("res://addons/godot_collab/ui/chat_panel.gd")

const C_IDLE := Color("#8a8f98")
const C_LIVE := Color("#57d977")
const C_WAIT := Color("#f4c445")
const PANEL_HEIGHT := 200

# status
var _dot: Label
var _status: Label
var _primary_lbl: Label
var _stats: Label
var _take_btn: Button
var _release_btn: Button
var _request_btn: Button
var _discovery_port: SpinBox
var _delete_warning: ConfirmationDialog
var _pending_deletes: Array = []
var _manifest_dialog: ConfirmationDialog
var _backup_dialog: AcceptDialog
var _backup_list: VBoxContainer
var _clear_backups_dialog: ConfirmationDialog
var _notice_dialog: AcceptDialog
var _pending_clear := ""
var _new_code_btn: Button
var _tabs: TabContainer
var _nickname: LineEdit
var _external_row: HBoxContainer
var _external_value: LineEdit
# columns / containers
var _forms: VBoxContainer
var _session_box: VBoxContainer
# session widgets
var _invite_value: LineEdit
var _code_value: Label
var _players: VBoxContainer
var _disconnect_btn: Button
var _chat: VBoxContainer
# host form
var _host_name: LineEdit
var _host_port: SpinBox
var _host_role: OptionButton
# join form
var _nearby: VBoxContainer
var _nearby_label: Label
var _join_invite: LineEdit
var _join_ip: LineEdit
var _join_port: SpinBox
var _join_name: LineEdit
var _join_code: LineEdit
# join confirmation
var _join_warning: ConfirmationDialog
var _pending_join := {}

func _ready() -> void:
	custom_minimum_size = Vector2(0, PANEL_HEIGHT)
	add_theme_constant_override("separation", 10)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_tabs)

	var conn_col := _make_tab("Session")
	var people_col := _make_tab("People")
	var chat_col := _make_tab("Chat")

	# --- column 1: status + connect / session ---
	var head := HBoxContainer.new()
	conn_col.add_child(head)
	_dot = Label.new()
	_dot.text = "●"
	_dot.modulate = C_IDLE
	head.add_child(_dot)
	var title := Label.new()
	title.text = "Godot Collab"
	title.add_theme_font_size_override("font_size", 14)
	head.add_child(title)

	_status = Label.new()
	_status.text = "Not connected."
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.modulate = Color(1, 1, 1, 0.75)
	_status.add_theme_font_size_override("font_size", 11)
	conn_col.add_child(_status)

	_stats = Label.new()
	_stats.text = ""
	_stats.modulate = Color(1, 1, 1, 0.45)
	_stats.add_theme_font_size_override("font_size", 10)
	conn_col.add_child(_stats)

	_build_forms(conn_col)
	_build_session_box(conn_col)

	# --- column 2: people + who owns what ---
	people_col.add_child(_section_label("Your nickname"))
	var nick_row := HBoxContainer.new()
	people_col.add_child(nick_row)
	_nickname = LineEdit.new()
	_nickname.placeholder_text = "Pick a name…"
	_nickname.max_length = Protocol.MAX_NICKNAME
	_nickname.tooltip_text = "The name everyone else sees. Takes effect immediately."
	_nickname.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_nickname.text_submitted.connect(func(t): _submit_nickname())
	nick_row.add_child(_nickname)
	var nick_btn := Button.new()
	nick_btn.text = "Set"
	nick_btn.pressed.connect(_submit_nickname)
	nick_row.add_child(nick_btn)

	people_col.add_child(_section_label("People"))
	_primary_lbl = Label.new()
	_primary_lbl.text = ""
	_primary_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_primary_lbl.add_theme_font_size_override("font_size", 11)
	people_col.add_child(_primary_lbl)

	# Manual control over the file you hold.
	var claim_row := HBoxContainer.new()
	people_col.add_child(claim_row)
	_take_btn = Button.new()
	_take_btn.text = "Take"
	_take_btn.tooltip_text = "Become the primary of the file you have open."
	_take_btn.pressed.connect(func(): take_file_requested.emit())
	claim_row.add_child(_take_btn)
	_release_btn = Button.new()
	_release_btn.text = "Release"
	_release_btn.tooltip_text = "Give up your primary so someone else can edit it."
	_release_btn.pressed.connect(func(): release_file_requested.emit())
	claim_row.add_child(_release_btn)
	_request_btn = Button.new()
	_request_btn.text = "Request"
	_request_btn.tooltip_text = "Ask the current primary to hand this file over."
	_request_btn.pressed.connect(func(): handover_requested.emit())
	claim_row.add_child(_request_btn)
	_players = VBoxContainer.new()
	people_col.add_child(_players)

	# --- column 3: chat ---
	_chat = ChatPanel.new()
	_chat.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_chat.submitted.connect(func(t): chat_submitted.emit(t))
	chat_col.add_child(_chat)

	# All dialogs are built through the same helpers so titles, sizes, wrapping
	# and button wording stay consistent with each other.
	_join_warning = _make_confirm("Join session", "Join and overwrite", "Cancel")
	_join_warning.confirmed.connect(_on_join_confirmed)

	_delete_warning = _make_confirm("Delete files", "Delete for everyone", "Keep files")
	_delete_warning.confirmed.connect(func():
		var p := _pending_deletes.duplicate()
		_pending_deletes.clear()
		deletes_confirmed.emit(p))

	_clear_backups_dialog = _make_confirm("Delete backups", "Delete backups", "Keep")
	_clear_backups_dialog.confirmed.connect(func():
		var target := _pending_clear
		_pending_clear = ""
		clear_backups_requested.emit(target))

	# Unmissable notice for things the user MUST see (a refused join, say) --
	# a status line on a tab they are not looking at is not good enough.
	_notice_dialog = AcceptDialog.new()
	_notice_dialog.title = "Godot Collab"
	_notice_dialog.dialog_autowrap = true
	_notice_dialog.min_size = Vector2i(DIALOG_WIDTH, 0)
	_notice_dialog.exclusive = false
	_apply_editor_style(_notice_dialog)
	add_child(_notice_dialog)

	_manifest_dialog = _make_confirm("Review incoming project",
		"Apply and sync", "Cancel and leave", Vector2i(DIALOG_WIDTH, 320))
	_manifest_dialog.confirmed.connect(func(): manifest_accepted.emit())
	_manifest_dialog.canceled.connect(func(): manifest_declined.emit())

	_backup_dialog = AcceptDialog.new()
	_backup_dialog.title = "Restore a backup"
	_backup_dialog.ok_button_text = "Close"
	_backup_dialog.min_size = Vector2i(DIALOG_WIDTH, 380)
	_backup_dialog.exclusive = false
	_apply_editor_style(_backup_dialog)
	add_child(_backup_dialog)
	# Godot wraps dialog content in a margin container rather than butting it
	# against the window edge.
	var backup_margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		backup_margin.add_theme_constant_override(side, 8)
	_backup_list = VBoxContainer.new()
	var backup_scroll := ScrollContainer.new()
	backup_scroll.custom_minimum_size = Vector2(0, 300)
	backup_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	backup_scroll.add_child(_backup_list)
	backup_margin.add_child(backup_scroll)
	_backup_dialog.add_child(backup_margin)

	set_mode_disconnected()

# -- dialog construction / formatting --------------------------------------
# Every dialog is built and worded the same way so they read as one product:
#   <one-line summary>
#   (blank)
#   • bulleted detail, capped and summarised when long
#   (blank)
#   <consequence note>
#   (blank)
#   <question?>

const DIALOG_WIDTH := 520
const DIALOG_MAX_BULLETS := 12

func _make_confirm(title: String, ok_text: String, cancel_text: String,
		min_size: Vector2i = Vector2i(DIALOG_WIDTH, 0)) -> ConfirmationDialog:
	var d := ConfirmationDialog.new()
	d.title = title
	d.ok_button_text = ok_text
	d.cancel_button_text = cancel_text
	d.dialog_autowrap = true
	d.min_size = min_size
	# Not exclusive: two prompts can legitimately overlap (a delete confirmation
	# arriving while the project review is open) and exclusivity would error.
	d.exclusive = false
	_apply_editor_style(d)
	add_child(d)
	return d

## Make a dialog look like one of Godot's own.
##
## The editor runs its own theme, which is NOT inherited by windows a plugin
## creates -- without this our dialogs render with the default project theme
## and look foreign next to "Save Scene As" or "Remove Node". Applying the
## editor theme picks up its fonts, colours, button styles and spacing.
func _apply_editor_style(d: Window) -> void:
	if not Engine.is_editor_hint():
		return
	var theme := EditorInterface.get_editor_theme()
	if theme != null:
		d.theme = theme
	# Godot sizes its dialogs against the editor scale, so we should too.
	var scale := EditorInterface.get_editor_scale()
	if scale > 0.0:
		d.min_size = Vector2i(d.min_size * scale)

## Compose dialog body text in the shared house style.
func _dialog_text(summary: String, bullets: Array, note: String,
		question: String) -> String:
	var out := summary + "\n"
	if not bullets.is_empty():
		out += "\n"
		for b in bullets.slice(0, DIALOG_MAX_BULLETS):
			out += "  • %s\n" % str(b)
		if bullets.size() > DIALOG_MAX_BULLETS:
			out += "  … and %d more\n" % (bullets.size() - DIALOG_MAX_BULLETS)
	if note != "":
		out += "\n" + note + "\n"
	if question != "":
		out += "\n" + question
	return out

## Strip "res://" so lists read as project-relative paths everywhere.
func _short_paths(paths: Array) -> Array:
	var out: Array = []
	for p in paths:
		out.append(str(p).replace("res://", ""))
	return out

## One tab: a full-width, vertically stacked, independently scrolling page.
func _make_tab(title: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tabs.add_child(scroll)
	# A margin keeps content off the tab border, matching editor panels.
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 6)
	scroll.add_child(margin)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 6)
	margin.add_child(col)
	return col

# -- forms (disconnected) --------------------------------------------------

func _build_forms(parent: Control) -> void:
	_forms = VBoxContainer.new()
	_forms.add_theme_constant_override("separation", 4)
	parent.add_child(_forms)

	_forms.add_child(_section_label("Host"))
	_host_name = _labeled_line(_forms, "Name", _default_user_name())
	var hp := HBoxContainer.new(); _forms.add_child(hp)
	hp.add_child(_mk_label("Port"))
	_host_port = SpinBox.new()
	_host_port.min_value = 1024; _host_port.max_value = 65535
	_host_port.value = Protocol.DEFAULT_PORT
	_host_port.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hp.add_child(_host_port)
	var rr := HBoxContainer.new(); _forms.add_child(rr)
	rr.add_child(_mk_label("Guests"))
	_host_role = OptionButton.new()
	_host_role.add_item("Editor", 0)
	_host_role.add_item("Viewer", 1)
	_host_role.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rr.add_child(_host_role)
	var host_btn := Button.new()
	host_btn.text = "Host Session"
	host_btn.pressed.connect(_on_host_pressed)
	_forms.add_child(host_btn)

	_forms.add_child(HSeparator.new())
	_forms.add_child(_section_label("Join"))

	_nearby_label = Label.new()
	_nearby_label.text = "Searching your network…"
	_nearby_label.modulate = Color(1, 1, 1, 0.5)
	_nearby_label.add_theme_font_size_override("font_size", 11)
	_forms.add_child(_nearby_label)
	_nearby = VBoxContainer.new()
	_forms.add_child(_nearby)

	var inv := HBoxContainer.new(); _forms.add_child(inv)
	_join_invite = LineEdit.new()
	_join_invite.placeholder_text = "Paste invite link…"
	_join_invite.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_join_invite.text_submitted.connect(func(_t): _apply_invite())
	inv.add_child(_join_invite)
	var use_btn := Button.new()
	use_btn.text = "Use"
	use_btn.pressed.connect(_apply_invite)
	inv.add_child(use_btn)

	_join_ip = _labeled_line(_forms, "Host IP", "127.0.0.1")
	var jp := HBoxContainer.new(); _forms.add_child(jp)
	jp.add_child(_mk_label("Port"))
	_join_port = SpinBox.new()
	_join_port.min_value = 1024; _join_port.max_value = 65535
	_join_port.value = Protocol.DEFAULT_PORT
	_join_port.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	jp.add_child(_join_port)
	_join_name = _labeled_line(_forms, "Name", _default_user_name())
	_join_code = _labeled_line(_forms, "Code", "")
	_join_code.placeholder_text = "ABCD-4829"
	var join_btn := Button.new()
	join_btn.text = "Join Session"
	join_btn.pressed.connect(_on_join_pressed)
	_forms.add_child(join_btn)

	# Two editors on one machine cannot share a UDP port, so the beacon channel
	# is adjustable -- give each local editor its own and both keep discovery.
	var dp := HBoxContainer.new(); _forms.add_child(dp)
	dp.add_child(_mk_label("LAN chan"))
	_discovery_port = SpinBox.new()
	_discovery_port.min_value = 1024; _discovery_port.max_value = 65535
	_discovery_port.value = Protocol.DISCOVERY_PORT
	_discovery_port.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_discovery_port.tooltip_text = ("UDP port used to find sessions on your network.\n"
		+ "Everyone who should see each other must use the same number.\n"
		+ "Change it only if two editors run on this one computer.")
	_discovery_port.value_changed.connect(func(v): discovery_port_changed.emit(int(v)))
	dp.add_child(_discovery_port)

	var test_btn := Button.new()
	test_btn.text = "Run self-test"
	test_btn.tooltip_text = "Verify hosting + joining works locally, no second computer needed."
	test_btn.pressed.connect(func(): self_test_requested.emit())
	_forms.add_child(test_btn)

func _build_session_box(parent: Control) -> void:
	_session_box = VBoxContainer.new()
	_session_box.add_theme_constant_override("separation", 4)
	parent.add_child(_session_box)

	_session_box.add_child(_section_label("Invite"))
	var inv := HBoxContainer.new(); _session_box.add_child(inv)
	_invite_value = LineEdit.new()
	# Read-only but still selectable, so Ctrl+C works even if the clipboard
	# API is unavailable. Clicking selects the whole link ready to copy.
	_invite_value.editable = false
	_invite_value.selecting_enabled = true
	_invite_value.caret_blink = false
	_invite_value.tooltip_text = "Click to select, or use Copy."
	_invite_value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_invite_value.gui_input.connect(func(event):
		if event is InputEventMouseButton and event.pressed:
			_invite_value.select_all()
			_invite_value.grab_focus())
	inv.add_child(_invite_value)
	var copy := Button.new()
	copy.text = "Copy"
	copy.tooltip_text = "Copy the invite link to the clipboard."
	copy.pressed.connect(func(): _copy_text(_invite_value.text, "Invite link"))
	inv.add_child(copy)

	_external_row = HBoxContainer.new()
	_external_row.visible = false
	_session_box.add_child(_external_row)
	_external_row.add_child(_mk_label("Internet"))
	_external_value = LineEdit.new()
	_external_value.editable = false
	_external_value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_external_row.add_child(_external_value)
	var copy_ext := Button.new()
	copy_ext.text = "Copy"
	copy_ext.tooltip_text = "Copy the internet-reachable invite link."
	copy_ext.pressed.connect(func(): _copy_text(_external_value.text, "Internet link"))
	_external_row.add_child(copy_ext)

	var code_row := HBoxContainer.new(); _session_box.add_child(code_row)
	code_row.add_child(_mk_label("Code"))
	_code_value = Label.new()
	_code_value.add_theme_font_size_override("font_size", 16)
	_code_value.text = "—"
	code_row.add_child(_code_value)
	var copy_code := Button.new()
	copy_code.text = "Copy"
	copy_code.tooltip_text = "Copy just the session code."
	copy_code.pressed.connect(func(): _copy_text(_code_value.text, "Session code"))
	code_row.add_child(copy_code)
	_new_code_btn = Button.new()
	_new_code_btn.text = "New"
	_new_code_btn.tooltip_text = "Generate a new join code. People already connected stay connected."
	_new_code_btn.pressed.connect(func(): new_code_requested.emit())
	code_row.add_child(_new_code_btn)

	var btns := HBoxContainer.new(); _session_box.add_child(btns)
	var backups := Button.new()
	backups.text = "Backups"
	backups.pressed.connect(func(): open_backups_requested.emit())
	btns.add_child(backups)
	_disconnect_btn = Button.new()
	_disconnect_btn.text = "Leave"
	_disconnect_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_disconnect_btn.pressed.connect(func(): disconnect_requested.emit())
	btns.add_child(_disconnect_btn)

# -- mode switching --------------------------------------------------------

func set_mode_disconnected() -> void:
	_forms.visible = true
	_session_box.visible = false
	_chat.set_enabled(false)
	_chat.clear()
	_dot.modulate = C_IDLE
	_primary_lbl.text = ""
	_external_row.visible = false

func set_mode_hosting(code: String, ip: String, port: int) -> void:
	_forms.visible = false
	_session_box.visible = true
	_code_value.text = code
	_invite_value.text = Protocol.make_invite(ip, port, code)
	_disconnect_btn.text = "End Session"
	_new_code_btn.visible = true
	_chat.set_enabled(true)
	_dot.modulate = C_LIVE

func set_mode_client(ip: String, port: int, code: String) -> void:
	_forms.visible = false
	_session_box.visible = true
	_code_value.text = code
	_invite_value.text = Protocol.make_invite(ip, port, code)
	_disconnect_btn.text = "Leave"
	_new_code_btn.visible = false
	_chat.set_enabled(true)
	_dot.modulate = C_LIVE

## Shown only when UPnP actually succeeded.
func set_external_invite(link: String) -> void:
	_external_value.text = link
	_external_row.visible = link != ""

func set_status(text: String) -> void:
	_status.text = text
	if text.begins_with("Connecting") or text.begins_with("Self-test:"):
		_dot.modulate = C_WAIT

## Banner describing your own edit rights on the file you are focused on.
## `my_primary` is the file THIS user holds (may differ from the focused file).
func set_primary_state(path: String, owned: bool, owner_name: String,
		my_primary: String = "") -> void:
	# Always say plainly which file you hold, even if you are looking elsewhere.
	var held := "You hold: %s" % my_primary.get_file() if my_primary != "" else "You hold: nothing"

	if path == "":
		_primary_lbl.text = "%s\nNo file focused." % held
		_primary_lbl.modulate = Color(1, 1, 1, 0.6)
	elif owned:
		_primary_lbl.text = "%s\n✏ Primary of %s — your edits sync." % [held, path.get_file()]
		_primary_lbl.modulate = Color(0.45, 0.9, 0.5)
	else:
		_primary_lbl.text = "%s\n🔒 %s — %s is primary (view only)" % [
			held, path.get_file(), owner_name]
		_primary_lbl.modulate = Color(1.0, 0.72, 0.3)

	var free_file := path != "" and not owned and owner_name == ""
	_take_btn.disabled = path == "" or owned
	_release_btn.disabled = my_primary == ""
	_request_btn.disabled = path == "" or owned or free_file

## Show exactly what a join will do before anything is written.
## `overwrites` are local files that exist and differ; `additions` are new.
func show_manifest(overwrites: Array, additions: Array, identical: int = 0) -> void:
	var summary := ""
	var bullets: Array = []
	if overwrites.is_empty():
		summary = "No existing file in this project will be changed."
		bullets = ["%d new file(s) will be added." % additions.size()]
	else:
		summary = "⚠  %d file(s) in THIS project will be OVERWRITTEN:" % overwrites.size()
		bullets = _short_paths(overwrites)
	var note := ""
	if not overwrites.is_empty():
		note += "%d new file(s) will also be added. " % additions.size()
	if identical > 0:
		note += "%d file(s) already match and will be left alone. " % identical
	note += ("Overwritten files are copied to .collab_backup/ first and can be "
		+ "put back from the Backups button.")
	_manifest_dialog.dialog_text = _dialog_text(
		summary, bullets, note, "Apply the host's project?")
	_manifest_dialog.popup_centered()

## Browse and restore backups. `entries` come from BackupStore.list_all().
func show_backups(entries: Array, total_bytes: int = 0) -> void:
	for c in _backup_list.get_children():
		c.queue_free()

	# Summary + a way to reclaim the space.
	var header := HBoxContainer.new()
	var summary := Label.new()
	summary.text = "%d backup(s) · %.1f MB" % [entries.size(), total_bytes / 1048576.0]
	summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	summary.add_theme_font_size_override("font_size", 11)
	header.add_child(summary)
	var clear_all_btn := Button.new()
	clear_all_btn.text = "Clear all"
	clear_all_btn.tooltip_text = "Delete every backup. This cannot be undone."
	clear_all_btn.disabled = entries.is_empty()
	clear_all_btn.pressed.connect(func(): _ask_clear("", entries.size()))
	header.add_child(clear_all_btn)
	_backup_list.add_child(header)
	_backup_list.add_child(HSeparator.new())

	# How many backups each original file has, for the per-file Clear button.
	var counts := {}
	for e in entries:
		counts[str(e.path)] = int(counts.get(str(e.path), 0)) + 1

	if entries.is_empty():
		var empty := Label.new()
		empty.text = "No backups yet. They are created whenever an incoming change overwrites a file."
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_backup_list.add_child(empty)
	else:
		var current_path := ""
		for e in entries:
			# Group under the original file path.
			if str(e.path) != current_path:
				current_path = str(e.path)
				var head_row := HBoxContainer.new()
				var head := Label.new()
				head.text = current_path.replace("res://", "")
				head.add_theme_font_size_override("font_size", 12)
				head.modulate = Color(0.6, 0.78, 1.0)
				head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				head_row.add_child(head)
				var clear_one := Button.new()
				clear_one.text = "Clear"
				clear_one.tooltip_text = "Delete every backup of this file."
				var this_path := current_path
				var this_count := int(counts.get(current_path, 0))
				clear_one.pressed.connect(func(): _ask_clear(this_path, this_count))
				head_row.add_child(clear_one)
				_backup_list.add_child(head_row)
			var row := HBoxContainer.new()
			var lbl := Label.new()
			lbl.text = "    v%d · %s · %.1f KB" % [
				int(e.version), str(e.stamp).replace("T", " "), int(e.size) / 1024.0]
			lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			lbl.add_theme_font_size_override("font_size", 11)
			row.add_child(lbl)
			var btn := Button.new()
			btn.text = "Restore"
			var file := str(e.file)
			btn.pressed.connect(func(): restore_requested.emit(file))
			row.add_child(btn)
			_backup_list.add_child(row)
	_backup_dialog.popup_centered()

## Show something the user must not miss.
func show_notice(title: String, summary: String, bullets: Array, note: String) -> void:
	_notice_dialog.title = title
	_notice_dialog.dialog_text = _dialog_text(summary, bullets, note, "")
	_notice_dialog.popup_centered()

## Confirm before deleting backups: they are the only copy of overwritten work.
func _ask_clear(path: String, count: int) -> void:
	_pending_clear = path
	var what := ("every backup in this project" if path == ""
		else "the backups of %s" % path.replace("res://", ""))
	_clear_backups_dialog.dialog_text = _dialog_text(
		"About to delete %s." % what,
		["%d backup file(s) will be removed." % count],
		"Backups are the only copy of anything an incoming change overwrote. "
		+ "Once deleted they cannot be recovered.",
		"Delete them?")
	_clear_backups_dialog.popup_centered()

## Ask before propagating deletions -- they hit everyone at once.
func confirm_deletes(paths: Array) -> void:
	_pending_deletes = paths.duplicate()
	_delete_warning.dialog_text = _dialog_text(
		"%d file(s) were deleted on this computer:" % paths.size(),
		_short_paths(paths),
		"Deleting them for everyone takes effect immediately for every "
		+ "collaborator. Copies are kept in .collab_backup/ and can be put back "
		+ "from the Backups button.",
		"Delete for everyone?")
	_delete_warning.popup_centered()

## Copy to the clipboard and verify it actually landed.
##
## DisplayServer.clipboard_set() fails silently when the platform has no
## clipboard (headless, some Linux setups), which looks exactly like a broken
## button. We read the value back and tell the user either way, and always
## leave the text selected so Ctrl+C works as a fallback.
func _copy_text(text: String, label: String) -> bool:
	if text.strip_edges() == "":
		set_status("Nothing to copy yet.")
		return false
	if not DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		_invite_value.select_all()
		set_status("%s selected — press Ctrl+C to copy." % label)
		return false
	DisplayServer.clipboard_set(text)
	if DisplayServer.clipboard_get() == text:
		set_status("%s copied to the clipboard." % label)
		return true
	_invite_value.select_all()
	set_status("Could not reach the clipboard — the text is selected, press Ctrl+C.")
	return false

## Traffic + latency readout, so a slow session is diagnosable.
func set_stats(sent: int, received: int, latency_ms: int) -> void:
	var line := "↑ %.1f KB   ↓ %.1f KB" % [sent / 1024.0, received / 1024.0]
	if latency_ms >= 0:
		line += "   ping %d ms" % latency_ms
	_stats.text = line

func set_defaults(d: Dictionary) -> void:
	if str(d.get("name", "")) != "":
		_host_name.text = str(d["name"])
		_join_name.text = str(d["name"])
	_host_port.value = int(d.get("port", Protocol.DEFAULT_PORT))
	_join_ip.text = str(d.get("join_ip", "127.0.0.1"))
	_join_port.value = int(d.get("join_port", Protocol.DEFAULT_PORT))
	_host_role.selected = 1 if str(d.get("role", "")) == Protocol.ROLE_VIEWER else 0
	if _discovery_port != null:
		_discovery_port.set_value_no_signal(
			int(d.get("discovery_port", Protocol.DISCOVERY_PORT)))

func update_discovered(hosts: Array) -> void:
	if _nearby == null:
		return
	for c in _nearby.get_children():
		c.queue_free()
	if hosts.is_empty():
		_nearby_label.text = "No sessions found on your network yet."
		return
	_nearby_label.text = "Found nearby:"
	for h in hosts:
		var row := HBoxContainer.new()
		var lbl := Label.new()
		lbl.text = "🖥 %s (%d)" % [h.get("name", "Session"), int(h.get("players", 1))]
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.add_theme_font_size_override("font_size", 11)
		row.add_child(lbl)
		var pick := Button.new()
		pick.text = "Use"
		var ip := str(h.get("ip", ""))
		var port := int(h.get("port", Protocol.DEFAULT_PORT))
		pick.pressed.connect(func():
			_join_ip.text = ip
			_join_port.value = port
			set_status("Filled in %s:%d — enter the code to join." % [ip, port]))
		row.add_child(pick)
		_nearby.add_child(row)

# roster: Array of {id, name, color, role, is_self, activity, primary}
func update_roster(roster: Array, show_controls: bool = false) -> void:
	for c in _players.get_children():
		c.queue_free()
	for u in roster:
		var row := HBoxContainer.new()
		var dot := Label.new()
		dot.text = "●"
		dot.modulate = Color.html(str(u.get("color", "#ffffff")))
		row.add_child(dot)
		var uid_for_jump := int(u.get("id", -1))
		var name_lbl := Button.new()
		name_lbl.flat = true
		name_lbl.alignment = HORIZONTAL_ALIGNMENT_LEFT
		name_lbl.tooltip_text = "Open the file this person is working in."
		if not u.get("is_self", false):
			name_lbl.pressed.connect(func(): jump_to_user_requested.emit(uid_for_jump))
		var suffix := " (you)" if u.get("is_self", false) else ""
		# Show how long someone has been quiet, so a stale claim is explainable.
		var idle := int(u.get("idle_for", -1))
		if idle >= 60 and not u.get("is_self", false):
			suffix += "  · idle %dm" % int(idle / 60)
		name_lbl.text = "%s [%s]%s" % [u.get("name", "?"), u.get("role", "editor"), suffix]
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_lbl)

		var uid := int(u.get("id", -1))
		var role := str(u.get("role", Protocol.ROLE_EDITOR))
		if show_controls and uid > 0:
			var toggle := Button.new()
			var make_viewer := role != Protocol.ROLE_VIEWER
			toggle.text = "→V" if make_viewer else "→E"
			toggle.tooltip_text = "Change permissions."
			var new_role := Protocol.ROLE_VIEWER if make_viewer else Protocol.ROLE_EDITOR
			toggle.pressed.connect(func(): role_change_requested.emit(uid, new_role))
			row.add_child(toggle)
			var kick := Button.new()
			kick.text = "✕"
			kick.tooltip_text = "Remove from the session."
			kick.pressed.connect(func(): kick_requested.emit(uid))
			row.add_child(kick)
		_players.add_child(row)

		# Which file this person is primary on.
		var primary := str(u.get("primary", ""))
		if primary != "":
			var pl := Label.new()
			pl.text = "    ✏ %s" % primary.get_file()
			pl.modulate = Color(1, 1, 1, 0.6)
			pl.add_theme_font_size_override("font_size", 11)
			_players.add_child(pl)
		var activity := str(u.get("activity", ""))
		if activity != "" and activity != "idle":
			var act := Label.new()
			act.text = "    ↳ %s" % activity
			act.modulate = Color(1, 1, 1, 0.45)
			act.add_theme_font_size_override("font_size", 11)
			_players.add_child(act)

func chat_line(name: String, color: String, text: String) -> void:
	_chat.add_line(name, color, text)

func chat_system(text: String) -> void:
	_chat.add_system(text)

# -- handlers --------------------------------------------------------------

func _submit_nickname() -> void:
	var wanted := Protocol.clean_nickname(_nickname.text)
	if wanted == "":
		set_status("Enter a nickname first.")
		return
	_nickname.text = wanted
	nickname_changed.emit(wanted)

## Reflect the name actually in use (the host may have cleaned it up).
func set_nickname(name: String) -> void:
	_nickname.text = name

func _apply_invite() -> void:
	var parsed = Protocol.parse_invite(_join_invite.text)
	if parsed == null:
		set_status("That doesn't look like a valid invite link.")
		return
	_join_ip.text = str(parsed.ip)
	_join_port.value = int(parsed.port)
	_join_code.text = str(parsed.code)
	set_status("Invite loaded — click Join Session.")

func _on_host_pressed() -> void:
	var role := Protocol.ROLE_VIEWER if _host_role.selected == 1 else Protocol.ROLE_EDITOR
	host_requested.emit(_host_name.text.strip_edges(), int(_host_port.value), role)

func _on_join_pressed() -> void:
	# Joining pulls the host's whole project onto this machine, overwriting any
	# file with the same path. Make absolutely sure the user understands that
	# before a single byte is written.
	_pending_join = {
		"ip": _join_ip.text.strip_edges(),
		"port": int(_join_port.value),
		"name": _join_name.text.strip_edges(),
		"code": _join_code.text.strip_edges().to_upper(),
	}
	if _pending_join.ip == "":
		# Put the cursor where the problem is, so the button never just
		# "does nothing".
		set_status("Enter the host's IP address first.")
		_join_ip.grab_focus()
		return
	_join_warning.dialog_text = _dialog_text(
		"You are about to join the session at %s." % _pending_join.ip,
		[
			"The host's project is copied onto this computer.",
			"Any file here with the same path WILL BE OVERWRITTEN.",
			"Join from an empty project unless you mean to replace this one.",
		],
		"Your installed addons are left alone, files the host does not have are "
		+ "not deleted, and anything overwritten is backed up to .collab_backup/ "
		+ "first. You will see the exact file list before anything is written.",
		"Continue?")
	_join_warning.popup_centered()

func _on_join_confirmed() -> void:
	if _pending_join.is_empty():
		return
	var j := _pending_join.duplicate()
	_pending_join.clear()
	join_requested.emit(str(j.ip), int(j.port), str(j.name), str(j.code))

# -- small UI helpers ------------------------------------------------------

func _default_user_name() -> String:
	var n := OS.get_environment("USERNAME")
	if n == "":
		n = OS.get_environment("USER")
	return n if n != "" else "User"

func _section_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 12)
	l.modulate = Color(0.6, 0.78, 1.0)
	return l

func _mk_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(60, 0)
	return l

func _labeled_line(parent: Control, label: String, initial: String) -> LineEdit:
	var row := HBoxContainer.new()
	parent.add_child(row)
	row.add_child(_mk_label(label))
	var le := LineEdit.new()
	le.text = initial
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(le)
	return le
