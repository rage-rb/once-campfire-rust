# Rage benchmark slice

This is the authenticated message/Cable slice, using Rage 1.28.0
It serves benchmark HTTP and all six Cable subscriptions through Rage,
while Rails supplies Active Record, Action Text, Action View, Turbo signing, and code loading.
The pinned `reference/` models, helpers, ERB and route helpers are read directly, never modified.
This is a benchmark application; the rest of Campfire's browser flows are not implemented.

From the repository root, with Ruby 4.0.6 and Bundler on PATH:

```sh
cd bench/rage
bundle install
cd ../..
export SECRET_KEY_BASE=$(printf 'a%.0s' {1..128}) # reproducible benchmark key only
export CAMPFIRE_STORAGE_PATH="$PWD/bench/.work/rage/storage"
bench/rage/bin/prepare
HTTP_PORT=4555 bench/rage/bin/server
```

`bin/server` accepts the runner's unused `server` argument, preserves the storage path and maps
`HTTP_PORT` to Rage's port. It runs one worker in production, with in-process Cable and Deferred.
`DATABASE_PATH` can select an existing compatible SQLite database. Use an isolated benchmark copy:
messages, sessions and membership presence are real writes. `bin/prepare` loads the exact reference
schema only into an empty database, then calls the reference `FirstRun.create!` with the same
Campfire account, David Hansson administrator and All Talk room as `fill.py`. It does not
fill the 80 ordinary messages; the runner's preparation should do that via HTTP.
Preparation and server startup reject a different dataset: exactly one active administrator and
open room (both id 1), one mentions membership and no push subscriptions are required. Names and
credentials must match `fill.py`, since names affect every message's payload. Existing valid data
is preserved; use a fresh isolated work directory for older Rage fixtures named David/Everyone.

The implemented routes are `/up`, `/`, `/session/new`, `/session`, `/rooms/:id`,
`/users/me/sidebar`, `/rooms/:room_id/messages` and `/cable`. Login uses the reference password
check, Session model and Rails signed cookie jar. HTTP and Cable share the same session lookup.
Turbo signatures use the reference key derivation and `campfire` GlobalIDs, so existing preparation
artifacts can be shared when the secret and data match. Each HTTP action and deferred task resets
fiber-local `Current`; Cable authenticates without changing it.

Every POST preserves reference message/rich-text persistence, room touch, FTS insert, unread
membership updates, native Deferred push enqueue, both empty push recipient queries, the empty bot
lookup, full message partial render, synchronous large/small broadcasts and Turbo HTTP response.
The response renders again, using the message fragment cached by the broadcast as in Rails.

Deliberate benchmark differences:

- Setup pages are skeletal scrape HTML. First-run forms, browser assets, uploads, editing, boosts,
  and other browser endpoints are outside the slice. The full message ERB still includes their
  original markup and URLs. The fixture command replaces the first-run flow.
- Forgery protection and login rate limiting are disabled for this controlled benchmark. The
  scrape exposes a placeholder token, which the updated runner forwards. The Action View host also
  disables forgery protection, so inactive reaction forms omit CSRF hidden inputs. Include the
  actual frame size in comparisons. Tests compare complete HTML and JSON frames with the
  untouched reference ERB: with matching host/data and CSRF off they are byte-identical.
  Enabling Rails' eight masked reaction-form tokens adds 1,152 HTML bytes / 1,280
  uncompressed JSON-frame bytes. Rust also deliberately omits these tokens.
- The Rails fragment cache is an in-process MemoryStore rather than Redis, without changing the
  two render calls. No Redis service, Resque process or Action Cable server handles requests.
- Native Rage::Deferred uses its disk WAL and executes push lookup in the same process. The
  benchmark pool evaluates the reference subscriptions and raises if any real recipient exists;
  network push delivery and webhook jobs are outside the intended one-user, no-bot dataset.
- Rage/Iodine uses its stock Action Cable JSON protocol with three-second pings and no advertised
  `permessage-deflate` support. Report actual uncompressed frame/on-wire lengths. Active Support's
  `to_json` supplies Rails HTML escaping; never pre-encode the broadcast string.
- Runtime production log level defaults to warn. Development reloading is outside this slice;
  use production or test mode when validating against the pinned Rails development version.

The shared 100-client live checks and their raw results are recorded in
[`../results/rage-100-smoke-20261003/report.md`](../results/rage-100-smoke-20261003/report.md).
These validate preparation, native scheduling and delivery; they are not Pi measurements.

Run the focused acceptance suite with the bundled reference test dependencies:

```sh
cd bench/rage
bundle exec ruby test/benchmark_test.rb
```

It owns a fresh temporary SQLite database and Deferred WAL, with no seed/Docker requirement.
Thirteen tests cover benchmark dataset validation, HTTP and Cable cookie authentication, three scrape streams, six protocol
confirmations, signed-stream/membership guards, presence counts and disconnect, full message
HTML/Action Cable escaping, persistence/FTS/room touch, real disk enqueue and both empty push
queries, plus fiber-local `Current` cleanup. Tests use the same synchronous fiber shim as
`rage/rspec` and substitute socket transport/timers; live Iodine scheduling, pings and networking
are checked by the real loadgen smoke runs. No tests are skipped for missing benchmark data.

## Shared runner and local smoke

Build the load generator once; its Tokio runtime uses all available logical cores by default.
The runner no longer supplies a fixed affinity or a CPU quota. `APP_CPUS` and `LOADGEN_CPUS`
are optional Linux `taskset` selections; leave both unset for a real Pi/external load host.

