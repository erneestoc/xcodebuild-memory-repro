#!/bin/bash
# Measures the host-binary memory multiplier under one specific Xcode version,
# for bisecting which release introduced (or grew) the overhead.
#
#   DEVELOPER_DIR=/Applications/Xcode_16.1.app scripts/06_bisect_version.sh
#
# Accepts either the .app path or its Contents/Developer. Appends one row to
# results/bisect.csv:
#   date,xcode_version,xcode_build,macos,runtime,peak_pad0_mb,peak_padN_mb,slope_mb_per_mb
#
# Knobs:
#   BISECT_PAD=256   size (MB) of the padded fixture (pad-0 is always measured)
#   KEEP_DEVICE=1    don't delete the per-version simulator device afterwards
#
# Notes:
# - Shuts down all booted simulators so the measured run has a clean slate.
# - Each Xcode is paired with a runtime matching its SDK major version; if
#   none is installed the script runs `xcodebuild -downloadPlatform iOS`
#   (no Apple ID needed) which can take a while (~8 GB).
# - If the Xcode has never been launched you may need, once:
#     sudo DEVELOPER_DIR=<path> xcodebuild -runFirstLaunch

# Resolve DEVELOPER_DIR before common.sh runs its xcrun probes.
if [[ -n "${DEVELOPER_DIR:-}" && "$DEVELOPER_DIR" == *.app ]]; then
  export DEVELOPER_DIR="$DEVELOPER_DIR/Contents/Developer"
fi
source "$(dirname "$0")/common.sh"

BISECT_PAD="${BISECT_PAD:-256}"

XCODE_VERSION=$(xcodebuild -version | awk '/^Xcode/{print $2}')
XCODE_BUILD=$(xcodebuild -version | awk '/Build version/{print $3}')
MACOS_VERSION="$(sw_vers -productVersion) ($(sw_vers -buildVersion))"
[[ -n "$XCODE_VERSION" ]] || { echo "error: xcodebuild -version failed for DEVELOPER_DIR=${DEVELOPER_DIR:-<default>}" >&2; exit 1; }

if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  echo "warning: Xcode $XCODE_VERSION reports pending first-launch setup; continuing anyway." >&2
  echo "         If the run fails, complete it with:" >&2
  echo "         sudo DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)} xcodebuild -runFirstLaunch" >&2
fi

SDK_VERSION="$(xcrun --sdk iphonesimulator --show-sdk-version)"
SDK_MAJOR="${SDK_VERSION%%.*}"
echo "== bisect: Xcode $XCODE_VERSION ($XCODE_BUILD), iphonesimulator SDK $SDK_VERSION, macOS $MACOS_VERSION"

# Find a runtime whose major version matches this Xcode's SDK (download if
# absent), plus an iPhone device type that runtime actually supports.
find_runtime() {
  xcrun simctl list runtimes -j | python3 -c "
import json, sys
major = int(sys.argv[1])
rts = [r for r in json.load(sys.stdin)['runtimes']
       if r.get('platform') == 'iOS' and r.get('isAvailable')
       and int(r['version'].split('.')[0]) == major]
rts.sort(key=lambda r: [int(x) for x in r['version'].split('.')])
if rts:
    rt = rts[-1]
    phones = sorted(d['identifier'] for d in rt.get('supportedDeviceTypes', [])
                    if 'iPhone' in d['identifier'] and 'SE' not in d['identifier'])
    if phones:
        print(rt['identifier'], rt['version'], phones[-1])
" "$SDK_MAJOR"
}

RUNTIME_LINE=$(find_runtime || true)
if [[ -z "$RUNTIME_LINE" ]]; then
  echo "no installed iOS $SDK_MAJOR.x runtime; downloading via xcodebuild -downloadPlatform iOS (this is large)..."
  xcodebuild -downloadPlatform iOS
  RUNTIME_LINE=$(find_runtime || true)
  [[ -n "$RUNTIME_LINE" ]] || { echo "error: still no iOS $SDK_MAJOR.x runtime after download" >&2; exit 1; }
fi
read -r RUNTIME_ID RUNTIME_VERSION DEVICE_TYPE <<< "$RUNTIME_LINE"
echo "using runtime: $RUNTIME_ID ($RUNTIME_VERSION), device type: $DEVICE_TYPE"
DEVICE_NAME="bisect-$XCODE_VERSION"

xcrun simctl shutdown all >/dev/null 2>&1 || true
xcrun simctl list devices | grep -q "$DEVICE_NAME " && \
  xcrun simctl delete "$(xcrun simctl list devices | grep "$DEVICE_NAME " | grep -oE '[0-9A-F-]{36}' | head -1)" || true
UDID=$(xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE" "$RUNTIME_ID")
cleanup() {
  xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
  [[ -n "${KEEP_DEVICE:-}" ]] || xcrun simctl delete "$UDID" >/dev/null 2>&1 || true
}
trap cleanup EXIT
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null
echo "booted $DEVICE_TYPE ($UDID)"

# Pad ladder. 02_run_case.sh finds our booted device via pick_simulator.
declare -a peaks=()
for pad in 0 "$BISECT_PAD"; do
  label="bisect_${XCODE_VERSION}_pad${pad}MB"
  PAD_MB=$pad "$ROOT/scripts/01_build_fixture.sh"
  PAD_MB=$pad LABEL="$label" "$ROOT/scripts/02_run_case.sh"
  peak=$(grep -m1 'MEASURE peak_total_mb=' "$RESULTS/$label.log" | cut -d= -f2)
  [[ -n "$peak" ]] || { echo "error: no peak recorded for $label; see $RESULTS/$label.log" >&2; exit 1; }
  peaks+=("$peak")
done

SLOPE=$(python3 -c "print(f'{(${peaks[1]} - ${peaks[0]}) / $BISECT_PAD:.2f}')")
CSV="$RESULTS/bisect.csv"
[[ -f "$CSV" ]] || echo "date,xcode_version,xcode_build,macos,runtime,peak_pad0_mb,peak_pad${BISECT_PAD}_mb,slope_mb_per_mb" > "$CSV"
echo "$(date +%Y-%m-%d),$XCODE_VERSION,$XCODE_BUILD,\"$MACOS_VERSION\",$RUNTIME_VERSION,${peaks[0]},${peaks[1]},$SLOPE" >> "$CSV"

echo ""
echo "== Xcode $XCODE_VERSION: baseline ${peaks[0]} MB, +${BISECT_PAD} MB binary -> ${peaks[1]} MB  (slope ${SLOPE}x per binary MB)"
echo "== appended to $CSV"
