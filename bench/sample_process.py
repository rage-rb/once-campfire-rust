#!/usr/bin/env python3
"""Sample explicitly owned PIDs or an app process tree; Linux PSS, macOS RSS.

Run separately on the Pi:
python3 bench/sample_process.py --app-tree APP_PID > sample.jsonl
"""
import argparse
import json
import os
import subprocess
import time


def linux_process(pid, proc_root='/proc'):
    # comm may contain spaces; fields after its closing ')' begin with field 3.
    with open(f'{proc_root}/{pid}/stat') as stat:
        fields = stat.read().rsplit(')', 1)[1].split()
    cpu = (int(fields[11]) + int(fields[12])) / os.sysconf('SC_CLK_TCK')
    with open(f'{proc_root}/{pid}/smaps_rollup') as rollup:
        pss = next(int(line.split()[1]) for line in rollup if line.startswith('Pss:'))
    # PID plus start time distinguishes a replacement process that reused a PID.
    identity = (pid, int(fields[19]))
    return dict(cpu_seconds=cpu, memory_kb=pss, memory_kind='PSS'), identity


def process(pid):
    if os.path.isdir('/proc'):
        return linux_process(pid)
    row = subprocess.check_output(
        ['ps', '-p', str(pid), '-o', 'rss=', '-o', 'time='], text=True).split()
    if len(row) != 2:
        raise ProcessLookupError(pid)
    clock = row[1].split(':')
    cpu = sum(float(part) * 60 ** i for i, part in enumerate(reversed(clock)))
    return dict(cpu_seconds=cpu, memory_kb=int(row[0]), memory_kind='RSS'), (pid,)


def sample(pid):
    if not pid:
        return {}
    return process(pid)[0]


def linux_process_tree(root_pid, proc_root='/proc'):
    pids = []
    pending = [root_pid]
    seen = set()
    while pending:
        pid = pending.pop()
        if pid in seen:
            continue
        seen.add(pid)
        pids.append(pid)
        try:
            with open(f'{proc_root}/{pid}/task/{pid}/children') as child_list:
                children = child_list.read().split()
        except OSError:
            continue
        pending.extend(int(child) for child in children)
    return sorted(pids)


def ps_process_tree(root_pid):
    output = subprocess.check_output(['ps', '-axo', 'pid=', '-o', 'ppid='], text=True)
    children = {}
    for line in output.splitlines():
        pid, parent = (int(value) for value in line.split())
        children.setdefault(parent, []).append(pid)
    pids = []
    pending = [root_pid]
    seen = set()
    while pending:
        pid = pending.pop()
        if pid in seen:
            continue
        seen.add(pid)
        pids.append(pid)
        pending.extend(children.get(pid, []))
    return sorted(pids)


def process_tree(root_pid):
    if os.path.isdir('/proc'):
        return linux_process_tree(root_pid)
    return ps_process_tree(root_pid)


class ProcessTreeSampler:
    def __init__(self, root_pid):
        self.root_pid = root_pid
        self.cpu_by_identity = {}

    def sample(self):
        live = []
        for pid in process_tree(self.root_pid):
            try:
                metrics, identity = process(pid)
            except (OSError, StopIteration, subprocess.CalledProcessError, ValueError):
                continue
            live.append((pid, metrics))
            self.cpu_by_identity[identity] = metrics['cpu_seconds']

        if not any(pid == self.root_pid for pid, _ in live):
            raise ProcessLookupError(self.root_pid)

        return dict(
            cpu_seconds=sum(self.cpu_by_identity.values()),
            memory_kb=sum(metrics['memory_kb'] for _, metrics in live),
            memory_kind=live[0][1]['memory_kind'],
            process_count=len(live),
            pids=[pid for pid, _ in live],
        )


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    app = parser.add_mutually_exclusive_group()
    app.add_argument('--app', type=int, default=0, help='sample one app PID')
    app.add_argument('--app-tree', type=int, default=0,
                     help='aggregate an app root PID and all descendants')
    parser.add_argument('--loadgen', type=int, default=0)
    args = parser.parse_args()
    app_tree = ProcessTreeSampler(args.app_tree) if args.app_tree else None
    try:
        while True:
            app_sample = app_tree.sample() if app_tree else sample(args.app)
            row = dict(time=time.time(), app=app_sample, loadgen=sample(args.loadgen))
            print(json.dumps(row), flush=True)
            time.sleep(1)
    except (OSError, StopIteration, subprocess.CalledProcessError):
        pass  # Tracked process exited; the runner handles its exit status.
