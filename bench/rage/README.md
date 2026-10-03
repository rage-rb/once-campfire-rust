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
schema only into an empty database, then creates the account, David and Everyone room. It does not
fill the 80 ordinary messages; the runner's preparation should do that via HTTP.

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
  existing runner posts an empty token; scrape exposes a placeholder. The Action View host also
  disables forgery protection, so inactive reaction forms omit CSRF hidden inputs. Include the
  actual frame size in comparisons; do not claim exact wire-byte parity until validated.
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

Initial manual sanity on macOS ARM64 / Ruby 4.0.6: production boot, Rails-cookie login, three-source
scrape, full 9,199-byte Turbo response, and one real loadgen client with all six confirmations,
zero failures, one complete paced marker and 86/86 complete saturated messages over one second.
These are functional checks, not performance measurements; later stages add tests and the shared
100-client runner before real Raspberry Pi measurements.
