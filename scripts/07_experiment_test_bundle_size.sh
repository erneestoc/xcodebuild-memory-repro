#!/bin/bash
# Experiment 4: is the multiplier attached to the host app binary, the test
# bundle binary, or any binary in the session?
#
# Three matched cases, each adding the same 256 MB of inert __TEXT data in a
# different place:
#   baseline   nothing padded
#   app        host app binary padded
#   testbundle .xctest bundle binary padded
#
# Whatever the padded binary is, the padding is never executed or read by the
# test, so any difference in host-side RSS is the toolchain's own doing.
source "$(dirname "$0")/common.sh"

PAD="${PAD:-256}"
echo "--- experiment: which binary drives the multiplier (${PAD} MB pad) ---" | tee -a "$RESULTS/summary.txt"

PAD_MB=0 "$ROOT/scripts/01_build_fixture.sh"
PAD_MB=0 LABEL="which_baseline" "$ROOT/scripts/02_run_case.sh"

PAD_MB=$PAD "$ROOT/scripts/01_build_fixture.sh"
PAD_MB=$PAD LABEL="which_app_pad${PAD}MB" "$ROOT/scripts/02_run_case.sh"

TEST_PAD_MB=$PAD "$ROOT/scripts/01_build_fixture.sh"
TEST_PAD_MB=$PAD LABEL="which_testbundle_pad${PAD}MB" "$ROOT/scripts/02_run_case.sh"

peak() { grep -m1 'MEASURE peak_total_mb=' "$RESULTS/$1.log" | cut -d= -f2; }
base=$(peak which_baseline)
app=$(peak "which_app_pad${PAD}MB")
tb=$(peak "which_testbundle_pad${PAD}MB")

{
  echo ""
  echo "baseline                  ${base} MB"
  printf 'app binary   +%s MB -> %s MB  (%s x per padded MB)\n' \
    "$PAD" "$app" "$(python3 -c "print(f'{($app-$base)/$PAD:.2f}')")"
  printf 'test bundle  +%s MB -> %s MB  (%s x per padded MB)\n' \
    "$PAD" "$tb" "$(python3 -c "print(f'{($tb-$base)/$PAD:.2f}')")"
} | tee -a "$RESULTS/summary.txt"
