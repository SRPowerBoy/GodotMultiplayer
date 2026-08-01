extends SceneTree
## Verifies the dock does not demand excessive vertical space.
##
## A tall minimum size is what makes Godot grow the right dock column and
## squeeze the editor's bottom panel (Output/Debugger) out of the layout, so
## this guards against that regression.

const CollabPanel := preload("res://addons/godot_collab/ui/collab_panel.gd")
const Protocol := preload("res://addons/godot_collab/network/protocol.gd")

# The bottom panel must stay short -- it shares the bar with Output/Debugger.
const MAX_ACCEPTABLE_MIN_HEIGHT := 260.0

var results: Array = []
func ok(c: bool, l: String) -> void:
	results.append(c); print(("PASS " if c else "FAIL ") + l)

func _init() -> void:
	var panel = CollabPanel.new()
	root.add_child(panel)
	# Let layout settle.
	for i in 3:
		await process_frame

	var minsize: Vector2 = panel.get_combined_minimum_size()
	print("dock combined minimum size = %s" % str(minsize))
	ok(minsize.y <= MAX_ACCEPTABLE_MIN_HEIGHT,
		"dock min height %.0f <= %.0f (won't squeeze the bottom panel)"
		% [minsize.y, MAX_ACCEPTABLE_MIN_HEIGHT])

	# Three full-width vertical tabs, each independently scrollable.
	var tabs: TabContainer = null
	for c in panel.get_children():
		if c is TabContainer:
			tabs = c
	ok(tabs != null, "panel is organised into tabs")
	var scroll: ScrollContainer = null
	var pages := 0
	if tabs:
		for c in tabs.get_children():
			if c is ScrollContainer:
				pages += 1
				if scroll == null:
					scroll = c
	ok(scroll != null, "each tab scrolls on its own")
	ok(pages == 3, "there are 3 tabs (got %d)" % pages)
	if tabs and pages == 3:
		var names := [str(tabs.get_child(0).name), str(tabs.get_child(1).name),
			str(tabs.get_child(2).name)]
		ok(names == ["Session", "People", "Chat"],
			"tabs are Session / People / Chat (got %s)" % str(names))

	# Evidence for the fix: the inner content is what used to sit directly in
	# the dock. Its minimum height is the space the dock previously demanded.
	if scroll != null and scroll.get_child_count() > 0:
		var inner: Control = scroll.get_child(0)
		var inner_min: Vector2 = inner.get_combined_minimum_size()
		print("inner content minimum height = %.0f (this is what the dock used to demand)"
			% inner_min.y)
		ok(inner_min.y > minsize.y,
			"scrolling decoupled the dock (%.0f demanded -> %.0f required)"
			% [inner_min.y, minsize.y])

	# Simulate a short dock: the panel must accept a small height without
	# reporting a larger minimum (i.e. it scrolls instead of pushing).
	panel.size = Vector2(280, 200)
	for i in 2:
		await process_frame
	ok(panel.size.y <= 210.0, "dock accepts a 200px height (got %.0f)" % panel.size.y)

	# Sanity: switching modes must not blow up the minimum size either.
	panel.set_mode_hosting("ABCD-4829", "192.168.1.20", 8890)
	for i in 2:
		await process_frame
	var hosting_min: Vector2 = panel.get_combined_minimum_size()
	print("hosting-mode minimum size = %s" % str(hosting_min))
	ok(hosting_min.y <= MAX_ACCEPTABLE_MIN_HEIGHT,
		"hosting mode min height %.0f stays bounded" % hosting_min.y)

	# --- joining must be gated behind an explicit confirmation ---
	panel.set_mode_disconnected()
	for i in 2:
		await process_frame
	var joins: Array = []
	panel.join_requested.connect(func(ip, port, n, code): joins.append(ip))

	# Several confirmation dialogs exist (join, delete) -- pick the join one.
	var dialog: ConfirmationDialog = null
	var delete_dialog: ConfirmationDialog = null
	for c in panel.get_children():
		if c is ConfirmationDialog:
			if str(c.title) == "Join session":
				dialog = c
			elif str(c.title) == "Delete files":
				delete_dialog = c
	ok(dialog != null, "a join confirmation dialog exists")
	ok(delete_dialog != null, "a delete confirmation dialog exists")

	panel._join_ip.text = "10.0.0.5"
	panel._on_join_pressed()
	for i in 2:
		await process_frame
	ok(joins.is_empty(), "pressing Join does NOT connect before confirming")
	ok(dialog != null and dialog.visible, "the warning dialog is shown instead")
	ok(dialog != null and dialog.dialog_text.to_lower().contains("overwritten"),
		"warning states that files will be overwritten")
	ok(dialog != null and dialog.dialog_text.to_lower().contains("empty project"),
		"warning recommends joining from an empty project")

	# Confirming proceeds.
	dialog.confirmed.emit()
	for i in 2:
		await process_frame
	ok(joins.size() == 1 and joins[0] == "10.0.0.5",
		"confirming proceeds with the join (got %s)" % str(joins))

	# Cancelling must not connect.
	joins.clear()
	panel._on_join_pressed()
	for i in 2:
		await process_frame
	dialog.hide()          # user pressed Cancel / closed it
	for i in 2:
		await process_frame
	ok(joins.is_empty(), "cancelling the dialog does not connect")

	# --- the banner always states which file YOU hold ---
	panel.set_primary_state("res://a.gd", true, "", "res://a.gd")
	ok(panel._primary_lbl.text.contains("You hold: a.gd"),
		"banner names your held file when you own the focused one")
	panel.set_primary_state("res://other.tscn", false, "Alex", "res://a.gd")
	ok(panel._primary_lbl.text.contains("You hold: a.gd"),
		"banner still names your held file while viewing someone else's")
	ok(panel._primary_lbl.text.contains("Alex"), "banner names the other primary")
	panel.set_primary_state("res://x.gd", false, "Alex", "")
	ok(panel._primary_lbl.text.contains("You hold: nothing"),
		"banner is explicit when you hold nothing")

	# Buttons reflect state: cannot release nothing, cannot take what you own.
	panel.set_primary_state("res://a.gd", true, "", "res://a.gd")
	ok(panel._take_btn.disabled, "Take is disabled for a file you already hold")
	ok(not panel._release_btn.disabled, "Release is enabled when you hold a file")
	panel.set_primary_state("", false, "", "")
	ok(panel._release_btn.disabled, "Release is disabled when you hold nothing")

	# --- deletions must be confirmed before they propagate ---
	var confirmed: Array = []
	panel.deletes_confirmed.connect(func(p): confirmed.append_array(p))
	panel.confirm_deletes(["res://gone.gd", "res://also.tscn"])
	for i in 2:
		await process_frame
	ok(confirmed.is_empty(), "deletes do NOT propagate before confirming")
	ok(delete_dialog != null and delete_dialog.visible, "delete warning is shown")
	ok(delete_dialog != null and delete_dialog.dialog_text.contains("gone.gd"),
		"delete warning lists the affected files")
	delete_dialog.confirmed.emit()
	for i in 2:
		await process_frame
	ok(confirmed.size() == 2, "confirming propagates the deletes (got %d)" % confirmed.size())

	# --- join manifest: nothing is written until it is reviewed ---
	var manifest_dialog: ConfirmationDialog = null
	for c in panel.get_children():
		if c is ConfirmationDialog and str(c.title).to_lower().contains("review"):
			manifest_dialog = c
	ok(manifest_dialog != null, "an incoming-project review dialog exists")

	var accepted := [0]
	var declined := [0]
	panel.manifest_accepted.connect(func(): accepted[0] += 1)
	panel.manifest_declined.connect(func(): declined[0] += 1)

	panel.show_manifest(["res://player.gd", "res://level.tscn"], ["res://new.gd"], 7)
	for i in 2:
		await process_frame
	ok(manifest_dialog.visible, "review dialog is shown before any transfer")
	var mt: String = manifest_dialog.dialog_text
	ok(mt.contains("OVERWRITTEN"), "review states files will be overwritten")
	ok(mt.contains("player.gd") and mt.contains("level.tscn"),
		"review lists each file that would be overwritten")
	ok(mt.contains("1 new file"), "review counts additions separately")
	ok(mt.contains("7 file(s) already match"),
		"review reports files that already match instead of calling them overwrites")
	ok(accepted[0] == 0 and declined[0] == 0, "showing the review decides nothing")

	manifest_dialog.confirmed.emit()
	for i in 2:
		await process_frame
	ok(accepted[0] == 1, "confirming accepts the transfer")

	# The no-conflict case must read differently.
	panel.show_manifest([], ["res://a.gd", "res://b.gd"])
	for i in 2:
		await process_frame
	ok(panel._manifest_dialog.dialog_text.contains("No existing file"),
		"review says so plainly when nothing would be overwritten")

	# --- backup browser ---
	panel.show_backups([])
	for i in 2:
		await process_frame
	ok(panel._backup_dialog.visible, "backup browser opens")
	var restored: Array = []
	panel.restore_requested.connect(func(f): restored.append(f))
	panel.show_backups([{ "file": "a__v1__S.bak", "path": "res://a.gd",
		"version": 1, "stamp": "S", "size": 10 }], 10)
	for i in 2:
		await process_frame
	var found_btn: Button = null
	for row in panel._backup_list.get_children():
		for child in row.get_children() if row.get_child_count() > 0 else []:
			if child is Button:
				found_btn = child
	ok(found_btn != null, "each backup row offers a Restore button")
	if found_btn:
		found_btn.pressed.emit()
		await process_frame
		ok(restored.size() == 1 and restored[0] == "a__v1__S.bak",
			"Restore reports the right backup file (got %s)" % str(restored))

	# --- copy button: must never fail silently ---
	panel.set_mode_hosting("ABCD-4829", "192.168.1.20", 8890)
	for i in 2:
		await process_frame
	var link: String = panel._invite_value.text
	ok(link == "godotcollab://192.168.1.20:8890/ABCD-4829",
		"invite field holds the full link (got '%s')" % link)
	ok(panel._invite_value.selecting_enabled,
		"invite text is selectable so Ctrl+C works as a fallback")

	var copied := panel._copy_text(link, "Invite link")
	var msg: String = panel._status.text
	if copied:
		ok(DisplayServer.clipboard_get() == link, "clipboard really holds the link")
		ok(msg.contains("copied"), "success is reported to the user (got '%s')" % msg)
	else:
		# No clipboard here (headless) -- the user must still be told what to do.
		ok(msg.contains("Ctrl+C"), "fallback tells the user how to copy (got '%s')" % msg)
		ok(panel._invite_value.get_selected_text() == link,
			"text is pre-selected for a manual copy")
	ok(not panel._copy_text("", "Nothing"), "copying empty text is refused")
	ok(panel._status.text.contains("Nothing to copy"), "empty copy explains itself")

	# --- dialogs share one format ---
	var body := panel._dialog_text("Summary line.", ["a", "b"], "A note.", "Question?")
	ok(body.begins_with("Summary line."), "dialog body starts with the summary")
	ok(body.contains("  • a") and body.contains("  • b"), "details render as bullets")
	ok(body.contains("A note."), "note included")
	ok(body.ends_with("Question?"), "body ends with the question")
	var many: Array = []
	for i in 40:
		many.append("file_%d.gd" % i)
	var big := panel._dialog_text("S", many, "", "Q?")
	ok(big.contains("… and %d more" % (40 - panel.DIALOG_MAX_BULLETS)),
		"long lists are truncated with a count")
	ok(panel._short_paths(["res://a/b.gd"]) == ["a/b.gd"], "paths shown project-relative")

	# Every confirmation dialog uses the same width and wrapping.
	for c in panel.get_children():
		if c is ConfirmationDialog:
			ok(c.dialog_autowrap, "%s wraps its text" % c.title)
			ok(c.min_size.x == panel.DIALOG_WIDTH,
				"%s uses the shared width (%d)" % [c.title, c.min_size.x])

	# --- clearing backups is confirmed, never immediate ---
	var cleared: Array = []
	panel.clear_backups_requested.connect(func(p): cleared.append(p))
	var clear_dialog: ConfirmationDialog = null
	for c in panel.get_children():
		if c is ConfirmationDialog and str(c.title) == "Delete backups":
			clear_dialog = c
	ok(clear_dialog != null, "a backup-deletion confirmation exists")

	panel._ask_clear("res://a.gd", 3)
	for i in 2:
		await process_frame
	ok(cleared.is_empty(), "asking to clear does not delete anything yet")
	ok(clear_dialog.dialog_text.contains("a.gd"), "confirmation names the file")
	ok(clear_dialog.dialog_text.contains("3 backup file(s)"), "confirmation states the count")
	ok(clear_dialog.dialog_text.contains("cannot be recovered"),
		"confirmation warns the loss is permanent")
	clear_dialog.confirmed.emit()
	for i in 2:
		await process_frame
	ok(cleared == ["res://a.gd"], "confirming clears that file only (got %s)" % str(cleared))

	cleared.clear()
	panel._ask_clear("", 12)
	for i in 2:
		await process_frame
	ok(panel._clear_backups_dialog.dialog_text.contains("every backup"),
		"clear-all confirmation says it affects everything")
	clear_dialog.confirmed.emit()
	for i in 2:
		await process_frame
	ok(cleared == [""], "confirming clear-all requests every backup")

	# --- nicknames ---
	var nicks: Array = []
	panel.nickname_changed.connect(func(n): nicks.append(n))
	panel._nickname.text = "  Seth   The  Dev  "
	panel._submit_nickname()
	ok(nicks.size() == 1, "setting a nickname emits once (got %d)" % nicks.size())
	ok(nicks.size() == 1 and nicks[0] == "Seth The Dev",
		"whitespace is collapsed and trimmed (got '%s')" % str(nicks))
	ok(panel._nickname.text == "Seth The Dev", "field shows the cleaned name")

	nicks.clear()
	panel._nickname.text = "   "
	panel._submit_nickname()
	ok(nicks.is_empty(), "an empty nickname is refused")
	ok(panel._status.text.contains("nickname"), "and the user is told why")

	# Names must not be able to inject chat markup or overflow the roster.
	ok(Protocol.clean_nickname("[color=red]evil[/color]").contains("(color=red)"),
		"BBCode brackets are neutralised in names")
	var long_name := Protocol.clean_nickname("x".repeat(200))
	ok(long_name.length() <= Protocol.MAX_NICKNAME,
		"long names are truncated to %d (got %d)" % [Protocol.MAX_NICKNAME, long_name.length()])

	panel.queue_free()

	var passed := 0
	for r in results:
		if r: passed += 1
	print("\n==== %d/%d passed ====" % [passed, results.size()])
	quit(0 if passed == results.size() else 1)
