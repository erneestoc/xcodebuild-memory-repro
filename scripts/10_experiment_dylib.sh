#!/bin/bash
# Experiment 7: does moving code into an embedded dynamic library avoid the
# multiplier?
#
# The same 256 MB of inert padding is placed in three different Mach-Os, all
# present in the same app bundle:
#   app       App.app/App                      (declared as TestHostPath)
#   test      App.app/PlugIns/*.xctest/MemTests (declared as TestBundlePath)
#   dylib     App.app/Frameworks/libPadLib.dylib (linked by the app, not
#             named anywhere in the xctestrun)
#
# If the cost follows the paths named in the xctestrun rather than every
# Mach-O in the bundle, the dylib case will be close to baseline — which
# would make "move code into dynamic frameworks" an effective mitigation.
source "$(dirname "$0")/common.sh"

PAD="${PAD:-256}"
echo "--- experiment: app vs test bundle vs embedded dylib (${PAD} MB) ---" | tee -a "$RESULTS/summary.txt"

PAD_MB=0 "$ROOT/scripts/01_build_fixture.sh"
PAD_MB=0 LABEL="dy_baseline" "$ROOT/scripts/02_run_case.sh"

PAD_MB=$PAD "$ROOT/scripts/01_build_fixture.sh"
PAD_MB=$PAD LABEL="dy_app${PAD}" "$ROOT/scripts/02_run_case.sh"

TEST_PAD_MB=$PAD "$ROOT/scripts/01_build_fixture.sh"
TEST_PAD_MB=$PAD LABEL="dy_test${PAD}" "$ROOT/scripts/02_run_case.sh"

DYLIB_PAD_MB=$PAD "$ROOT/scripts/01_build_fixture.sh"
DYLIB_PAD_MB=$PAD LABEL="dy_dylib${PAD}" "$ROOT/scripts/02_run_case.sh"

peak() { grep -m1 'MEASURE peak_total_mb=' "$RESULTS/$1.log" | cut -d= -f2; }
base=$(peak dy_baseline)
{
  echo ""
  printf 'baseline                     %6s MB\n' "$base"
  for kind in app test dylib; do
    p=$(peak "dy_${kind}${PAD}")
    printf '%-12s +%s MB -> %6s MB   (%s x per padded MB)\n' \
      "$kind" "$PAD" "$p" "$(python3 -c "print(f'{($p-$base)/$PAD:.2f}')")"
  done
} | tee -a "$RESULTS/summary.txt"
