#!/usr/bin/env python3
"""Validate the six-subscription workload before reporting a benchmark as successful."""
import json
import sys

work, label = sys.argv[1:]
r = json.load(open(f'{work}/cable-{label}.json'))
latency, throughput = r['latency'], r['throughput']
errors = []
if not r['clients'] or r['ready'] != r['clients'] or r['failed']:
    errors.append(f"clients ready={r['ready']}/{r['clients']}, failed={r['failed']}")
if r['subscriptions_per_client'] != 6:
    errors.append('expected six subscriptions per client')
for name, part in [('paced', latency), ('saturated', throughput)]:
    if part['post_failed'] or part['posted'] != part['attempted']:
        errors.append(f"{name}: HTTP failures={part['post_failed']}")
    if not part['posted'] or part['complete'] != part['posted']:
        errors.append(f"{name}: complete={part['complete']}/{part['posted']}")
print(label, 'ready', r['ready'], 'failed', r['failed'], 'connect_s', r['connect_secs'],
      'post->all p50/p99', latency['all_clients'].get('p50_ms'), latency['all_clients'].get('p99_ms'),
      'saturated attempted/posted/complete', throughput['attempted'], throughput['posted'], throughput['complete'],
      'post_failed', throughput['post_failed'], 'wire MB/s', throughput.get('wire_mb_per_sec'),
      'compressed clients', r['compressed_clients'])
rows = [json.loads(line) for line in open(f'{work}/samp-{label}.jsonl')]
phases = {}
for line in open(f'{work}/cable-{label}.err'):
    if line.startswith('PHASE '):
        _, name, ms = line.split()
        phases[name] = int(ms) / 1000
names = sorted(phases, key=phases.get)
for start, end in zip(names, names[1:] + [None]):
    until = phases[end] if end else (rows[-1]['time'] if rows else phases[start])
    selected = [row for row in rows if phases[start] <= row['time'] <= until]
    if len(selected) < 2:
        continue
    seconds = selected[-1]['time'] - selected[0]['time']
    metrics = []
    for process in ['app', 'loadgen']:
        first, last = selected[0][process], selected[-1][process]
        if first and last:
            cores = (last['cpu_seconds'] - first['cpu_seconds']) / seconds
            memory = max(row[process]['memory_kb'] for row in selected) / 1024
            metrics.append(f"{process} {cores:.2f} cores, {first['memory_kind']} {memory:.0f} MB")
    print(f"  {start}: {seconds:.1f}s " + '; '.join(metrics))
if errors:
    sys.exit('INVALID RUN: ' + '; '.join(errors))
