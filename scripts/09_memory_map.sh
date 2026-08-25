#!/bin/bash
# Experiment 6: where does the memory actually go?
#
# Runs one padded session whose test sleeps, so the xcodebuild process sits at
# peak long enough to be inspected, and captures:
#
#   vm_stat deltas   whether the growth is anonymous (dirty, swappable) or
#                    file-backed (clean, evictable) memory. This is the
#                    question that decides whether the cost is "the kernel
#                    caching a mapped binary" or "a private copy on the heap".
#   vmmap / heap     per-region and per-allocation attribution, when the
#                    system permits inspecting the process.
#   footprint        the kernel's own accounting for the process.
#
# PAD_TARGET=app|test chooses which binary carries the padding (default test,
# the more expensive one). PAD=<MB> sets its size. SLEEP=<s> how long to hold.
source "$(dirname "$0")/common.sh"

PAD="${PAD:-512}"
PAD_TARGET="${PAD_TARGET:-test}"
SLEEP_S="${SLEEP:-75}"
if [[ "$PAD_TARGET" == "app" ]]; then
  APP_PAD="$PAD"; TEST_PAD=0
else
  APP_PAD=0; TEST_PAD="$PAD"
fi

OUT="$RESULTS/memmap-${PAD_TARGET}${PAD}"
rm -rf "$OUT"; mkdir -p "$OUT"
FIXTURE="$(fixture_path "$APP_PAD" "$TEST_PAD")"

PAD_MB="$APP_PAD" TEST_PAD_MB="$TEST_PAD" "$ROOT/scripts/01_build_fixture.sh"

UDID=$(pick_simulator)
XCTESTRUN="$FIXTURE/memmap.xctestrun"
cp "$FIXTURE/tests.xctestrun" "$XCTESTRUN"
plutil -insert MemTests.TestingEnvironmentVariables.REPRO_SLEEP_S -string "$SLEEP_S" "$XCTESTRUN"

# vm_stat reports page counts; capture the page size to convert to bytes.
PAGE=$(vm_stat | sed -n '1s/.*page size of \([0-9]*\).*/\1/p')
vm_stat > "$OUT/vm_stat.before.txt"

echo "== launching padded session (${PAD_TARGET} pad ${PAD} MB), holding ${SLEEP_S}s"
# STACK_LOGGING=1 makes libmalloc record an allocation backtrace per block, so
# malloc_history can name the code path that allocates the large buffers. It
# costs time and memory, so it is opt-in.
[[ -n "${STACK_LOGGING:-}" ]] && export MallocStackLogging=1
xcodebuild test-without-building \
  -xctestrun "$XCTESTRUN" \
  -destination "id=$UDID" \
  -derivedDataPath "$FIXTURE/dd" \
  -only-testing:MemTests/MemTests/testHoldOpen \
  > "$OUT/xcodebuild.log" 2>&1 &
XCB_WRAPPER=$!

# Wait for the process to reach its plateau rather than sampling on the way up.
PID="$XCB_WRAPPER"; peak_kb=0; stable=0
for _ in $(seq 1 400); do
  if [[ -n "$PID" ]]; then
    rss=$(ps -o rss= -p "$PID" 2>/dev/null | tr -d ' ')
    if [[ -n "$rss" ]]; then
      if (( rss > peak_kb )); then peak_kb=$rss; stable=0; else stable=$((stable + 1)); fi
      (( stable >= 6 && peak_kb > 500000 )) && break
    fi
  fi
  sleep 0.25
done
[[ -n "$PID" ]] || { echo "error: never saw an xcodebuild process" >&2; wait $XCB_WRAPPER; exit 1; }
echo "== xcodebuild pid $PID plateaued at $(( peak_kb / 1024 )) MB; capturing"

vm_stat > "$OUT/vm_stat.peak.txt"
ps -o pid=,rss=,vsz=,args= -p "$PID" > "$OUT/ps.txt" 2>&1 || true

# These require permission to inspect another process's task port. Apple's own
# tools are platform binaries, so this may be denied; record the refusal rather
# than pretending the data is missing for some other reason.
for tool in "footprint $PID" "vmmap --summary $PID" "vmmap $PID" "heap $PID"; do
  name=$(echo "$tool" | awk '{print $1}')
  suffix=$(echo "$tool" | grep -q -- --summary && echo ".summary" || echo "")
  if ! $tool > "$OUT/$name$suffix.txt" 2>&1; then
    echo "note: \`$tool\` failed (see $OUT/$name$suffix.txt)"
  fi
done

if [[ -n "${STACK_LOGGING:-}" ]]; then
  # Group live blocks by allocating stack, largest first: the top entry is the
  # code path responsible for the bulk of the footprint.
  malloc_history "$PID" -allBySize > "$OUT/malloc_history.allBySize.txt" 2>&1 \
    || echo "note: malloc_history failed (see $OUT/malloc_history.allBySize.txt)"
fi

wait $XCB_WRAPPER || true
vm_stat > "$OUT/vm_stat.after.txt"

python3 - "$OUT" "$PAGE" "$PAD" <<'PY'
import re, sys
out, page, pad = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])

def read(p):
    d = {}
    for line in open(p):
        m = re.match(r'"?([A-Za-z][^":]*)"?:\s+(\d+)', line.strip())
        if m:
            d[m.group(1).strip()] = int(m.group(2))
    return d

before, peak = read(f"{out}/vm_stat.before.txt"), read(f"{out}/vm_stat.peak.txt")
interesting = [
    ("Anonymous pages", "anonymous (dirty, swappable)"),
    ("File-backed pages", "file-backed (clean, evictable)"),
    ("Pages wired down", "wired"),
    ("Pages occupied by compressor", "compressor"),
]
lines = ["", f"system-wide vm_stat delta, baseline -> peak (pad {pad} MB):"]
for key, label in interesting:
    if key in before and key in peak:
        delta_mb = (peak[key] - before[key]) * page / 1024 / 1024
        lines.append(f"  {label:38} {delta_mb:+9.0f} MB")
lines.append("")
lines.append("If the growth were the kernel caching a mapped binary, it would")
lines.append("appear as file-backed pages, which are clean and evictable under")
lines.append("pressure. Anonymous growth is a private, dirty copy: it cannot be")
lines.append("dropped, only compressed or swapped.")
text = "\n".join(lines)
print(text)
open(f"{out}/vm_stat.delta.txt", "w").write(text + "\n")
PY

echo ""
echo "== artifacts in $OUT"
