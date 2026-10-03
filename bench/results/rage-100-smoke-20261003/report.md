# Rust / Rage 100-client functional benchmark checks

All five runs passed the updated common runner: **100 ready clients, six subscriptions per client,
zero failed clients, zero HTTP failures, every paced and saturated marker received by all clients**.
This is a functional acceptance run on one macOS ARM64 machine. App and loadgen both used localhost;
these rates are not Raspberry Pi measurements or estimates, and do not represent a physical network.

Host: macOS 26.7.1 / Darwin 25.6.0, ARM64, 12 logical cores available. Rust 1.94.0 (the locally
available toolchain, not Docker's 1.98.1), Ruby 4.0.6, Rage 1.28.0, rage-iodine 5.6.0. Rage reported
one worker × one thread, with one PID sampled. Rust uses its native runtime threads. Loadgen used
Tokio's default available-core worker count with no affinity; neither app had a CPU quota.
Local resource samples are **RSS**, not the Linux PSS used in the September report.

| Run | Paced complete | Saturated attempted / posted / complete | All-client paced p50 / p99 | Wire MB/s | Compressed sockets |
| --- | ---: | ---: | ---: | ---: | ---: |
| Rust raw | 10 / 10 | 21,258 / 21,258 / 21,258 | 1.576 / 1.978 ms | 2516.2 | 0 / 100 |
| Rage raw | 10 / 10 | 2,462 / 2,462 / 2,462 | 10.903 / 24.863 ms | 291.0 | 0 / 100 |
| Rust compression offer | 10 / 10 | 20,350 / 20,350 / 20,350 | 1.491 / 3.941 ms | 462.6 | 100 / 100 |
| Rage compression offer (short smoke) | 1 / 1 | 76 / 76 / 76 | 217.983 / 217.983 ms | 89.2 | 0 / 100 |

Raw runs used the original 30-second idle hold, 10 paced markers at 200 ms, two closed-loop posters
for 10 seconds and the existing delivery-drain deadlines. The Rust compression-offer run used the
same phases. The additional Rage negotiation check used `--hold-secs 0 --latency-msgs 1
--tput-secs 1`; it verifies the protocol and is not a throughput comparison. Compression checks
reused each implementation's work directory after the raw run, so database sizes differ; only the
first raw runs start from the matching 80-message fixtures.

Wire counts include WebSocket headers, unread frames and three-second protocol pings, excluding
HTTP/TCP headers and the upgrade. For the raw saturated runs, observed bytes / successful POST /
client are approximately **11,837 Rust** and **11,830 Rage**, including the small unread frame and
pings. IDs/timestamps vary. That close size checks the full message workload, not a marker-only
payload. The focused suite separately compares the complete Rage frame and untouched reference
ERB byte for byte with matching fixture/host and CSRF disabled: its fixture is 12,025 JSON bytes /
9,557 HTML bytes. CSRF/render/cache/deferred differences are documented in `bench/rage/README.md`.

Preparation used separate fresh WORK directories. Rage `bin/prepare` seeded through reference
`FirstRun.create!`; Rust used the reference-compatible first-run HTTP flow. Both had exactly
Campfire / David Hansson / All Talk, one administrator, one open room and one membership, all id 1,
with no push subscriptions. Both then posted **80 identical seeded-random ordinary bodies through
HTTP**, logged in and scraped exactly one RoomMessages and two Turbo stream sources.
The setup count is also checked from final persistent rows minus all successful measured posts:

| Implementation | Messages / Action Text / FTS after raw | After compression check | Initial fill |
| --- | ---: | ---: | ---: |
| Rust | 21,348 each | 41,708 each | 80 |
| Rage | 2,552 each | 2,629 each | 80 |

After clean Rage shutdown, its real disk-backed Deferred backend reported **zero pending tasks**;
its dead-task file was empty and the retained final server log contained no task errors. No real
push recipient exists in this fixture. Preparation, membership writes, enqueue and native task
execution are enabled, as are the reference message/rich-text/room-touch/FTS/bot/render paths.

Commands from repository root (Ruby 4.0.6 on PATH):

```sh
CARGO_TARGET_DIR=target/bench cargo build --release --manifest-path bench/loadgen/Cargo.toml
WORK="$PWD/bench/.work/rust-100-smoke-20261003" PORT=4565 \
  bench/results/pi-100k-20260928/run100k.sh target/release/campfire rust-raw 100
WORK="$PWD/bench/.work/rage-100-smoke-20261003" PORT=4566 \
  bench/results/pi-100k-20260928/run100k.sh bench/rage/bin/server rage-raw 100
WORK="$PWD/bench/.work/rust-100-smoke-20261003" PORT=4565 \
  bench/results/pi-100k-20260928/run100k.sh target/release/campfire rust-deflate 100 --deflate 1
WORK="$PWD/bench/.work/rage-100-smoke-20261003" PORT=4566 \
  bench/results/pi-100k-20260928/run100k.sh bench/rage/bin/server rage-deflate 100 \
  --deflate 1 --hold-secs 0 --latency-msgs 1 --tput-secs 1
```

Validation: focused Ruby suite **13 tests / 149 assertions / zero failures, errors or skips**;
reporter regressions **3 tests** covering missing clients/subscriptions, hidden HTTP failures,
incomplete and empty delivery; loadgen's local HTTP regression **1 test** verifies 200 succeeds
and 302/503 fail. Loadgen clippy with `--all-targets -- -D warnings`, both Rust formatting checks,
shell syntax and Python compilation pass. No whole-workspace Rust test run was needed for these
benchmark-only changes; the focused Ruby suite owns its seed and skips nothing.

The runner now supports `BASE=http://pi:4555` with `BIN=-`, assigned Ethernet `SOURCES` and a
standalone Pi PID sampler. See `bench/rage/README.md` for preparation, limits, commands and clock
alignment. The updated client fixes the shared-counter handshake gate, bounds each upgrade by
30 seconds, counts every attempted/failed POST, rejects redirects and unexpected socket closure,
and removes the accidental second idle hold after saturation. Frame counts now include every
observed frame, and unobserved wire metrics are null. These changes are explicit corrections to
the September orchestration, so this is not an exact replay of its CPU-quota/affinity setup.

The real Pi / external Ethernet / 100,000-client run remains to be performed on the user's hardware.
No Pi connection details were available during this stage. Committed artifacts include only
result JSON, phase logs, samples, summaries and fixture counts; work databases/cookies are excluded.

Additional external-branch check: a separately launched Rage server on `http://127.0.0.1:4568`,
with fresh server and client WORKs, passed `BASE=http://127.0.0.1:4568 PREPARED=1 SOURCES=""`
`run100k.sh - rage-external-localhost 100 --hold-secs 0 --latency-msgs 1 --tput-secs 1`.
All 100 clients confirmed six subscriptions, the one paced and 199 saturated POSTs were received
by all clients, and no HTTP/client failures occurred. The runner left the separately owned server
alive and sampled only the loadgen, with empty app metrics. Its final 280 message rows confirm the
80-message HTTP preparation. This simulates process ownership/orchestration on localhost and does
not validate Pi hardware or assigned-LAN-source routing. Raw artifacts use the
`rage-external-localhost` label.
