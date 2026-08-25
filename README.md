# xcodebuild test memory repro

`xcodebuild test-without-building` allocates roughly **nine to ten times the
size of the binaries under test** in host memory, per test session, before any
test runs. The memory is private and dirty, so it cannot be evicted under
pressure — only compressed or swapped.

```
peak host RSS (MB) = 232 + 9.02 x (app binary MB) + 10.02 x (test bundle MB)
```

Measured across a full 5 x 5 grid of binary sizes; every combination the fit
never saw is predicted to within 4 MB. A 400 MB app with a 700 MB test bundle
costs 10.6 GB per session, and 700 MB in each costs 13.6 GB.

**Cause.** Before running, the harness validates the built products against the
run destination — `-[XCTHTestRunSpecification
_validateBuiltProductsForRunDestination:]` down through
`-[DVTDevice supportsRunningExecutableAtPath:usingArchitecture:error:]` and
`DVTMachOPlatformsForExecutable`. It needs to know which platforms and
architectures each Mach-O supports, which is recorded in the file's header and
load commands. To read those few kilobytes it calls
`NSData dataWithContentsOfFile:` with a hardcoded `options: 0` instead of
`NSDataReadingMappedIfSafe`, so Foundation allocates a private copy of the
entire file. This happens four times per session for the same file, nothing
caches the answer between them, and roughly six more copies' worth of freed
pages are never returned to the OS.

Everything above is measured, and the raw captures are committed under
[`evidence/`](evidence/) so none of it has to be taken on trust:

| Question | Answer | Where to look |
|---|---|---|
| How much memory, exactly? | linear and additive in both binaries, predicting held-out cells to ~1 MB | [`evidence/matrix.csv`](evidence/matrix.csv) |
| Whose memory is it? | `xcodebuild`'s own, 220 MB → 2528 MB; the app under test does not grow | [`evidence/memmap-*/footprint.txt`](evidence/) |
| Why does it cause swap? | anonymous and dirty (~7.6 GB) not file-backed (~226 MB) | [`evidence/memmap-*/vm_stat.delta.txt`](evidence/) |
| What are the allocations? | four simultaneous full-size buffers, plus ~3 GB freed-but-resident | [`evidence/memmap-*/heap.excerpt.txt`](evidence/) |
| What allocates them? | whole-file reads for Mach-O header inspection | [`evidence/memmap-*/malloc_history.large.txt`](evidence/) |
| Is that really what the code does? | `mov x3, #0x0` — options argument, verified against the bytes on disk | [`evidence/disassembly.txt`](evidence/disassembly.txt) |
| Is the cost avoidable? | the same bytes in an embedded dylib cost 0.00x | [`evidence/placement/`](evidence/) |
| Has it got worse? | 7.01x in Xcode 16.1 → 9x/10x from 16.4 | [`evidence/bisect.csv`](evidence/bisect.csv) |

**[`ANALYSIS.md`](ANALYSIS.md) is the full write-up.**
[`FEEDBACK.md`](FEEDBACK.md) is the Apple Feedback Assistant report.

## Requirements

- macOS with Xcode (tested with Xcode 26.x on macOS 26, Apple silicon)
- an iOS simulator runtime installed (any recent iPhone device type)

No Xcode project is needed: the scripts build a minimal host app and an
app-hosted XCTest bundle directly with `swiftc`, generate an `.xctestrun`,
run it with `xcodebuild test-without-building`, and sample the resident
memory of the session's processes until it exits. Binary size is varied by
linking an inert `__TEXT` section, so between two cases only the *size* of a
file differs — no extra code, symbols, relocations or resources, and nothing
the test reads or executes.

## Run

```sh
./scripts/run_all.sh          # everything, then refreshes evidence/
QUICK=1 ./scripts/run_all.sh  # skips the 25-cell matrix and the memory capture
```

The full run builds and measures 25 fixtures, some 700 MB, so allow time and
~15 GB of free disk. Results land in `results/`; the load-bearing captures are
copied into `evidence/`. Individual experiments run standalone, and single
cases via `scripts/02_run_case.sh` (see its header for knobs).

