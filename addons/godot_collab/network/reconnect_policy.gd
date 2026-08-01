@tool
extends RefCounted
## Decides whether and when to retry a dropped connection.
##
## Kept free of any editor or socket dependency so the behaviour can be tested
## headlessly -- retry logic that only runs during a real network failure is
## exactly the kind that rots unnoticed.

const MAX_ATTEMPTS := 6
const BASE_DELAY := 1.5
const MAX_DELAY := 20.0

var attempt := 0
var delay_left := 0.0
## Set when the user leaves on purpose (pressed Leave, or was kicked).
var deliberate := false

func reset() -> void:
	attempt = 0
	delay_left = 0.0
	deliberate = false

## Called when a connection drops. Returns true if a retry was scheduled.
func on_disconnected() -> bool:
	if deliberate or attempt >= MAX_ATTEMPTS:
		return false
	attempt += 1
	delay_left = next_delay(attempt)
	return true

## Exponential backoff, capped so retries never become uselessly rare.
static func next_delay(n: int) -> float:
	return minf(BASE_DELAY * pow(2.0, float(n - 1)), MAX_DELAY)

## Advance the timer. Returns true on the tick a retry should fire.
func tick(delta: float) -> bool:
	if delay_left <= 0.0:
		return false
	delay_left -= delta
	if delay_left > 0.0:
		return false
	delay_left = 0.0
	return true

func exhausted() -> bool:
	return attempt >= MAX_ATTEMPTS

## Called once a connection succeeds.
func on_connected() -> bool:
	var was_retrying := attempt > 0
	attempt = 0
	delay_left = 0.0
	return was_retrying
