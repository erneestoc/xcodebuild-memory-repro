#!/usr/bin/env python3
"""Runs a command and samples the resident memory of every process it is
responsible for, until it exits.

Tracked set, sampled every 0.25s via `ps`:
  * the spawned command and all of its descendants (transitive ppid walk)
  * any process whose name matches HELPER_PATTERN and whose pid did not
    exist before the run started (test-session helpers such as the
    symbolication service are XPC-spawned and are not always descendants)

Prints the peak aggregate RSS, the per-process peaks, and writes a CSV
timeline next to the requested results file.
"""
import re
import subprocess
import sys
import time

HELPER_PATTERN = re.compile(
    r"xcodebuild|Symbolication|xcresulttool|XCTRunner|CoreSimulatorBridge",
    re.IGNORECASE,
)
INTERVAL = 0.25


def ps_snapshot():
    out = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,rss=,args="],
        capture_output=True, text=True,
    ).stdout
    procs = {}
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        try:
            pid, ppid, rss = int(parts[0]), int(parts[1]), int(parts[2])
        except ValueError:
            continue
        procs[pid] = (ppid, rss, parts[3])
    return procs


def descendants(procs, root):
    children = {}
    for pid, (ppid, _, _) in procs.items():
        children.setdefault(ppid, []).append(pid)
    result, stack = set(), [root]
    while stack:
        pid = stack.pop()
        if pid in result:
            continue
        result.add(pid)
        stack.extend(children.get(pid, []))
    return result


def main():
    if len(sys.argv) < 3:
        print(f"usage: {sys.argv[0]} <timeline.csv> <command...>", file=sys.stderr)
        return 2

    timeline_path, cmd = sys.argv[1], sys.argv[2:]
    preexisting = set(ps_snapshot().keys())

    child = subprocess.Popen(cmd)
    start = time.time()
    peak_total_kb = 0
    peak_breakdown = []
    proc_peaks = {}  # name -> peak kb
    timeline = []

    while child.poll() is None:
        procs = ps_snapshot()
        tracked = descendants(procs, child.pid)
        for pid, (_, _, args) in procs.items():
            if pid not in preexisting and HELPER_PATTERN.search(args):
                tracked.add(pid)

        total_kb, breakdown = 0, []
        for pid in tracked:
            if pid not in procs:
                continue
            _, rss, args = procs[pid]
            total_kb += rss
            name = args.split()[0].rsplit("/", 1)[-1]
            breakdown.append((rss, name))
            proc_peaks[name] = max(proc_peaks.get(name, 0), rss)

        timeline.append((time.time() - start, total_kb))
        if total_kb > peak_total_kb:
            peak_total_kb = total_kb
            peak_breakdown = sorted(breakdown, reverse=True)[:8]
        time.sleep(INTERVAL)

    exit_code = child.returncode
    with open(timeline_path, "w") as f:
        f.write("elapsed_s,total_rss_kb\n")
        for t, kb in timeline:
            f.write(f"{t:.2f},{kb}\n")

    print(f"MEASURE peak_total_mb={peak_total_kb / 1024:.0f}")
    print("MEASURE breakdown_at_peak:")
    for rss, name in peak_breakdown:
        print(f"MEASURE   {rss / 1024:8.0f} MB  {name}")
    print("MEASURE per_process_peaks:")
    for name, kb in sorted(proc_peaks.items(), key=lambda kv: -kv[1])[:8]:
        print(f"MEASURE   {kb / 1024:8.0f} MB  {name}")
    print(f"MEASURE command_exit={exit_code}")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
