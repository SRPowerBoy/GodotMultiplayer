@tool
extends RefCounted
## Wire protocol for Godot Collab Host.
## All messages are JSON objects sent as WebSocket text frames.
## File payloads are transported as base64 strings inside JSON so that
## text and binary assets share one uniform code path.

const PROTOCOL_VERSION := 2
const DEFAULT_PORT := 8890
const INVITE_SCHEME := "godotcollab://"

# --- Message types --------------------------------------------------------
const T_HELLO := "hello"            # client -> host : join request + credentials
const T_WELCOME := "welcome"        # host -> client : accepted, assigns id + role
const T_REJECT := "reject"          # host -> client : bad code / protocol / banned
const T_ROSTER := "roster"          # host -> all    : current user list
## Before any file is written, the host sends the list of paths it is about to
## push. The joiner compares that against its own project and can back out
## before a single byte is overwritten.
const T_MANIFEST := "manifest"          # host -> client : what the snapshot contains
const T_SNAPSHOT_ACCEPT := "snap_ok"    # client -> host : go ahead
const T_SNAPSHOT_DECLINE := "snap_no"   # client -> host : cancel, I am leaving

const T_SNAPSHOT_BEGIN := "snap_begin"
const T_SNAPSHOT_END := "snap_end"  # host -> client : full project transfer bounds
const T_CHAT := "chat"              # any            : chat line
const T_SYSTEM := "system"          # host -> all    : join/leave/system notice
const T_FILE_CHANGE := "file_change"# client -> host : proposed file write (+ base_version)
const T_FILE_UPDATE := "file_update"# host -> clients: authoritative file content (+ version)
const T_FILE_REJECT := "file_reject"# host -> one    : conflict; authoritative copy follows
const T_FILE_DELETE := "file_delete"# any            : a file was deleted
const T_FILE_REQUEST := "file_request" # client -> host : please resend path
const T_PRESENCE := "presence"      # any            : current scene + selected nodes
const T_PING := "ping"              # keep-alive heartbeat
const T_PONG := "pong"              # heartbeat reply
const T_ROLE := "role"              # host -> client : your role changed
const T_KICK := "kick"              # host -> client : you were removed
const T_NICKNAME := "nickname"      # client -> host : change my display name

## Display names are user-supplied, so keep them short and free of characters
## that would break the roster or chat rendering.
const MAX_NICKNAME := 24

static func clean_nickname(raw: String) -> String:
	var n := raw.strip_edges()
	# Collapse whitespace and neutralise BBCode brackets, which would otherwise
	# let a name inject markup into the chat log.
	n = n.replace("\t", " ").replace("\n", " ").replace("\r", " ")
	n = n.replace("[", "(").replace("]", ")")
	while n.contains("  "):
		n = n.replace("  ", " ")
	if n.length() > MAX_NICKNAME:
		n = n.substr(0, MAX_NICKNAME).strip_edges()
	return n

# --- File ownership ("primary") ------------------------------------------
# Each collaborator may hold exactly one primary file at a time. Only the
# primary owner may push changes for that file; everyone else is view-only on
# it. Claims are granted by the host, which is the single source of truth.
const T_CLAIM := "claim"            # client -> host : request primary on a path
const T_CLAIM_RESULT := "claim_result"  # host -> client : granted / denied
const T_CLAIMS := "claims"          # host -> all    : full ownership map
const T_RELEASE := "release"        # client -> host : give up my primary
const T_HANDOVER := "handover"      # client -> host -> owner : please release this

# --- Roles ----------------------------------------------------------------
const ROLE_HOST := "host"
const ROLE_EDITOR := "editor"
const ROLE_VIEWER := "viewer"

# --- Timing (ms) ----------------------------------------------------------
const HEARTBEAT_INTERVAL := 3000    # how often each side sends a ping
const CONNECTION_TIMEOUT := 12000   # drop a peer we have not heard from in this long
## A primary claim is released automatically after this long with no actual
## edits, so merely having a file open never locks it away from everyone else.
const CLAIM_IDLE_RELEASE := 45000

# --- LAN discovery --------------------------------------------------------
const DISCOVERY_PORT := 8891        # UDP beacon port (host broadcasts here)
const DISCOVERY_MAGIC := "GODOT_COLLAB_BEACON_V2"
const DISCOVERY_INTERVAL := 2000    # ms between beacons
const DISCOVERY_EXPIRY := 7000      # forget a host we have not heard from in this long

# Distinct colors handed out to collaborators, indexed by user id.
const USER_COLORS := [
	"#4aa3ff", "#ff5a5a", "#57d977", "#f4c445",
	"#c86bff", "#ff8f43", "#39d6c8", "#ff6fb5",
]

