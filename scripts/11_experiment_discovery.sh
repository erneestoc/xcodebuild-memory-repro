#!/bin/bash
# Experiment 8: can XCTestCase subclasses themselves live in a dynamic
# library, or only the code the tests depend on?
#
# The dylib mitigation (experiment 7) only helps for bytes that can actually
# be moved out of the .xctest binary. XCTest discovers tests by enumerating
# the runtime, so the question is whether a subclass compiled into an
# embedded dylib -- linked by the test bundle, so dyld loads it alongside --
# is discovered and run.
#
# Runs the whole bundle (no -only-testing) and reports which tests executed.
source "$(dirname "$0")/common.sh"

TESTCASE_DYLIB=1 "$ROOT/scripts/01_build_fixture.sh"
TESTCASE_DYLIB=1 ONLY_TEST="" LABEL="discovery_dylib" "$ROOT/scripts/02_run_case.sh" || true

LOG="$RESULTS/discovery_dylib.log"
echo ""
echo "--- test discovery with an XCTestCase subclass in an embedded dylib ---" \
  | tee -a "$RESULTS/summary.txt"
{
  echo "tests executed:"
  grep -oE "Test Case '[^']+' (passed|failed)" "$LOG" 2>/dev/null | sort -u | sed 's/^/  /' || true
  echo "suites:"
  grep -oE "Test Suite '[^']+' started" "$LOG" 2>/dev/null | sort -u | sed 's/^/  /' || true
  if grep -q 'testFromDylib' "$LOG" 2>/dev/null; then
    echo "RESULT: the dylib-hosted XCTestCase WAS discovered and run, so test"
    echo "        code itself can also live outside the .xctest binary."
  else
    echo "RESULT: the dylib-hosted XCTestCase was NOT discovered;"
    echo "        test case classes must stay in the .xctest binary."
  fi
} | tee -a "$RESULTS/summary.txt"
