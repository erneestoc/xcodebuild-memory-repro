#!/bin/bash
# Experiment 1: host-side memory scales ~9x with the host app binary size.
# The padded bytes are inert __TEXT data; only the binary's size changes.
source "$(dirname "$0")/common.sh"
echo "--- experiment: host binary size scaling ---" | tee -a "$RESULTS/summary.txt"
for pad in 0 64 256; do
  PAD_MB=$pad "$ROOT/scripts/01_build_fixture.sh"
  PAD_MB=$pad LABEL="binary_pad${pad}MB" "$ROOT/scripts/02_run_case.sh"
done
echo "Expected: peak grows ~9 MB per 1 MB of added binary size." | tee -a "$RESULTS/summary.txt"
