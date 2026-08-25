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

## What is actually happening

### 1. The question xcodebuild is asking

Before running anything, the test harness validates the built products against
the run destination: *can this app and this test bundle actually run on the
simulator I was pointed at?* Answering that means knowing **which platforms and
architectures each Mach-O binary was built for** — is this an iOS-simulator
arm64 binary, or a device build, or macOS?

The call chain is visible in the allocation stacks:

```
-[XCTHTestRunSpecification _validateBuiltProductsForRunDestination:]
  -[XCTHTestRunSpecification _isValidBundleAtFilePath:forRunDestination:]
    -[DVTDevice supportsRunningExecutableAtPath:usingArchitecture:error:]
      DVTPlatformFamilyForMachO  /  DVTMachOPlatformsForExecutable
```

### 2. Where that answer actually lives

In the Mach-O format, this is recorded at the very front of the file. The
header is 32 bytes, the load commands follow immediately, and the platform is
one `LC_BUILD_VERSION` command inside them.

`scripts/13_header_only.sh` parses it out of a bounded prefix and checks the
result against `otool -l` reading the whole file
([`evidence/header_only.txt`](evidence/header_only.txt)). For a 257 MB test
bundle binary:

```
file size                    269,036,736 bytes  (256.6 MB)
arch arm64             33 load commands, 3,512 bytes of them
  platform iOSSimulator       recorded at byte offset 2,304, in 32 bytes
bytes needed for answer            3,544 bytes  (3.5 KB)
bytes actually read          269,036,736 bytes
read amplification                75,913x
same answer as otool -l   yes
```

The datum being sought is **32 bytes at offset 2,304**. Everything required to
find and read it — header plus all load commands — is **3.5 KB**, and it is
always at the start of the file regardless of how large the file is. The prefix
yields the identical answer to parsing the entire binary.

### 3. What it does instead

It reads the whole file. `NSData dataWithContentsOfFile:` is called with an
options argument of `0`, so Foundation allocates a private heap buffer the size
of the entire binary and copies every byte into it — 257 MB to consult 32 of
them, a **75,913x read amplification**. At 700 MB it is over 200,000x.

Two things make it worse than a single wasteful read:

- **It happens four times per session for the same file.** Three of the four
  stacks pass through `supportsRunningExecutableAtPath:` for the same path
  within one validation, and nothing caches the answer between them.
- **The memory is dirty, not mapped.** `NSData` offers
  `NSDataReadingMappedIfSafe`, which would `mmap` the file so its pages are
  clean and file-backed: the kernel could then drop them instantly under memory
  pressure. With options `0` the pages are anonymous and dirty, so they can
  only be compressed or written to swap. This is why the symptom is swapping
  rather than harmless page-cache growth.

On top of that, roughly six further copies' worth of freed buffers are never
returned to the OS, sitting in empty `MALLOC_LARGE` regions.

Only the binaries **named in the `.xctestrun`** are validated this way, which
is why the same bytes placed in an embedded dynamic library cost nothing at
all — see [Which binaries are charged](#which-binaries-are-charged).

### 4. Everything above is measured

Raw captures are committed under [`evidence/`](evidence/) so none of it has to
be taken on trust:

| Question | Answer | Where to look |
|---|---|---|
| How much memory, exactly? | linear and additive in both binaries; 16 held-out cells predicted to within 4 MB | [`evidence/matrix.csv`](evidence/matrix.csv) |
| Whose memory is it? | `xcodebuild`'s own, 233 MB → 2542 MB at +256 MB; the app under test does not grow | [`evidence/memmap-*/footprint.txt`](evidence/) |
| Why does it cause swap? | anonymous and dirty (~7.6 GB) not file-backed (~226 MB) | [`evidence/memmap-*/vm_stat.delta.txt`](evidence/) |
| What are the allocations? | four simultaneous full-size buffers, plus ~3 GB freed-but-resident | [`evidence/memmap-*/heap.excerpt.txt`](evidence/) |
| What allocates them? | run-destination validation reading whole files for their headers | [`evidence/memmap-*/malloc_history.large.txt`](evidence/) |
| Is reading the whole file necessary? | no — 3.5 KB gives the identical answer, 75,913x less | [`evidence/header_only.txt`](evidence/header_only.txt) |
| Is that really what the code does? | `mov x3, #0x0` — the options argument, decoded from the bytes on disk | [`evidence/disassembly.txt`](evidence/disassembly.txt) |
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
- `scripts/12_disassemble_dvt.sh` — dumps and byte-verifies the `options` argument
- `scripts/13_header_only.sh` — how few bytes actually answer the question
- `scripts/collect_evidence.sh` — refreshes `evidence/` from `results/`
- `ANALYSIS.md` — where the memory goes, and why
- `scripts/06_bisect_version.sh` — per-Xcode-version measurement for bisecting the regression
- `scripts/measure_rss.py` — samples the process tree + session helpers, tracks
  peak, and separately reports new processes outside the tracked set (the
  simulated app, `testmanagerd`, ...) so nothing material goes unseen
- `FEEDBACK.md` — the Feedback Assistant report this repository accompanies
