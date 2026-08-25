#!/bin/bash
# Copies the load-bearing captures out of results/ into evidence/, so the
# repository shows the raw output the analysis is built on without anyone
# having to reproduce it first. Large captures are excerpted, and each file
# records the command that produced it.
#
# Run after: 08_matrix.sh, 10_experiment_dylib.sh, 11_experiment_discovery.sh,
#            STACK_LOGGING=1 09_memory_map.sh, 06_bisect_version.sh
source "$(dirname "$0")/common.sh"

EV="$ROOT/evidence"
mkdir -p "$EV"

hdr() { # <file> <command that produced it>
  {
    echo "# Captured on $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(sysctl -n machdep.cpu.brand_string)"
    echo "# Xcode $(xcodebuild -version | awk '/^Xcode/{print $2}') ($(xcodebuild -version | awk '/Build version/{print $3}'))"
    echo "# Produced by: $2"
    echo "#"
  } > "$1"
}

copy_csv() {
  [[ -f "$RESULTS/$1" ]] || { echo "skip $1 (not present)"; return; }
  cp "$RESULTS/$1" "$EV/$1"
  echo "wrote evidence/$1"
}

copy_csv matrix.csv
copy_csv bisect.csv

# --- memory attribution -------------------------------------------------
for d in "$RESULTS"/memmap-*; do
  [[ -d "$d" ]] || continue
  name=$(basename "$d")
  out="$EV/$name"
  mkdir -p "$out"

  if [[ -f "$d/footprint.txt" ]]; then
    hdr "$out/footprint.txt" "footprint <pid>"
    grep -v MallocStackLogging "$d/footprint.txt" >> "$out/footprint.txt"
    echo "wrote evidence/$name/footprint.txt"
  fi

  if [[ -f "$d/vmmap.summary.txt" ]]; then
    hdr "$out/vmmap.summary.txt" "vmmap --summary <pid>"
    cat "$d/vmmap.summary.txt" >> "$out/vmmap.summary.txt"
    echo "wrote evidence/$name/vmmap.summary.txt"
  fi

  if [[ -f "$d/heap.txt" ]]; then
    hdr "$out/heap.excerpt.txt" "heap <pid>  (first 80 lines: totals, live block sizes, class breakdown)"
    head -80 "$d/heap.txt" >> "$out/heap.excerpt.txt"
    echo "wrote evidence/$name/heap.excerpt.txt"
  fi

  if [[ -f "$d/vm_stat.delta.txt" ]]; then
    hdr "$out/vm_stat.delta.txt" "vm_stat before/at-peak, differenced"
    cat "$d/vm_stat.delta.txt" >> "$out/vm_stat.delta.txt"
    echo "wrote evidence/$name/vm_stat.delta.txt"
  fi

  # malloc_history is ~100 MB of full stacks; keep every allocation over
  # 50 MB with its innermost frames, which is what the analysis cites.
  if [[ -f "$d/malloc_history.allBySize.txt" ]]; then
    hdr "$out/malloc_history.large.txt" "malloc_history <pid> -allBySize  (allocations > 50 MB, innermost 10 frames)"
    python3 - "$d/malloc_history.allBySize.txt" >> "$out/malloc_history.large.txt" <<'PY'
import re, sys
rows = []
with open(sys.argv[1], errors="replace") as f:
    for line in f:
        m = re.match(r'(\d+) calls? for (\d+) bytes: (.*)', line)
        if m and int(m.group(2)) > 50_000_000:
            rows.append((int(m.group(2)), int(m.group(1)), m.group(3)))
rows.sort(reverse=True)
print(f"{len(rows)} live allocation stacks over 50 MB, "
      f"{sum(r[0] for r in rows)/1024/1024:.0f} MB combined\n")
for size, calls, stack in rows:
    frames = [f.strip() for f in stack.split('|')]
    print(f"=== {size/1024/1024:.0f} MB in {calls} call(s) "
          f"({size} bytes) ===")
    for fr in frames[-10:]:
        print("    " + re.sub(r'^0x[0-9a-f]+ ', '', fr))
    print()
PY
    echo "wrote evidence/$name/malloc_history.large.txt"
  fi
done

# --- experiment summaries ----------------------------------------------
for label in dy_baseline dy_app256 dy_test256 dy_dylib256; do
  [[ -f "$RESULTS/$label.log" ]] || continue
  mkdir -p "$EV/placement"
  hdr "$EV/placement/$label.measure.txt" "scripts/10_experiment_dylib.sh -> $label"
  grep -E '^MEASURE|TEST EXECUTE' "$RESULTS/$label.log" >> "$EV/placement/$label.measure.txt" || true
  echo "wrote evidence/placement/$label.measure.txt"
done

if [[ -f "$RESULTS/discovery_dylib.log" ]]; then
  mkdir -p "$EV/discovery"
  hdr "$EV/discovery/test_run.txt" "scripts/11_experiment_discovery.sh (whole bundle, no -only-testing)"
  grep -E "Test Suite '|Test Case '" "$RESULTS/discovery_dylib.log" >> "$EV/discovery/test_run.txt" || true
  echo "wrote evidence/discovery/test_run.txt"
fi

echo ""
echo "== evidence/ refreshed"
