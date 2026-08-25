#!/bin/bash
# Dumps the DVTFoundation code that performs the whole-file reads, so the
# claim in the analysis can be checked against the shipped binary directly.
#
# Shows three things:
#   1. that DVTPlatformFamilyForMachO's first action is a full file read;
#   2. the shared _dataWithContentsOfFile helper;
#   3. the options argument it passes to NSData, which is a hardcoded zero
#      where NSDataReadingMappedIfSafe (1 << 3) would make the pages mapped,
#      clean and evictable rather than private, dirty and swappable.
#
# DEVELOPER_DIR selects which Xcode to inspect. Read-only: nothing is modified.
if [[ -n "${DEVELOPER_DIR:-}" && "$DEVELOPER_DIR" == *.app ]]; then
  export DEVELOPER_DIR="$DEVELOPER_DIR/Contents/Developer"
fi
source "$(dirname "$0")/common.sh"

XCODE_APP="$(dirname "$(dirname "$(xcode-select -p)")")"
DVT="$XCODE_APP/Contents/SharedFrameworks/DVTFoundation.framework/Versions/A/DVTFoundation"
[[ -f "$DVT" ]] || { echo "error: DVTFoundation not found at $DVT" >&2; exit 1; }

OUT="${1:-$RESULTS/disassembly.txt}"
mkdir -p "$(dirname "$OUT")"

{
  echo "# $(xcodebuild -version | tr '\n' ' ')"
  echo "# $DVT"
  echo "# $(codesign -dvvv "$DVT" 2>&1 | grep -E '^TeamIdentifier' || true)"
  echo "#"
  echo
  echo "== exported Mach-O inspection symbols =========================="
  nm -gU "$DVT" 2>/dev/null | grep -iE 'MachOPlatforms|PlatformFamilyForMachO|MachOArch' || true
  echo
  echo "== DVTPlatformFamilyForMachO: first action is a whole-file read =="
  otool -tV -p _DVTPlatformFamilyForMachO "$DVT" 2>/dev/null \
    | sed -n '1,30p' | grep -E 'DVTPlatformFamilyForMachO:|bl\s|ret' || true
  echo
  echo "== _dataWithContentsOfFile: the shared helper ==================="
  echo "-- the NSData call and the options argument it passes:"
  otool -tV -p _dataWithContentsOfFile "$DVT" 2>/dev/null \
    | grep -B4 'initWithContentsOfFile:options:error:' || true
  echo
  echo "   The 'mov x3, #0x0' immediately preceding the call is the options"
  echo "   argument (x3 = 4th argument). NSDataReadingMappedIfSafe is 1 << 3."
  echo "   With options 0, Foundation allocates a private buffer the size of"
  echo "   the entire file instead of mapping it."
  echo
  echo "== raw bytes at the options instruction ========================="
  python3 - "$DVT" <<'PY'
import re, subprocess, sys, struct
path = sys.argv[1]
dis = subprocess.run(["otool", "-tV", "-p", "_dataWithContentsOfFile", path],
                     capture_output=True, text=True).stdout
addr = None
for line in dis.splitlines():
    m = re.match(r'([0-9a-f]{16})\s+mov\s+x3, #0x0', line)
    if m:
        addr = int(m.group(1), 16)
    if 'initWithContentsOfFile:options:error:' in line and addr is not None:
        break
if addr is None:
    print("   (instruction not located; layout differs in this build)")
    raise SystemExit(0)

# Locate the arm64 slice in the universal binary to convert vmaddr -> file offset.
info = subprocess.run(["lipo", "-detailed_info", path],
                      capture_output=True, text=True).stdout
slice_off, cur = 0, None
for line in info.splitlines():
    line = line.strip()
    if line.startswith("architecture "):
        cur = line.split()[1]
    elif line.startswith("offset ") and cur == "arm64":
        slice_off = int(line.split()[1]); break

off = slice_off + addr
with open(path, "rb") as f:
    f.seek(off); word = struct.unpack("<I", f.read(4))[0]
print(f"   vmaddr        0x{addr:x}")
print(f"   arm64 slice   0x{slice_off:x}")
print(f"   file offset   0x{off:x}")
print(f"   instruction   0x{word:08x}   MOVZ X3, #{(word >> 5) & 0xffff}")
print(f"   for reference MOVZ X3, #8 (NSDataReadingMappedIfSafe) = 0xd2800103")
PY
} | tee "$OUT"

echo
echo "== written to $OUT"
