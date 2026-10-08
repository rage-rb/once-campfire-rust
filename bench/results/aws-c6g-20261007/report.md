# AWS Rails / Rage fan-out results, 2026-10-07

These are **remote AWS measurements reconstructed on 2026-10-08**.
No benchmark was executed on the local machine to produce this archive. JSON formatting has
been normalized; these are recovered measurements, not byte-for-byte copies of the original files.

The server was reported as `c6g.xlarge`, and the separate load-generator host as
`m8azn.3xlarge`. Rails was reported to use Ruby 4, four Puma workers with five threads each,
Redis, Resque, and manual compression matching Rage.
Exact software versions, revisions, database states, and per-PID service identities were not recorded.

## Comparison

The first Rails run remains the primary comparison entry. Its retry is retained separately:
the retry still has a long saturated tail, so neither attempt is discarded as an outlier.
All runs confirmed six subscriptions per client, zero failed clients or HTTP posts, and
complete delivery of every posted marker.

| Run | Ready clients | Connect (s) | Paced to-all p50 / p99 (ms) | Saturated to-all p50 / p99 (ms) | Deliveries/s | Wire MB/s | Saturated complete |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [Rails 10k (first)](cable-rails-10k-ruby-4.json) | 10,000 | 29.36 | 2385.919 / 3346.431 | 2998.271 / 13754.367 | 8,709 | 19.9 | 12 / 12 |
| [Rails 10k (retry)](cable-rails-10k-ruby-4-2.json) | 10,000 | 29.47 | 2291.711 / 3186.687 | 2965.503 / 11214.847 | 9,162 | 21.0 | 12 / 12 |
| [Rage / Active Record 50k](cable-rage-c6-50k-active-record.json) | 50,000 | 49.37 | 343.551 / 476.927 | 1074.175 / 1723.391 | 206,282 | 471.6 | 45 / 45 |
| [Rage / Sequel 50k](cable-rage-c6-50k.json) | 50,000 | 27.80 | 422.143 / 556.031 | 1189.887 / 1694.719 | 192,149 | 438.7 | 42 / 42 |
| [Rage / Sequel 100k](cable-rage-c6-100k.json) | 100,000 | 61.32 | 864.767 / 1112.063 | 1891.327 / 2224.127 | 187,964 | 429.7 | 22 / 22 |

A delivery is one posted message received by one client, not one room-wide broadcast.
Client counts differ, so aggregate delivery throughput is more useful than room-wide posts/s
for this comparison. These short, single-room runs do not establish sustained production capacity
or isolate the cost of the framework, ORM, Ruby version, or additional services.

## Server resources

Derived from the pasted server samples, not from the load-generator console's memory figures.
CPU cores = change in cumulative process-tree CPU seconds / elapsed sample time.
Idle memory is the highest sample during the idle hold. Active peak covers connect through done;
overall peak also includes pre-run and post-disconnect samples.

| Run | Idle PSS (GiB) | Active peak PSS (GiB) | Overall peak PSS (GiB) | Connect cores | Idle cores | Saturated + drain cores | Samples | Active process count |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Rails 10k (first) | 2.34 | 2.52 | 2.55 | 3.57 | 0.25 | 3.62 | 115 | 13 |
| Rails 10k (retry) | 2.33 | 2.62 | 2.63 | 3.55 | 0.23 | 3.87 | 112 | 13 |
| Rage / Active Record 50k | 4.67 | 4.71 | 4.71 | 3.89 | 0.16 | 3.66 | 118 | 5 |
| Rage / Sequel 50k | 3.03 | 3.14 | 3.14 | 3.90 | 0.18 | 3.55 | 91 | 5 |
| Rage / Sequel 100k | 5.90 | 5.95 | 5.95 | 3.85 | 0.30 | 3.55 | 125 | 5 |

These are sampled process-tree PSS totals, not whole-machine or cgroup memory usage; kernel TCP
buffers are excluded. Rails' 13 processes include the sampled app tree and cannot be identified
from PID lists alone; the count is not its Puma thread count. Rage's active sample tree has five
processes. Resource scope therefore differs between configurations.

CPU uses the first and last samples within each phase, without boundary interpolation. The
saturated resource figure above includes delivery drain; the existing reporter splits drain
into a separate phase when enough samples exist. Short phases have few samples. All derived
values, exact sample spans, and counts are retained in [derived-metrics.json](derived-metrics.json).

## Rails tail

| Metric | First Rails 10k | Retry Rails 10k |
| --- | ---: | ---: |
| Saturated HTTP POST p50 | 949.759 ms | 948.735 ms |
| Saturated HTTP POST p99 / maximum | 13,778.943 ms | 13,099.007 ms |
| Saturated all-clients p99 / maximum | 13,754.367 ms | 11,214.847 ms |
| Saturated per-client p99 | 13,180.927 ms | 10,477.567 ms |
| Actual saturated posting phase | 13.779 s | 13.097 s |

Each Rails attempt has only 12 saturated POST observations, so its POST and all-client p99
equal the observed maximum. Both attempts reproduce a slow request. The nominal ten-second
posting phase can run longer while awaiting in-flight HTTP requests. Zero drain means that
delivery had completed when all POSTs returned; it does not imply low delivery latency.
These aggregates do not establish the cause or identify which request stalled.

## Artifacts and provenance

- `cable-<label>.json`: complete result JSON as pasted, with normalized formatting.
- `cable-<label>.err`: exact supplied PHASE lines only; other stderr was not supplied.
- `samp-<label>.jsonl`: full supplied remote app-samples series, including startup/cleanup;
  original empty `loadgen` objects are preserved. No missing client samples were fabricated.
- `summary-<label>.txt`: original pasted console summary, including client resource metrics.
  Its memory label says MB but the reporter divides KiB by 1024 (MiB); wire MB/s is decimal.
- [commands.txt](commands.txt): user-supplied invocations; unresolved environment variables
  intentionally remain unresolved. These commands were not executed during archival.
- [metadata.json](metadata.json), [env.txt](env.txt): provenance, reported setup, and unknowns.
- [validation.txt](validation.txt): parsing, sample chronology, and completeness checks.

The use of the Pi-named runner does not make these Raspberry Pi or local-host measurements.
No server logs, secrets, database snapshots, client sample series, exact revisions, or verified
fixture counts were recovered. Dataset equivalence, runtime limits, network burst state, and
long-term behaviour remain unverified.

To re-analyze the archived result and server samples without launching any benchmark:

```sh
python3 bench/cable_report.py bench/results/aws-c6g-20261007 rails-10k-ruby-4
python3 bench/cable_report.py bench/results/aws-c6g-20261007 rails-10k-ruby-4-2
python3 bench/cable_report.py bench/results/aws-c6g-20261007 rage-c6-50k-active-record
python3 bench/cable_report.py bench/results/aws-c6g-20261007 rage-c6-50k
python3 bench/cable_report.py bench/results/aws-c6g-20261007 rage-c6-100k
```

The reconstructed sampler files contain app metrics only, so this command reports server
resources. The separately preserved console summaries report load-generator resources.
