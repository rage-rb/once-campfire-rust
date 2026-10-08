# Rails Cable compression benchmark

The pinned Action Cable transport does not enable WebSocket compression. Its
`Connection::ClientSocket` creates `WebSocket::Driver.rack` with protocols only;
it never registers a compression extension. The optional initializer at
[`reference/config/initializers/benchmark_cable_compression.rb`](../../reference/config/initializers/benchmark_cable_compression.rb)
adds the manual transport used by `bench/rage` directly to the Rails application.

With `BENCHMARK_CABLE_COMPRESSION=1`, envelopes of at least 256 encoded bytes use
Ruby Zlib level-6 raw deflate, a fresh stream for each envelope, and sync flush
with the four-byte trailer removed. The entire Action Cable JSON envelope is
compressed, preserving its exact identifier and Rails HTML escaping. Smaller
envelopes, including ordinary welcome/ping/unread messages, remain JSON.

Action Cable's Redis listener calls a worker-local `SubscriberMap` before
dispatching to that worker's subscribers. The initializer prepares one complete
envelope per distinct subscription identifier/connection coder **before** those
callbacks are scheduled, then reuses it for every matching subscriber. Default
JSON streams decode the broadcast once. There is no global or retained message
cache: the shared data/envelopes live only as long as the publication's queued
callbacks. Redis carries the original JSON and every Puma worker prepares its
own envelopes. Three workers with the same identifier therefore compress up to
three times per publication, not once across the whole server.

Custom stream callbacks/coders retain their original processing; their outgoing
messages and direct connection transmissions are compressed individually.
Channel transmit logging and notifications, authorization, Redis pub/sub,
presence, persistence, CSRF protection, rendering and jobs remain in place.

Like Rage, this sends compressed bytes as **text frames with RSV1 clear and no
`permessage-deflate` negotiation**. It requires the repository's loadgen with
`--deflate 1`; standard browser WebSocket clients cannot use this transport.
Expect `compressed_clients: 0` but positive `inflated_frames` when large messages
are delivered. HTTP compression from Thruster is separate.

## Enable on the server

Build the reference image and select fresh isolated storage from the repository
root on the Linux server (Docker, Python 3 and curl must be available):

```bash
git submodule update --init reference
docker build -f reference/Dockerfile -t campfire-rails:bench reference

export WORK="$PWD/bench/.work/rails-pi-compressed"
export SECRET_KEY_BASE=$(python3 -c 'print("a" * 128)') # benchmark key only
mkdir -p "$WORK/storage/db" "$WORK/storage/files"
sudo chown -R 1000:1000 "$WORK/storage"

RAILS_ARGS=(
  --env-file "$PWD/parity/.env.reference"
  -e "SECRET_KEY_BASE=$SECRET_KEY_BASE"
  -e RAILS_LOG_LEVEL=warn
  -e WEB_CONCURRENCY=3
  -e RAILS_MAX_THREADS=5
  --ulimit nofile=200000:200000
  -v "$WORK/storage/db:/rails/storage/db"
  -v "$WORK/storage/files:/rails/storage/files"
)

docker run --rm "${RAILS_ARGS[@]}" campfire-rails:bench bin/rails db:prepare
docker run -d --name campfire-rails-compressed --network host \
  "${RAILS_ARGS[@]}" -e BENCHMARK_CABLE_COMPRESSION=1 \
  -e HTTP_PORT=4555 -e TARGET_PORT=4556 -e PORT=4556 \
  campfire-rails:bench

curl -fsS http://127.0.0.1:4555/up
docker logs campfire-rails-compressed
APP_PID=$(docker inspect -f '{{.State.Pid}}' campfire-rails-compressed)
sudo python3 bench/sample_process.py --app-tree "$APP_PID" \
  > "$WORK/app-samples.jsonl" &
SAMPLE_PID=$!
```

This runs the original `bin/boot`: Thruster, Puma, Redis and Resque. Ports 4555,
4556 and 6379 must be free on the host; permit the load host to reach 4555.
The benchmark environment disables SSL. Three Puma workers/five HTTP threads
match the reference defaults on a four-core Pi; the original Resque config
selects two workers there. No emulated CPU quota is used. The sampler includes
the complete process tree, including Redis and Resque.

