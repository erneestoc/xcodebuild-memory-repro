# xcodebuild test memory repro

Self-contained scripts that reproduce and measure host-side (macOS) memory
behavior of `xcodebuild test-without-building` that limits how many iOS
simulator test sessions a CI machine can run in parallel.

No Xcode project is needed: the scripts build a minimal host app and an
app-hosted XCTest bundle directly with `swiftc`, generate an `.xctestrun`,
run it with `xcodebuild test-without-building`, and sample the resident
memory of the session's processes until it exits.

## Requirements

- macOS with Xcode (tested with Xcode 26.x on macOS 26, Apple silicon)
- an iOS simulator runtime installed (any recent iPhone device type)

## Run

```sh
./scripts/run_all.sh
```

Takes ~10 minutes. Results (peak memory per case, per-process breakdown,
and RSS timelines) land in `results/`; a consolidated table is printed at
the end. Individual experiments can be run separately
(`scripts/03..05_experiment_*.sh`), and single cases via
`scripts/02_run_case.sh` (see its header for knobs).

## What it demonstrates

Measured on an M4 Max, Xcode 26.2, warm booted simulator. Peak aggregate
RSS of `xcodebuild` + session helpers, from `results/summary.txt`:

| Case | Peak RSS | Effect |
|---|---|---|
| baseline (100 KB host app binary, trivial test) | ~235 MB | fixed session cost |
| host app binary +256 MB of inert `__TEXT` padding | ~2531 MB | **~9.0x the added binary size** |
| test writes 4 MB to stdout | ~292 MB | ~14x the bytes written |
| test adds one 64 MB `XCTAttachment`, `lifetime = .deleteOnSuccess`, test passes | ~421 MB | ~2.9x the payload that could never be needed |

The dominant effect is the first one: host-side memory grows ~9 MB for
every 1 MB of host app binary, before the app under test even launches
(the RSS climb completes before the app process appears in the simulator).
The growth is attributable to eager, in-memory symbolication reads of the
test session's binaries (`XCTOutOfProcessSymbolicationService` machinery
reading whole binaries into malloc'd memory rather than mapping them).

For a production app with a 400-500 MB binary this is 3.5-4.5 GB of
host-side memory per concurrent test session, independent of what the
tests do — which, more than CPU, is what caps `-parallel-testing` /
Bazel `--local_test_jobs` style simulator parallelism on CI hosts.

## Bisecting across Xcode versions

To find which Xcode release introduced (or grew) the binary-size multiplier,
run the same measurement under each installed Xcode:

```sh
DEVELOPER_DIR=/Applications/Xcode_16.1.app scripts/06_bisect_version.sh
DEVELOPER_DIR=/Applications/Xcode_26.2.app scripts/06_bisect_version.sh
```

Each invocation rebuilds the fixture with that toolchain's SDK, pairs it with
a simulator runtime matching the SDK's major version (downloading one via
`xcodebuild -downloadPlatform iOS` if needed), measures the pad-0 and pad-256
cases on a dedicated device, and appends one row to `results/bisect.csv`:

```
date,xcode_version,xcode_build,macos,runtime,peak_pad0_mb,peak_pad256_mb,slope_mb_per_mb
```

`slope_mb_per_mb` is the per-version comparison metric: extra host-side MB per
MB of host app binary. It is independent of machine size and fixture choice.
A freshly expanded Xcode may first need
`sudo DEVELOPER_DIR=<path> xcodebuild -runFirstLaunch`.

### Measured so far

macOS 26.2 (25C56), Apple silicon, 256 MB of `__TEXT` padding:

| Xcode | Build | Runtime | Unpadded | +256 MB | Multiplier |
|-------|-------|---------|----------|---------|------------|
| 16.1  | 16B40 | iOS 18.6 | 229 MB | 2025 MB | **7.02x** |
| 16.4  | 16F6  | iOS 18.6 | 200 MB | 2508 MB | **9.02x** |
| 26.2  | 17C52 | iOS 26.2 | 232 MB | 2543 MB | **9.03x** |

Repeat runs agree to within 1-2 MB. The multiplier rose ~29% between 16.1
and 16.4 and has been flat since; 16.2 and 16.3 are not yet measured, so the
change lands somewhere in 16.2...16.4. The 16.1/16.4 rows share a macOS
build, a simulator runtime and a fixture, so the toolchain is the only
variable between them.

## Files

- `Sources/AppMain.swift`, `Sources/Tests.swift` — the fixture app + tests
- `scripts/01_build_fixture.sh` — builds app/bundle/xctestrun (`PAD_MB` pads the app binary)
- `scripts/02_run_case.sh` — one measured run (`CONSOLE_MB`, `ATTACH_MB`, `ONLY_TEST` knobs)
- `scripts/03..05_experiment_*.sh` — the three scaling experiments
- `scripts/06_bisect_version.sh` — per-Xcode-version measurement for bisecting the regression
- `scripts/measure_rss.py` — samples the process tree + session helpers, tracks peak
- `FEEDBACK.md` — the Feedback Assistant report this repository accompanies
