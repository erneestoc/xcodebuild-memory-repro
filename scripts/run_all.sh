#!/bin/bash
# Runs every experiment, refreshes evidence/, and prints the consolidated
# summary. Expect this to take a while: the matrix alone builds and measures
# 25 fixtures, some of them 700 MB.
#
# QUICK=1 skips the full matrix and the memory-attribution capture.
source "$(dirname "$0")/common.sh"

: > "$RESULTS/summary.txt"
{
  xcodebuild -version
  sw_vers
  echo "cpu: $(sysctl -n machdep.cpu.brand_string)"
  echo "ram: $(( $(sysctl -n hw.memsize) / 1073741824 )) GB"
} | tee -a "$RESULTS/summary.txt"

# 1. The three original scaling effects: binary size, console output, attachments.
"$ROOT/scripts/03_experiment_binary_size.sh"
"$ROOT/scripts/04_experiment_console_output.sh"
"$ROOT/scripts/05_experiment_attachments.sh"

# 2. Which binary carries the cost: app vs test bundle vs embedded dylib,
#    and whether a dylib-hosted XCTestCase is still discovered.
"$ROOT/scripts/07_experiment_test_bundle_size.sh"
"$ROOT/scripts/10_experiment_dylib.sh"
"$ROOT/scripts/11_experiment_discovery.sh"

if [[ -z "${QUICK:-}" ]]; then
  # 3. The full (app size x test bundle size) matrix and its linear fit.
  "$ROOT/scripts/08_matrix.sh"

  # 4. Where the memory goes: footprint / vmmap / heap / malloc_history.
  STACK_LOGGING=1 PAD=256 PAD_TARGET=test "$ROOT/scripts/09_memory_map.sh"
else
  echo "QUICK=1: skipping 08_matrix.sh and 09_memory_map.sh"
fi

# 5. Copy the load-bearing captures into evidence/ for review without re-running.
"$ROOT/scripts/collect_evidence.sh"

echo
echo "==================== SUMMARY ===================="
cat "$RESULTS/summary.txt"
echo
echo "Per-toolchain comparison is separate, one Xcode at a time:"
echo "  DEVELOPER_DIR=/Applications/Xcode_16.1.app scripts/06_bisect_version.sh"
