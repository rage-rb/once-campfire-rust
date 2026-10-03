#!/usr/bin/env python3
"""Sample explicitly owned PIDs; Linux PSS, macOS RSS. No process-name guessing.

Run separately on the Pi: python3 bench/sample_process.py --app APP_PID > sample.jsonl
"""
import argparse
import json
import os
import subprocess
import time


def sample(pid):
    if not pid:
        return {}
    if os.path.isdir('/proc'):
        # comm may contain spaces; fields after its closing ')' begin with field 3.
        fields = open(f'/proc/{pid}/stat').read().rsplit(')', 1)[1].split()
        cpu = (int(fields[11]) + int(fields[12])) / os.sysconf('SC_CLK_TCK')
        pss = next(int(line.split()[1]) for line in open(f'/proc/{pid}/smaps_rollup') if line.startswith('Pss:'))
        return dict(cpu_seconds=cpu, memory_kb=pss, memory_kind='PSS')
    row = subprocess.check_output(['ps', '-p', str(pid), '-o', 'rss=', '-o', 'time='], text=True).split()
    if len(row) != 2:
        raise ProcessLookupError(pid)
    clock = row[1].split(':')
    cpu = sum(float(part) * 60 ** i for i, part in enumerate(reversed(clock)))
    return dict(cpu_seconds=cpu, memory_kb=int(row[0]), memory_kind='RSS')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=int, default=0)
    parser.add_argument('--loadgen', type=int, default=0)
    args = parser.parse_args()
    try:
        while True:
            print(json.dumps(dict(time=time.time(), app=sample(args.app), loadgen=sample(args.loadgen))), flush=True)
            time.sleep(1)
    except (OSError, StopIteration):
        pass  # Tracked process exited; the runner handles its exit status.
