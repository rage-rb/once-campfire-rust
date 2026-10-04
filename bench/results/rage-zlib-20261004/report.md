# Ruby Zlib Cable compression

The Rage benchmark now compresses the complete Action Cable JSON envelope through Ruby's
Zlib before Iodine publication/fan-out. Compression follows Rust's settings: level 6,
raw deflate, a fresh stream for each message, sync flush without the final four-byte trailer,
and a 256-byte minimum payload. There is no application compression toggle. Small messages
and protocol control messages remain JSON. Active Support's JSON escaping is preserved.

Iodine still sends text frames without extension negotiation or RSV1. The benchmark's
`--deflate 1` client therefore inflates non-JSON payloads independently of both. The runner
now selects that mode by default for both apps. `compressed_clients` continues to count
negotiated extensions; the new `inflated_frames` counts successfully decoded frames, so
Rage's zero negotiated clients cannot be mistaken for uncompressed traffic. This transport
is intended for this benchmark client, not a standard browser WebSocket client.

Validation: **14 Ruby tests, 158 assertions, no failures/errors/skips**; **2 loadgen socket
tests**; **3 report regression tests**; loadgen clippy with `--all-targets -- -D warnings`,
both Rust formatting checks, shell syntax and `git diff --check` pass. The Ruby suite compares
the entire inflated envelope with independently rendered reference ERB, including JSON
escaping. Its sample is 12,025 bytes before compression and 2,228 bytes after compression
(signed identifiers and timestamps can vary the compressed size). Two subscribed sockets
with the same identifier trigger one Zlib compression and one Iodine publication. Repeated
serialization round-trips with separate inflaters verify no context takeover.

All live runs use 100 clients, six subscriptions per client, three paced markers, two
closed-loop posters for five seconds, and no idle hold. All three runs have 100 ready clients,
zero failed clients or HTTP posts, and every marker delivered to all clients.

| Local run | Paced complete | Saturated complete / posted | Posts/s | Wire bytes per post/client | Inflated frames |
| --- | ---: | ---: | ---: | ---: | ---: |
| Rage before | 3/3 | 1,851/1,851 | 370.0 | 11,827.6 | 0 |
| Rage Ruby Zlib | 3/3 | 1,808/1,808 | 361.3 | 2,280.1 | 181,100 |
| Rust deflate | 3/3 | 9,972/9,972 | 1,994.2 | 2,269.6 | 997,500 |

Wire bytes per post/client divide saturated socket bytes by successful posts and clients;
they include the message envelope, unread update, frame headers and incidental pings.
Rage's average shrank about 80.7% and is within 0.5% of Rust in these runs. Neither byte
identity between compressors nor identical dynamic message IDs/timestamps is implied.
Rage negotiated compression on 0/100 sockets; Rust negotiated it on 100/100. Inflated frame
counts equal `(paced + saturated posts) * 100` for both compressed runs.

These are short functional/comparability measurements on macOS ARM64, not Raspberry Pi
throughput claims or evidence of a repeatable performance change. Both Rage runs preserve
the current configuration: Ruby 4.0.6 with YJIT enabled, Rage 1.28.0, rage-iodine 6.1.0,
four workers and in-memory Deferred scheduling. The baseline copies the app at `c6ca069`
before adding compression. Rust uses the existing native release build (Rust 1.94.0).
Every run starts with a fresh matching 80-message fixture populated through HTTP. Message,
Action Text and FTS counts match all setup and benchmark posts: 1,934 before, 1,891 after,
and 10,055 for Rust. No error/exception entries appear in the server logs.

Raw JSON, phase logs, process samples and environment metadata are retained here. The
single-PID Rage sampler observes only the parent, so its displayed CPU/RSS is not an
aggregate application measurement. Work databases, cookies and the temporary baseline
application are excluded.

To repeat with Ruby/Bundler on PATH and fresh work directories:

```sh
cd bench/rage && bundle exec ruby test/benchmark_test.rb
cd ../..
CARGO_TARGET_DIR=target/bench cargo test --manifest-path bench/loadgen/Cargo.toml
CARGO_TARGET_DIR=target/bench cargo build --release --manifest-path bench/loadgen/Cargo.toml
WORK="$PWD/bench/.work/rage-zlib-repeat" PORT=4665 \
  bench/results/pi-100k-20260928/run100k.sh bench/rage/bin/server rage 100 \
  --hold-secs 0 --latency-msgs 3 --tput-secs 5
WORK="$PWD/bench/.work/rust-zlib-repeat" PORT=4665 \
  bench/results/pi-100k-20260928/run100k.sh target/release/campfire rust 100 \
  --hold-secs 0 --latency-msgs 3 --tput-secs 5
```
