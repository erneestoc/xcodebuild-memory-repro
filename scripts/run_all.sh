#!/bin/bash
# Runs every experiment and prints the consolidated summary.
source "$(dirname "$0")/common.sh"
: > "$RESULTS/summary.txt"
xcodebuild -version | tee -a "$RESULTS/summary.txt"
sw_vers | tee -a "$RESULTS/summary.txt"
"$ROOT/scripts/03_experiment_binary_size.sh"
"$ROOT/scripts/04_experiment_console_output.sh"
"$ROOT/scripts/05_experiment_attachments.sh"
echo
echo "==================== SUMMARY ===================="
cat "$RESULTS/summary.txt"
