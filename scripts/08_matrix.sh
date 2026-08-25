#!/bin/bash
# Experiment 5: the (app binary size x test bundle size) matrix.
#
# Sweeps both padded binaries independently and together, to establish
#   * whether each cost is linear over a realistic size range, and
#   * whether the two costs are additive, i.e. whether
#       peak ~= base + A*(app MB) + B*(test MB)
#     predicts combinations it was not fitted on.
#
# Writes results/matrix.csv:
#   app_mb,test_mb,app_binary_mb,test_binary_mb,peak_mb
#
# Fixtures are large (a 700 MB pad makes a 700 MB binary), so each case's
# fixture is deleted once measured. KEEP_FIXTURES=1 disables that.
#
# MATRIX_CASES overrides the grid: "app:test app:test ...".
source "$(dirname "$0")/common.sh"

DEFAULT_CASES="0:0 128:0 256:0 512:0 0:128 0:256 0:512 0:700 256:256 400:700"
read -r -a CASES <<< "${MATRIX_CASES:-$DEFAULT_CASES}"

CSV="$RESULTS/matrix.csv"
echo "app_mb,test_mb,app_binary_mb,test_binary_mb,peak_mb" > "$CSV"

for case in "${CASES[@]}"; do
  app="${case%%:*}"
  test="${case##*:}"
  label="matrix_app${app}_test${test}"
  fixture="$(fixture_path "$app" "$test")"

  avail_gb=$(( $(df -k /System/Volumes/Data | tail -1 | awk '{print $4}') / 1048576 ))
  if (( avail_gb < 12 )); then
    echo "stopping: only ${avail_gb} GB free, need headroom for a $(( app + test )) MB fixture" >&2
    break
  fi

  PAD_MB="$app" TEST_PAD_MB="$test" "$ROOT/scripts/01_build_fixture.sh"
  PAD_MB="$app" TEST_PAD_MB="$test" LABEL="$label" "$ROOT/scripts/02_run_case.sh"

  peak=$(grep -m1 'MEASURE peak_total_mb=' "$RESULTS/$label.log" | cut -d= -f2)
  app_bin=$(du -m "$fixture/App.app/App" | cut -f1)
  test_bin=$(du -m "$fixture/App.app/PlugIns/MemTests.xctest/MemTests" | cut -f1)
  echo "$app,$test,$app_bin,$test_bin,$peak" >> "$CSV"

  [[ -n "${KEEP_FIXTURES:-}" ]] || rm -rf "$fixture"
done

echo ""
echo "== matrix complete: $CSV"
python3 "$ROOT/scripts/fit_matrix.py" "$CSV" | tee -a "$RESULTS/summary.txt"