```sh
CARGO_TARGET_DIR=target/bench cargo build --release --manifest-path bench/loadgen/Cargo.toml
WORK="$PWD/bench/.work/rust-smoke" PORT=4555 \
  bench/results/pi-100k-20260928/run100k.sh target/release/campfire rust 100
WORK="$PWD/bench/.work/rage-smoke" PORT=4555 \
  bench/results/pi-100k-20260928/run100k.sh bench/rage/bin/server rage 100
```

Local Rage preparation automatically runs `bin/prepare`. Both implementations then use the same
`fill.py` body generator to POST 80 messages through HTTP, log in and scrape exactly three distinct
stream sources. `fill.py --prepared` skips only the first-run form, which Rage replaces with the
fixture command. Save a separate WORK for each implementation and secret/base combination.
Subsequent runs with the same WORK reuse the cookie and scrape, preserving the initial 80-message
fill but accumulating benchmark messages. Use fresh WORKs for measured comparisons.

The default measured phases remain 30 seconds idle, 10 paced markers at 200 ms intervals and two
closed-loop posters for 10 seconds, then delivery drain. `--wire 1` counts actual WebSocket bytes
and frames with compression disabled for a comparable raw transport. Add `--deflate 1` to offer
browser compression; JSON reports both the offer and number of sockets that negotiated it.
Rust accepts it; stock Rage/Iodine declines it. A comparison with that offer measures each native
transport, including the compression difference. `frames_per_sec` now includes all socket frames
(pings/unreads included); `deliveries_per_sec` retains the separate marked-delivery count.
No measured wire count is represented as zero when `--wire 0 --deflate 0` disables observation.

The runner exits unsuccessfully on a missing client, fewer than six subscriptions, any failed HTTP
POST, or incomplete paced/saturated delivery. A login redirect is a failed POST. Every attempted
saturated POST is reported so failed requests cannot disappear from throughput. WebSocket upgrades
have a 30-second deadline and retain their own slot in the 50-handshake limit. The previous client
shared connection counter could release another client's slot; that is corrected. The accidental
second idle hold after saturation is removed. These corrections and the real-network topology
mean this is a reproduction of the workload, not an identical replay of the older emulated-host
orchestration in the September report.

Local runs sample only PIDs launched by the runner, clean up those processes on exit, and refuse to
launch over an already listening app. Linux records PSS and CPU from `/proc`; macOS records RSS and
CPU from `ps` and labels that distinction. App CPU/memory exclude the loadgen. External mode samples
only the loadgen on its own host; sample the one-process app separately on the Pi.

## Real Raspberry Pi 5 and external load host

On the Pi, install this checkout's pinned Ruby/bundle (or build Rust), keep the `reference/`
submodule checked out, and arrange an open-file limit above the socket count on both machines
(for example `ulimit -n 200000`, with a corresponding hard limit). No emulated CPU quota is used.
The following launches Rage and samples its actual single worker/process:

```sh
# Pi, repository root. Choose a fresh WORK for each measured comparison.
export WORK="$PWD/bench/.work/rage-pi"
export CAMPFIRE_STORAGE_PATH="$WORK/storage"
export SECRET_KEY_BASE=$(python3 -c 'print("a" * 128)') # benchmark key
mkdir -p "$WORK"
bench/rage/bin/prepare
HTTP_PORT=4555 bench/rage/bin/server > "$WORK/log" 2>&1 &
APP_PID=$!
python3 bench/sample_process.py --app "$APP_PID" > "$WORK/app-samples.jsonl" &
SAMPLE_PID=$!
# After the load-host run, stop these exact PIDs and retain app-samples.jsonl/log:
# kill "$SAMPLE_PID" "$APP_PID"; wait "$SAMPLE_PID" "$APP_PID"
```

For Rust, use a separate WORK and the same key/storage exports, then replace Rage preparation and
launch with `DISABLE_SSL=1 HTTP_PORT=4555 TARGET_PORT=4556 target/release/campfire server`.
Its empty database first-run flow is prepared remotely by `fill.py`; use `PREPARED=0` below.
Run the servers one at a time on the same Pi port. A single Rage worker/thread is deliberate;
if changing the worker topology, aggregate every worker's CPU/memory and disclose it.

On the separate Linux load host:

```sh
# PI_BASE is the Pi Ethernet address; LAN_SOURCES are real IPv4 addresses assigned to this host.
# Supply enough source/destination port pairs for 100k, considering ip_local_port_range/TIME_WAIT.
export PI_BASE=http://192.168.1.50:4555
export LAN_SOURCES=192.168.1.101,192.168.1.102,192.168.1.103,192.168.1.104
WORK="$PWD/bench/.work/rage-pi-client" BASE="$PI_BASE" PREPARED=1 SOURCES="$LAN_SOURCES" \
  bench/results/pi-100k-20260928/run100k.sh - rage-pi 100000 --deflate 0
# Rust: fresh Pi storage and load-host WORK, PREPARED=0, label rust-pi, same workload.
```

The example source addresses must actually be assigned to the load host; loopback source addresses
are rejected in external mode. Four sources suffice only when the configured ephemeral-port range
provides at least 25,000 available ports each; additional sources or cooldown may be needed between
runs. Connect through Ethernet to measure the real network limit. First validate 100, then 1,000
and 10,000 clients before 100,000. Synchronize clocks if merging Pi samples with load-host PHASE
Unix timestamps. The sampler reports one PID; the native Rage launch uses one process.

Runner regression checks: `python3 -m unittest bench/test_cable_report.py` and
`CARGO_TARGET_DIR=target/bench cargo test --manifest-path bench/loadgen/Cargo.toml`.
