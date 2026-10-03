# Rage slice benchmark review

Reviewed commits `87a1a3b` and `2456488` against `100k_PARTS.md`, the pinned reference,
and installed Rage 1.28.0 / rage-iodine 5.6.0 source. The review concerns benchmark
workload validity; this application deliberately implements only the measured slice.

The message path retains reference model callbacks, Action Text and FTS persistence,
room touch, unread update, two synchronous broadcasts, bot lookup, full ERB rendering,
and a second cached render for the HTTP response. HTTP and Cable use the real Rails
signed cookie jar. Room-message subscriptions derive membership authorization from
the verified stream; the generic Turbo channel rejects guarded message streams.
Presence runs the reference membership writes on subscribe and disconnect.

Fixed a preparation mismatch: the earlier fixture used Benchmark / David / Everyone,
while `fill.py` uses Campfire / David Hansson / All Talk. Names change rendered payload
bytes. Preparation now calls the reference `FirstRun.create!`; preparation and server
startup reject an incompatible dataset instead of allowing extra users, bots or push
subscriptions to add work or trigger unsupported deferred delivery. Validation runs
before the listening socket opens, not on the measured message path. Existing valid
records are preserved, and partial first-run data is rejected before seeding.

Validation on macOS ARM64, Ruby 4.0.6:

- Focused suite: **13 tests, 149 assertions, zero failures/errors/skips**.
- Complete Rage and untouched reference ERB / Action Cable envelopes match byte for
  byte with the same dataset and CSRF disabled. The test fixture frame is 12,025 bytes
  for 9,557 bytes of HTML. Enabling the eight Rails reaction-form CSRF tokens adds
  1,152 HTML bytes / 1,280 JSON-frame bytes. Real markers and client IDs change lengths.
- Fresh preparation followed by repeated preparation succeeds with one user/room.
- Live Iodine server reports **1 worker × 1 thread**, one process. A real authenticated
  HTTP POST returned 200 and 9,095 bytes, created one message/rich-text/FTS row, and left
  **zero pending disk-backed Deferred tasks** after clean shutdown, with no task errors.
  This checks native task execution, beyond the suite's transport/timer substitutes.

The differences already documented in `bench/rage/README.md` remain intentional:
memory fragment cache, persistent in-process Deferred, omitted CSRF/rate limiting,
skeletal setup pages, uncompressed WebSockets and the measured Rack form-parse workaround.
No production-hardening or unrelated browser-flow changes were added.

The next stage must run the common runner with 100 clients against both implementations,
check every marker and POST attempt, fill the same 80 ordinary messages, and use fresh
work directories for older Rage fixtures. The load generator already defaults to all
available logical cores; removing the runner's fixed taskset satisfies that requirement.
Real Pi results still require an external load host, real source IPs, Linux resource
sampling, reported compression behavior, and matching prepared data. Local smoke runs
verify functionality and are not Raspberry Pi performance estimates.
