#!/bin/bash
# Experiment 2: host-side memory grows ~26x the bytes the test writes to
# stdout (output is buffered multiple times across the session).
source "$(dirname "$0")/common.sh"
echo "--- experiment: console output scaling ---" | tee -a "$RESULTS/summary.txt"
PAD_MB=0 "$ROOT/scripts/01_build_fixture.sh"
for mb in 0 4 16; do
  PAD_MB=0 CONSOLE_MB=$mb ONLY_TEST="MemTests/MemTests/testEmitConsoleOutput" \
    LABEL="console_${mb}MB" "$ROOT/scripts/02_run_case.sh"
done
echo "Expected: peak grows ~26 MB per 1 MB written to stdout." | tee -a "$RESULTS/summary.txt"
