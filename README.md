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

The dominant effect is the first one, and it applies to every Mach-O in the
session. Sweeping both binaries (`scripts/08_matrix.sh`) gives a linear,
additive model that predicts held-out combinations to within 1 MB:

```
peak host RSS (MB) = 234 + 9.01 x (app binary MB) + 10.02 x (test bundle MB)
```

So a 400 MB app with a 700 MB test bundle costs **10.6 GB of host memory per
test session**, before any test runs, independent of what the tests do — which,
more than CPU, is what caps `-parallel-testing` / Bazel `--local_test_jobs`
style simulator parallelism.

`malloc_history` attributes the large allocations to whole-file reads
performed to inspect Mach-O headers — `DVTMachOPlatformsForExecutable`,
`DVTPlatformFamilyForMachO` and
`-[DVTDevice supportsRunningExecutableAtPath:usingArchitecture:error:]`, each
calling `NSData dataWithContentsOfFile:` without `NSDataReadingMappedIfSafe`
and so allocating a private copy of the entire file to read its first few
kilobytes. The pages are dirty and unreclaimable rather than mapped and
evictable, which is why the symptom is swap.

Only the binaries named in the `.xctestrun` are charged. The same 256 MB of
padding placed in an embedded dynamic library costs **nothing**:

| Padded binary | Peak | Multiplier |
|---------------|-----:|-----------:|
| baseline | 232 MB | — |
| `App.app/App` | 2543 MB | 9.03x |
| `App.app/PlugIns/*.xctest/MemTests` | 2799 MB | 10.03x |
| `App.app/Frameworks/libPadLib.dylib` | 231 MB | **0.00x** |

So moving code into embedded dynamic frameworks avoids the cost entirely, and
an `XCTestCase` subclass hosted in such a library is still discovered and run
(`scripts/11_experiment_discovery.sh`).

**See [`ANALYSIS.md`](ANALYSIS.md) for the full breakdown**, including the
`footprint`/`vmmap`/`heap`/`malloc_history` evidence, the mitigation, and what
a fix would look like.

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

### Which binary is charged

`scripts/07_experiment_test_bundle_size.sh` moves the same 256 MB of padding
between the host app binary and the `.xctest` bundle binary:

| Xcode | Padding in host app | Padding in .xctest bundle |
|-------|---------------------|---------------------------|
| 16.1  | 7.01x | 7.01x |
| 26.2  | 9.00x / 9.02x | 10.01x / 10.02x |

Both binaries are charged, so a large test bundle costs as much as a large
app — slightly more per megabyte on current Xcode. In 16.1 the two were
identical, so the regression added roughly two extra whole-binary reads for
the app and three for the test bundle.

The cost belongs to `xcodebuild` itself, not to the app under test: the
simulated app's RSS is unchanged by padding its own binary (the inert
`__TEXT` pages are mapped and never faulted in), while `xcodebuild` goes
from 220 MB to ~2.5 GB.

## Files

- `Sources/AppMain.swift`, `Sources/Tests.swift` — the fixture app + tests
- `scripts/01_build_fixture.sh` — builds app/bundle/xctestrun (`PAD_MB` pads the app binary)
- `scripts/02_run_case.sh` — one measured run (`CONSOLE_MB`, `ATTACH_MB`, `ONLY_TEST` knobs)
- `scripts/03..05_experiment_*.sh` — the three scaling experiments
- `scripts/07_experiment_test_bundle_size.sh` — app binary vs `.xctest` binary
- `scripts/08_matrix.sh` + `scripts/fit_matrix.py` — the (app x test bundle) matrix and its linear fit
- `scripts/09_memory_map.sh` — holds a session at peak and captures `footprint`,
  `vmmap`, `heap`, `malloc_history` and `vm_stat` deltas (`STACK_LOGGING=1` for
  allocation backtraces)
- `scripts/10_experiment_dylib.sh` — app binary vs test bundle vs embedded dylib
- `scripts/11_experiment_discovery.sh` — is a dylib-hosted `XCTestCase` discovered?
- `ANALYSIS.md` — where the memory goes, and why
- `scripts/06_bisect_version.sh` — per-Xcode-version measurement for bisecting the regression
- `scripts/measure_rss.py` — samples the process tree + session helpers, tracks
  peak, and separately reports new processes outside the tracked set (the
  simulated app, `testmanagerd`, ...) so nothing material goes unseen
- `FEEDBACK.md` — the Feedback Assistant report this repository accompanies