Comparing toolchains is separate, one Xcode at a time:

```sh
DEVELOPER_DIR=/Applications/Xcode_16.1.app scripts/06_bisect_version.sh
```

## What it demonstrates

Measured on an M4 Max, 48 GB, macOS 26.2 (25C56), Xcode 26.2 (17C52), against a
warm booted simulator. Peak aggregate RSS of `xcodebuild` plus session helpers.

### The size of the binaries (the dominant effect)

The full 5 x 5 grid, peak host RSS in MB. Only the first row and column — where
a single binary is padded — were used to fit the model; the sixteen cells where
**both** are padded were held out entirely.

| app \ test | 0 MB | 128 MB | 256 MB | 512 MB | 700 MB |
|-----------:|-----:|-------:|-------:|-------:|-------:|
| **0 MB**   | 233 | 1514 | 2798 | 5361 | 7247 |
| **128 MB** | 1385 | *2672* | *3953* | *6517* | *8401* |
| **256 MB** | 2542 | *3823* | *5106* | *7671* | *9555* |
| **512 MB** | 4848 | *6132* | *7415* | *9979* | *11865* |
| **700 MB** | 6544 | *7827* | *9110* | *11675* | *13562* |

Prediction error across all twenty-five cells, in MB:

| app \ test | 0 | 128 | 256 | 512 | 700 |
|-----------:|--:|----:|----:|----:|----:|
| **0**   | +1 | -1 | +1 | -1 | +1 |
| **128** | -1 | *+3* | *+2* | *+0* | *+1* |
| **256** | +2 | *+0* | *+0* | *+0* | *+1* |
| **512** | -1 | *+1* | *+1* | *+0* | *+2* |
| **700** | +0 | *+1* | *+1* | *+1* | *+4* |

Every held-out combination lands within 4 MB, 0.1% at the top of the range, so
the two costs are independent and additive. The relationship stays linear to
700 MB per binary — it does not taper off at realistic sizes.

### Which binaries are charged

Only the Mach-Os named in the `.xctestrun`. The same 256 MB of padding placed
in an embedded dynamic library that the app links, and that dyld therefore
loads, costs nothing:

| Padded binary | Named in xctestrun | Peak | Multiplier |
|---------------|--------------------|-----:|-----------:|
| baseline | — | 232 MB | — |
| `App.app/App` | TestHostPath | 2543 MB | 9.03x |
| `App.app/PlugIns/*.xctest/MemTests` | TestBundlePath | 2799 MB | 10.03x |
| `App.app/Frameworks/libPadLib.dylib` | no | 231 MB | **0.00x** |

The same bytes cost 10x in one Mach-O and nothing in another, so the cost is
not inherent to having large binaries under test. Moving code into embedded
dynamic frameworks avoids it entirely, and an `XCTestCase` subclass hosted in
such a library is still discovered and run
(`scripts/11_experiment_discovery.sh`; see the caveat about Xcode's test
navigator in [`ANALYSIS.md`](ANALYSIS.md)).

### Two smaller effects

| Case | Peak RSS | Effect |
|---|---|---|
| test writes 4 MB to stdout | ~292 MB | ~14x the bytes written |
| test adds one 64 MB `XCTAttachment`, `lifetime = .deleteOnSuccess`, test passes | ~421 MB | ~2.9x a payload that could never be needed |

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

The regression also made the two binaries cost *different* amounts, which was
not previously the case (`scripts/07_experiment_test_bundle_size.sh`):

| Xcode | Padding in host app | Padding in .xctest bundle |
|-------|---------------------|---------------------------|
| 16.1  | 7.01x | 7.01x |
| 26.2  | 9.00x / 9.02x | 10.01x / 10.02x |

In 16.1 both binaries cost an identical 7.01x. By 26.2 the app costs 9x and
the test bundle 10x — the signature of call sites being added, roughly two
more whole-file reads for the app and three for the test bundle, rather than
of any single read becoming more expensive.

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
