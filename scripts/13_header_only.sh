#!/bin/bash
# Experiment 9: how much of a Mach-O do you actually have to read to answer
# the question xcodebuild is asking?
#
# The call sites in section 5 of ANALYSIS.md want the platforms and
# architectures a binary supports. That is recorded in the Mach-O header and
# its load commands, which sit at the very start of the file. This script
# parses them out of a bounded prefix, prints the byte offsets involved, and
# checks the answer against `otool -l` reading the whole file.
#
# Usage: scripts/13_header_only.sh [binary ...]
# With no arguments it builds a 256 MB-padded fixture and inspects it.
source "$(dirname "$0")/common.sh"

TARGETS=("$@")
if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "no binary given; building a 256 MB-padded fixture to inspect"
  TEST_PAD_MB=256 "$ROOT/scripts/01_build_fixture.sh" >/dev/null
  F="$(fixture_path 0 256)"
  TARGETS=("$F/App.app/PlugIns/MemTests.xctest/MemTests" "$F/App.app/App")
fi

python3 - "${TARGETS[@]}" <<'PY'
import struct, subprocess, sys, os

FAT_MAGICS = {0xcafebabe: False, 0xcafebabf: True}
MH_MAGIC_64, MH_CIGAM_64 = 0xfeedfacf, 0xcffaedfe
LC_REQ_DYLD = 0x80000000
LC_BUILD_VERSION = 0x32
VERSION_MIN = {0x24: "macOS", 0x25: "iOS", 0x2F: "tvOS", 0x30: "watchOS"}
PLATFORM = {1: "macOS", 2: "iOS", 3: "tvOS", 4: "watchOS", 5: "bridgeOS",
            6: "MacCatalyst", 7: "iOSSimulator", 8: "tvOSSimulator",
            9: "watchOSSimulator", 10: "DriverKit"}
CPU = {0x0100000c: "arm64", 0x01000007: "x86_64", 0x0000000c: "arm",
       0x00000007: "i386"}


def slices(fh):
    """(offset, size) per architecture; a thin file is one slice."""
    fh.seek(0)
    magic = struct.unpack(">I", fh.read(4))[0]
    if magic in FAT_MAGICS:
        wide = FAT_MAGICS[magic]
        n = struct.unpack(">I", fh.read(4))[0]
        out = []
        for _ in range(n):
            if wide:
                _, _, off, size, _ = struct.unpack(">QQQQQ", fh.read(40))
            else:
                _, _, off, size, _ = struct.unpack(">IIIII", fh.read(20))
            out.append((off, size))
        return out
    return [(0, os.fstat(fh.fileno()).st_size)]


def inspect(path):
    total = os.path.getsize(path)
    print(f"{path}")
    print(f"  file size                 {total:>14,} bytes  ({total/1024/1024:.1f} MB)")

    needed_max = 0
    findings = []
    with open(path, "rb") as fh:
        for sl_off, _ in slices(fh):
            fh.seek(sl_off)
            magic = struct.unpack("<I", fh.read(4))[0]
            if magic not in (MH_MAGIC_64, MH_CIGAM_64):
                continue
            fh.seek(sl_off)
            # mach_header_64 is 32 bytes: magic, cputype, cpusubtype,
            # filetype, ncmds, sizeofcmds, flags, reserved.
            hdr = fh.read(32)
            _, cputype, _, _, ncmds, sizeofcmds, _, _ = struct.unpack("<IiiIIIII", hdr)
            arch = CPU.get(cputype & 0xffffffff, hex(cputype))

            # Everything needed lives in header + load commands.
            prefix_end = sl_off + 32 + sizeofcmds
            needed_max = max(needed_max, prefix_end)

            cmds = fh.read(sizeofcmds)
            pos, plats = 0, []
            for _ in range(ncmds):
                cmd, cmdsize = struct.unpack_from("<II", cmds, pos)
                real = cmd & ~LC_REQ_DYLD
                if real == LC_BUILD_VERSION:
                    plat = struct.unpack_from("<I", cmds, pos + 8)[0]
                    plats.append((PLATFORM.get(plat, f"platform {plat}"),
                                  sl_off + 32 + pos, cmdsize))
                elif real in VERSION_MIN:
                    plats.append((VERSION_MIN[real],
                                  sl_off + 32 + pos, cmdsize))
                pos += cmdsize
            findings.append((arch, ncmds, sizeofcmds, plats))

    for arch, ncmds, sizeofcmds, plats in findings:
        print(f"  arch {arch:<8}          {ncmds} load commands, "
              f"{sizeofcmds:,} bytes of them")
        for name, off, size in plats:
            print(f"    platform {name:<18} recorded at byte offset "
                  f"{off:,}, in {size} bytes")

    print(f"  bytes needed for answer   {needed_max:>14,} bytes  "
          f"({needed_max/1024:.1f} KB)")
    print(f"  bytes actually read       {total:>14,} bytes")
    if needed_max:
        print(f"  read amplification        {total/needed_max:>14,.0f}x")

    # Cross-check: does reading only the prefix give the same platform set as
    # otool -l over the whole file?
    ours = sorted({n for _, _, _, ps in findings for n, _, _ in ps})
    out = subprocess.run(["otool", "-l", path], capture_output=True, text=True).stdout
    theirs = set()
    for i, line in enumerate(out.splitlines()):
        s = line.strip()
        if s.startswith("platform "):
            v = s.split()[1]
            theirs.add(PLATFORM.get(int(v), v) if v.isdigit() else v.upper())
        elif s.startswith("cmd LC_VERSION_MIN_"):
            theirs.add({"LC_VERSION_MIN_IPHONEOS": "iOS",
                        "LC_VERSION_MIN_MACOSX": "macOS",
                        "LC_VERSION_MIN_TVOS": "tvOS",
                        "LC_VERSION_MIN_WATCHOS": "watchOS"}.get(s.split()[1], s))
    match = "yes" if ours and {o.upper() for o in ours} == {t.upper() for t in theirs} else \
            f"prefix={ours} otool={sorted(theirs)}"
    print(f"  same answer as otool -l   {match}")
    print()


print("How much of each binary must be read to learn its platforms/architectures?")
print("The Mach-O header is 32 bytes; the load commands follow immediately.")
print()
for p in sys.argv[1:]:
    if os.path.exists(p):
        inspect(p)
    else:
        print(f"{p}: not found\n")
PY
