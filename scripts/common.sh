# Shared helpers for the repro scripts. Source, don't execute.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/work"
RESULTS="$ROOT/results"
mkdir -p "$WORK" "$RESULTS"

SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
PLATFORM_DIR="$(dirname "$(dirname "$(dirname "$SDK_PATH")")")"
TARGET_TRIPLE="arm64-apple-ios16.0-simulator"

# Boots (if necessary) and echoes the UDID of a simulator to test on.
pick_simulator() {
  local udid
  udid=$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1 || true)
  if [[ -z "$udid" ]]; then
    udid=$(xcrun simctl list devices available | grep -oE 'iPhone [0-9][^(]*\([0-9A-F-]{36}\)' \
      | head -1 | grep -oE '[0-9A-F-]{36}' || true)
    [[ -n "$udid" ]] || { echo "error: no available iPhone simulator" >&2; exit 1; }
    xcrun simctl boot "$udid"
    xcrun simctl bootstatus "$udid" -b >/dev/null
  fi
  echo "$udid"
}
