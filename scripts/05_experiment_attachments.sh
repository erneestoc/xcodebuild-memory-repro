#!/bin/bash
# Experiment 3: an XCTAttachment with lifetime=.deleteOnSuccess on a PASSING
# test (so the payload can never be needed) still grows host-side memory
# ~1.4x the payload size.
source "$(dirname "$0")/common.sh"
echo "--- experiment: attachment payload scaling ---" | tee -a "$RESULTS/summary.txt"
PAD_MB=0 "$ROOT/scripts/01_build_fixture.sh"
for mb in 0 64 256; do
  PAD_MB=0 ATTACH_MB=$mb ONLY_TEST="MemTests/MemTests/testAddAttachment" \
    LABEL="attach_${mb}MB" "$ROOT/scripts/02_run_case.sh"
done
echo "Expected: peak grows ~1.4 MB per 1 MB of attachment payload," | tee -a "$RESULTS/summary.txt"
echo "even though lifetime=.deleteOnSuccess on a passing test." | tee -a "$RESULTS/summary.txt"
