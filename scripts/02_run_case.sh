#!/bin/bash
# One measured `xcodebuild test-without-building` run.
#   PAD_MB      which fixture to use (must be built by 01_build_fixture.sh)
#   ONLY_TEST   test to run (default MemTests/MemTests/testTrivial)
#   CONSOLE_MB  REPRO_CONSOLE_MB for the test process
#   ATTACH_MB   REPRO_ATTACH_MB for the test process
#   LABEL       row label for results/summary.txt
source "$(dirname "$0")/common.sh"

PAD_MB="${PAD_MB:-0}"
TEST_PAD_MB="${TEST_PAD_MB:-0}"
ONLY_TEST="${ONLY_TEST:-MemTests/MemTests/testTrivial}"
CONSOLE_MB="${CONSOLE_MB:-0}"
ATTACH_MB="${ATTACH_MB:-0}"
LABEL="${LABEL:-pad${PAD_MB}_console${CONSOLE_MB}_attach${ATTACH_MB}}"

FIXTURE="$(fixture_path "$PAD_MB" "$TEST_PAD_MB")"
[[ -d "$FIXTURE" ]] || { echo "fixture missing; run: PAD_MB=$PAD_MB TEST_PAD_MB=$TEST_PAD_MB scripts/01_build_fixture.sh" >&2; exit 1; }

UDID=$(pick_simulator)
RUN_DIR="$WORK/run-$LABEL"
rm -rf "$RUN_DIR"; mkdir -p "$RUN_DIR"

# Per-case copy of the xctestrun with the size knobs injected. It must sit
# next to App.app because __TESTROOT__ resolves to the xctestrun's directory.
XCTESTRUN="$FIXTURE/run-$LABEL.xctestrun"
cp "$FIXTURE/tests.xctestrun" "$XCTESTRUN"
plutil -insert MemTests.TestingEnvironmentVariables.REPRO_CONSOLE_MB -string "$CONSOLE_MB" "$XCTESTRUN"
plutil -insert MemTests.TestingEnvironmentVariables.REPRO_ATTACH_MB -string "$ATTACH_MB" "$XCTESTRUN"
plutil -insert MemTests.TestingEnvironmentVariables.REPRO_SLEEP_S -string "${SLEEP_S:-0}" "$XCTESTRUN"

echo "== case $LABEL (simulator $UDID, only-testing $ONLY_TEST)"
set +e
python3 "$ROOT/scripts/measure_rss.py" "$RESULTS/$LABEL.timeline.csv" \
  xcodebuild test-without-building \
    -xctestrun "$XCTESTRUN" \
    -destination "id=$UDID" \
    -derivedDataPath "$RUN_DIR/derived_data" \
    -only-testing:"$ONLY_TEST" \
    > "$RESULTS/$LABEL.log" 2>&1
status=$?
set -e

peak=$(grep -m1 'MEASURE peak_total_mb=' "$RESULTS/$LABEL.log" | cut -d= -f2)
grep -E '^MEASURE' "$RESULTS/$LABEL.log" | sed 's/^MEASURE //'
if ! grep -q 'TEST EXECUTE SUCCEEDED' "$RESULTS/$LABEL.log"; then
  echo "warning: test did not report success (exit $status); see $RESULTS/$LABEL.log" >&2
fi
printf '%-40s %8s MB\n' "$LABEL" "$peak" >> "$RESULTS/summary.txt"