For a baseline, use a fresh storage directory and container name, and omit
`-e BENCHMARK_CABLE_COMPRESSION=1` (or set it to `0`). The initializer then installs
no hooks. Keep `--deflate 1` in the load-host command for both runs; a client offer
does not force baseline Rails to compress.

The image now includes the initializer from `reference/`; rebuild an older image
before enabling compression. For the native reference application, restart with
`BENCHMARK_CABLE_COMPRESSION=1`. To use it in another Rails installation, copy the
initializer into that installation's `config/initializers/` first.

The full reference diff is in [`reference-compression.patch`](reference-compression.patch).
The initializer is a new file, so unstaged `git diff` alone does not display it.
To view its complete addition without staging:

```bash
git -C reference diff --no-index -- /dev/null config/initializers/benchmark_cable_compression.rb
```

## Run from the separate Linux load host

Use the same external runner as `bench/rage/README.md`. With Python 3, curl and
Rust/Cargo installed, it builds the native loadgen automatically:

```bash
sudo prlimit --pid "$$" --nofile=200000:200000
ulimit -n 200000
export PI_BASE=http://192.168.1.50:4555
# These must be real addresses assigned to this host and routable to the Pi.
export LAN_SOURCES=192.168.1.101,192.168.1.102,192.168.1.103,192.168.1.104
export CLIENT_WORK="$PWD/bench/.work/rails-pi-compressed-client"

WORK="$CLIENT_WORK" BASE="$PI_BASE" PREPARED=0 SOURCES="$LAN_SOURCES" \
  bench/results/pi-100k-20260928/run100k.sh - rails-compressed 100 --deflate 1

# Scale through 1,000 and 10,000 before attempting 100,000.
WORK="$CLIENT_WORK" BASE="$PI_BASE" PREPARED=0 SOURCES="$LAN_SOURCES" \
  bench/results/pi-100k-20260928/run100k.sh - rails-compressed 100000 --deflate 1
```

`PREPARED=0` performs the normal Rails first-run flow and posts the initial 80
messages. Credentials are `david@example.com` / `secret123456`, with David Hansson
in All Talk (room 1). Login and scrape retain the Rails session cookie and CSRF
token for the measured POSTs. Reusing CLIENT_WORK skips preparation and reuses
those artifacts; measured messages accumulate in the server database. Start the
final measured comparison with fresh server storage and CLIENT_WORK.

Four source addresses need at least 25,000 available ephemeral ports each. Check
`sysctl net.ipv4.ip_local_port_range` and allow TIME_WAIT to expire between runs.
The workload is six subscriptions per socket, 30 seconds idle, ten paced posts
at 200 ms intervals, two saturated posters for ten seconds, then delivery drain.
The runner validates all clients, HTTP POSTs and marked deliveries.

After the run, on the server:

```bash
sudo kill "$SAMPLE_PID"
wait "$SAMPLE_PID"
docker stop campfire-rails-compressed
docker logs campfire-rails-compressed > "$WORK/log" 2>&1
```

## Validation and encoding measurements

Using the reference bundle, from the repository root:

```bash
BUNDLE_GEMFILE="$PWD/reference/Gemfile" bundle exec ruby \
  bench/rails/test/benchmark_cable_compression_test.rb

for mode in plain per-client shared; do
  BUNDLE_GEMFILE="$PWD/reference/Gemfile" bundle exec ruby \
    bench/rails/measure_compression.rb "$mode"
done
```

Tests inspect real Action Cable/websocket-driver frame bytes, complete envelope
round-trips and matching Rage output; verify compression precedes worker delivery
and runs once per identifier/publication; and cover custom callbacks/coders,
small frames, incoming JSON and opt-in hooks before/after class loading.
The microbenchmark compares stock fan-out, compression per client and shared
compression. `CLIENTS`, `BROADCASTS` and `PAYLOAD` (a file containing captured
Turbo HTML) customize it. It measures encoding/delivery callbacks, not actual
network traffic, Redis, full server capacity or Pi performance.
