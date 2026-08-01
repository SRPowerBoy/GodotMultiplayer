# Godot Collab Host

Peer-hosted, real-time collaboration for the Godot **4.4** editor. One person
clicks **Host Session**, shares an invite code, and collaborators join and edit
the same project live. **No external server infrastructure** — the host's editor
*is* the server.

Verified against **Godot v4.4.1-stable** (headless networking + file-sync test
suites pass; the plugin loads clean in the editor).

---

## Install

1. Copy the `addons/godot_collab/` folder into your project's `addons/` folder.
2. **Project → Project Settings → Plugins →** enable **Godot Collab Host**.
3. A **Godot Collab** dock appears on the right.

(This repository is itself a minimal Godot project, so you can open the folder
directly in Godot 4.4 to try the plugin or run the tests in `../_test_*.gd`.)

---

## Use

### Host
1. In the dock, enter your name, a port (default `8890`), and whether guests
   join as **Editor** or **Viewer**.
2. Click **Host Session**. You get an invite **code** like `ABCD-4829` and your
   **LAN IP**. Share both. Click **Copy** to copy the code.

### Join
1. Easiest of all: if the host is on your network, their session appears
   automatically under **Found on your network** — click **Use**, then type the
   code. Otherwise paste the host's **invite link**
   (`godotcollab://IP:PORT/CODE`) and click **Use**, or type the **IP**,
   **port**, **name**, and **session code** by hand.
2. Click **Join Session**. The host streams the whole project to you on connect;
   after that, saves sync both ways.

### Not sure it works? Self-test
Click **Run self-test (this machine)** while disconnected. It spins up a loopback
host + client inside your editor and confirms the handshake succeeds — no second
computer required.

---

## How it works

```
        Host editor (authoritative server + project state + versions)
                    │  TCPServer + WebSocketPeer.accept_stream()
        ┌───────────┴───────────┐
     Client A                Client B      (WebSocketPeer.connect_to_url)
```

Godot 4 removed the old high-level WebSocket *server* class, so the host accepts
raw TCP connections and upgrades each one to a `WebSocketPeer`. Every message is
JSON sent as a WebSocket text frame; file bytes travel as base64 inside the JSON
so text and binary assets share one code path.

- **File sync** — a modification-time + content-hash watcher (`sync/file_sync.gd`)
  detects *saves* (never per-keystroke) across `.gd .tscn .tres .cfg` and assets
  (`png jpg wav ogg glb …`), and pushes the changed file. Remote writes are
  echo-suppressed so a received change is never bounced back.
- **Host authority + conflict handling** — the host keeps a version number per
  file. A client edit carries the version it was based on; if that is stale, the
  host **rejects** it and force-resyncs the authoritative copy. The host always
  wins.
- **Snapshot on join** — new peers pull the entire tracked project from the host.
  The transfer is **paced across frames** (a few files per tick) with live
  progress, so a large project never stalls the editor or overruns the socket.
- **LAN auto-discovery** — hosts advertise over UDP broadcast; idle editors on
  the same network list nearby sessions with one-click fill-in. The beacon
  carries the session *name and port only* — never the code — so discovery can't
  be used to join without the secret.
- **Compression** — payloads above 512 B are gzipped before base64 (typically a
  60–98% cut on scripts and scenes). The receiver honours a per-message `enc`
  field, so compressed and plain payloads interoperate.
- **Host moderation** — the host can promote/demote any collaborator between
  editor and viewer, or remove them, straight from the player list.
- **Deletions & renames sync** — removing a file propagates to everyone (a rename
  is a delete + add at the file level). The removed file is backed up first.
- **Invite links** — one copy-paste token (`godotcollab://IP:PORT/CODE`) carries
  everything a collaborator needs.
- **Heartbeat + timeout** — both ends ping every few seconds; a peer (or host)
  that goes silent past the timeout is detected and cleanly disconnected instead
  of hanging.
- **Backups** — before overwriting or deleting, the host/clients snapshot into
  `.collab_backup/` (per-path, versioned, timestamped). Use **Open backups** in
  the dock, then restore a `.bak` by hand.
- **Remembers you** — name, port, last host IP and role persist between sessions.
- **Presence** — `presence/selection_sync.gd` reports your current scene and
  selected node; the dock shows every collaborator's color, role, and what they
  are editing (e.g. `player.tscn ▸ Enemy`).
- **Chat** — built-in, with join/leave notices.
- **Roles / security** — Host / Editor / Viewer. Viewers can't write. The session
  code doubles as a join secret; wrong code is rejected.

---

## Honest limitations (read this)

This plugin is deliberately built around what the Godot editor actually exposes.
Some items from an idealized "live co-editing" pitch are **not** fully possible
from GDScript inside the editor, and are handled at reduced fidelity rather than
faked:

- **Granularity is per-save, not per-keystroke.** Scenes/scripts sync when you
  save (`Ctrl-S`) or when a resource/import changes — not on every character.
  Two people typing into the *same file* between saves is last-writer-wins at the
  file level (older base version is rejected and reloaded).
- **No live viewport cursor overlay.** The editor gives no reliable API to draw
  another user's mouse over the 2D/3D viewport or to inject their live node
  drags. "Collaborator cursors" are realized as **selection presence** (who has
  what selected in which scene). `presence/cursor_sync.gd` documents this.
- **Networking is LAN + manual IP/port.** Works over the internet if the host
  port-forwards. True NAT hole-punching needs a rendezvous/signaling server,
  which would violate the "no infrastructure" requirement, so it is not included.
- **No TLS/`wss://` by default.** Traffic is `ws://` on your LAN. The session code
  gates joining; treat it as trusted-LAN collaboration.
- **Same-second double saves** to one file may need a second save to register
  (mtime has 1-second resolution). Rare in practice.
- Files larger than ~12 MB are skipped to protect the socket.

---

## File layout

```
addons/godot_collab/
  plugin.cfg / plugin.gd        EditorPlugin entry + orchestrator
  network/
    protocol.gd                 message types, invites, compression codec
    host_server.gd              TCPServer + WebSocketPeer host, roster, versions
    client_connection.gd        WebSocketPeer client
    lan_discovery.gd            UDP broadcast beacon + listener
  sync/
    file_sync.gd                save watcher, apply-remote, backups
    scene_sync.gd               reload open scene on remote change
    resource_sync.gd            reimport assets / refresh resources
  presence/
    selection_sync.gd           local scene + selection tracker
    cursor_sync.gd              remote presence aggregator
  ui/
    collab_panel.gd             the dock
    chat_panel.gd               chat widget
```

---

## Automated tests

The repo root ships three headless suites (run from the project folder):

```
godot --headless --path . --script res://_test_net.gd        # 27 checks
godot --headless --path . --script res://_test_filesync.gd   #  9 checks
godot --headless --path . --script res://_test_discovery.gd  #  6 checks
```

They cover the handshake, roster, chat, versioning/conflicts, code rejection,
kick + role changes, viewer enforcement, compression round-trips (text, tiny,
binary), invite parsing, save/delete detection, backups, echo suppression, and
LAN beacon discovery + expiry.

## Testing on two machines

1. Both machines on the same LAN, both with this addon enabled in the *same*
   project (copy the project to each, or use a shared checkout).
2. Machine A: **Host Session**, note the IP + code.
3. Machine B: **Join Session** with A's IP, port, and code.
4. On A, edit and **save** a script or scene → it appears on B within ~1 second,
   and vice-versa. Watch the player list and chat update.