static func color_for_id(id: int) -> String:
	return USER_COLORS[abs(id) % USER_COLORS.size()]

static func stringify(msg: Dictionary) -> String:
	return JSON.stringify(msg)

static func parse(text: String):
	var data = JSON.parse_string(text)
	if typeof(data) == TYPE_DICTIONARY:
		return data
	return null

# --- File payload encoding ------------------------------------------------
# Bytes travel as base64 inside JSON. Anything above the threshold is gzipped
# first, which typically cuts .tscn/.gd traffic by 60-80%. The receiver reads
# the "enc" field, so mixed compressed/plain payloads interoperate safely.

## Hard cap on a single inbound frame. Buffers are large so real assets fit,
## but an unbounded peer could otherwise exhaust the host's memory. Anything
## above this is dropped without being parsed.
const MAX_MESSAGE_BYTES := 24 * 1024 * 1024

## Flood protection: a peer may send at most this many messages per window
## before the host starts dropping them. Generous enough for a burst of saves,
## tight enough that a runaway loop cannot swamp the session.
const RATE_LIMIT_WINDOW := 1000   # ms
const RATE_LIMIT_MESSAGES := 120

## Paths arriving over the network are untrusted. Only plain project-relative
## resource paths are ever written to disk -- no traversal, no absolute paths,
## no Windows drive letters, no UNC paths.
static func is_safe_path(path: String) -> bool:
	if not path.begins_with("res://"):
		return false
	var rest := path.substr(6)
	if rest == "" or rest.begins_with("/"):
		return false
	if rest.contains("..") or rest.contains("\\") or rest.contains(":"):
		return false
	if rest.contains("//"):
		return false
	return true

## Absolute location of this project on disk. Two editors sharing one folder
## cannot collaborate -- they are the same files -- so peers compare this and
## refuse rather than corrupting each other.
static func project_fingerprint() -> String:
	return ProjectSettings.globalize_path("res://").to_lower()

## Engine version of this editor, e.g. "4.4". Scene and resource text formats
## differ between minor releases, so peers compare this and warn before they
## corrupt each other's files.
static func engine_version() -> String:
	var info := Engine.get_version_info()
	return "%d.%d" % [int(info.get("major", 0)), int(info.get("minor", 0))]

## True when two engine versions can safely exchange scenes and resources.
static func versions_compatible(a: String, b: String) -> bool:
	return a == b

const COMPRESS_THRESHOLD := 512
const COMPRESSION_MODE := FileAccess.COMPRESSION_GZIP

## Build the {data, enc, raw_size} fields for a file payload.
static func encode_payload(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() >= COMPRESS_THRESHOLD:
		var packed := bytes.compress(COMPRESSION_MODE)
		# Only keep the compressed form if it actually helped.
		if packed.size() > 0 and packed.size() < bytes.size():
			return {
				"data": Marshalls.raw_to_base64(packed),
				"enc": "gzip",
				"raw_size": bytes.size(),
			}
	return {"data": Marshalls.raw_to_base64(bytes), "enc": "raw", "raw_size": bytes.size()}

## Recover the original bytes from a message carrying a payload.
static func decode_payload(msg: Dictionary) -> PackedByteArray:
	var raw := Marshalls.base64_to_raw(str(msg.get("data", "")))
	if str(msg.get("enc", "raw")) == "gzip":
		var expected := int(msg.get("raw_size", 0))
		if expected <= 0:
			return PackedByteArray()
		var out := raw.decompress(expected, COMPRESSION_MODE)
		return out if out.size() == expected else PackedByteArray()
	return raw

# --- Invite links ---------------------------------------------------------
# A single copy-paste token that carries everything a collaborator needs:
#   godotcollab://192.0.2.10:8890/ABCD-4829

static func make_invite(ip: String, port: int, code: String) -> String:
	return "%s%s:%d/%s" % [INVITE_SCHEME, ip, port, code]

## Returns {ip, port, code} or null if the string is not a valid invite.
static func parse_invite(text: String):
	var t := text.strip_edges()
	if not t.begins_with(INVITE_SCHEME):
		return null
	t = t.substr(INVITE_SCHEME.length())
	var slash := t.find("/")
	if slash == -1:
		return null
	var host_part := t.substr(0, slash)
	var code := t.substr(slash + 1)
	var colon := host_part.rfind(":")
	if colon == -1:
		return null
	var ip := host_part.substr(0, colon)
	var port := int(host_part.substr(colon + 1))
	if ip == "" or port <= 0 or code == "":
		return null
	return {"ip": ip, "port": port, "code": code}
