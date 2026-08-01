# Godot Collab Host

**Real-time collaboration inside the Godot editor. One person hosts — no server, no account, no cloud.**

The person who starts the session *is* the server. Everyone else connects straight to
them, and edits flow between editors as you save.

Tested against **Godot 4.4.1** and **Godot 4.7.1**.

---

## Install

1. Download the latest release and unzip it at the **root of your Godot project**
   (the folder containing `project.godot`) — it contains an `addons/` folder that
   merges with yours.
2. **Project → Project Settings → Plugins →** enable **Godot Collab Host**.
3. A **Godot Collab** tab appears in the bottom bar.

> Unzip at the project root, **not** inside `addons/` — the archive already
> includes the `addons/` prefix.

## Use

**Host:** open the *Session* tab, pick a name and port, click **Host Session**.
You get an invite link (`godotcollab://192.168.1.20:8890/ABCD-4829`) and a code.

**Join:** sessions on your network appear automatically under *Found nearby* —
click **Use** and enter the code. Or paste an invite link, or type the IP by hand.

Before anything is written you get a **review dialog** listing exactly which of
your files would be overwritten. Nothing transfers until you accept.

---

## What it does

- **File sync** on save — scripts, scenes, resources and assets
- **File ownership** — you hold one "primary" file at a time; others are view-only on it,
  claims release automatically when idle, and scripts you don't own are locked read-only
- **Host-authoritative conflict resolution** with per-file version numbers
- **Automatic LAN discovery** — hosts advertise, joiners see them listed
- **UPnP port forwarding** for internet sessions (falls back to manual forwarding)
- **Compression** — payloads gzipped before transfer
- **Backups** of everything overwritten, with a browser to restore or clear them
- **Presence** — who's connected, what they're editing, who holds what
- **Chat** with per-project history
- **Roles** — host / editor / viewer, plus kick and promote
- **Auto-reconnect** with exponential backoff, and an offline edit queue

## Honest limitations

- **Sync happens on save**, not per keystroke. Two people editing the *same* file
  between saves is resolved at file level, not merged.
- **No live cursors in the viewport.** Godot exposes no API for it. Presence is
  shown as "who has what selected", which is the achievable form.
- **Scenes cannot be truly locked** — you'll see a 🔒 banner and your changes
  won't sync, but the editor won't stop you typing. Scripts *are* hard-locked.
- **Networking is LAN + UPnP/manual port forwarding.** No NAT hole-punching and
  no relay server — that would require the infrastructure this deliberately avoids.
- **Traffic is unencrypted `ws://`.** Fine on your own LAN; not suitable for
  anything sensitive over the internet.
- **Joining overwrites files** with the same path (backed up first, and shown to
  you beforehand). Join from a scratch project unless you mean to replace this one.
- **`project.godot` and `addons/` are not synced** — they're per-machine. A joiner
  may need to set up autoloads and input maps themselves.
- **Both sides should run the same Godot version.** Scene formats differ between
  minor releases; mismatches are detected and warned about, not prevented.

## Requirements

- Godot 4.4+ (verified on 4.4.1 and 4.7.1)
- Everyone on the same LAN, or a reachable host (UPnP or forwarded port)
- **A separate copy of the project per person** — two editors on one folder is
  detected and refused

---

## Tests

```bash
godot --headless --path . --script res://_test_net.gd
godot --headless --path . --script res://_test_filesync.gd
godot --headless --path . --script res://_test_claims.gd
godot --headless --path . --script res://_test_ui.gd
godot --headless --path . --script res://_test_discovery.gd
godot --headless --path . --script res://_test_resilience.gd
godot --headless --path . --script res://_test_joinflow.gd
```

252 checks covering the protocol, file sync, ownership, UI gating, LAN discovery,
resilience (reconnect, rate limits, path traversal, fuzzing) and the join handshake.

`_test_twoproc_host.gd` / `_test_twoproc_client.gd` run a host and client as two
separate Godot processes over a real socket.

## Layout

```
addons/godot_collab/
  plugin.cfg / plugin.gd      EditorPlugin entry + orchestrator
  network/                    protocol, host server, client, LAN discovery,
                              reconnect policy, UPnP
  sync/                       file watcher, scene/resource refresh, backups, logs
  presence/                   focus tracking, selection presence
  ui/                         bottom panel, chat
```

## License

MIT — see [LICENSE](LICENSE).
