# Feedback Assistant report (paste-ready)

**Title:** xcodebuild test-without-building: DVTFoundation reads entire Mach-O binaries into malloc'd memory to inspect their headers, costing ~9-10x binary size in dirty host RAM per test session

**Area:** Developer Tools — Xcode / xcodebuild

**Type:** Unexpected behavior / performance

**Version:** Reproduced with Xcode 26.2 (17C52), 16.4 (16F6) and 16.1 (16B40) on macOS 26.2 (25C56), Apple silicon. The binary-size multiplier regressed from ~7x to ~9x between 16.1 and 16.4 (see "Regression history" below).

---

## Description

Running iOS simulator tests via `xcodebuild test-without-building -xctestrun ...`
allocates host-side (macOS) memory proportional to inputs that should not
require in-memory buffering:

1. **~9-10x the size of the Mach-O binaries in the session, before the app
   under test launches.** The `xcodebuild` process's RSS grows ~9 MB per 1 MB
   of host app binary, and ~10 MB per 1 MB of `.xctest` bundle binary.
   Timeline sampling shows the growth completes before the test host
   process appears in the simulator, and padding a binary with inert
   `__TEXT` bytes (no code, no symbols, never executed or read) reproduces
   it exactly. Sweeping both binaries gives a linear, additive model:

       peak RSS (MB) = 234 + 9.01 x (app binary MB) + 10.02 x (test bundle MB)

   fitted on single-variable rows and predicting held-out combinations to
   within 1 MB, staying linear to 700 MB. For a 400 MB app with a 700 MB
   test bundle that is **10.6 GB of host memory per test session**, before
   any test runs.

   The cost is attached to the binary *files*, not to anything executing:
   the simulated app's own RSS does not change when its binary grows, and
   the entire increase appears in the host-side `xcodebuild` process
   (220 MB -> 2528 MB at +256 MB of padding, with every other process in
   the session flat).

   **The memory is dirty and private, not mapped file pages.** `footprint`
   at plateau with a 512 MB test bundle shows 5133 MB of 5237 MB in
   `MALLOC_LARGE`, 100% dirty, 0 bytes clean, 0 bytes reclaimable;
   system-wide `vm_stat` over the same window grows ~7.6 GB anonymous
   against ~226 MB file-backed. These pages cannot be evicted under
   pressure, only compressed or swapped.

   **Attribution.** With `MallocStackLogging` enabled, `malloc_history`
   attributes the large blocks to whole-file reads performed to inspect
   Mach-O headers:

       DVTMachOPlatformsForExecutable                     -> 257 MB
       DVTPlatformFamilyForMachO                          -> 257 MB
       -[DVTDevice supportsRunningExecutableAtPath:
                          usingArchitecture:error:]       -> 257 MB
       DVTMachOPlatformsForExecutable (second occurrence) -> 257 MB

   each via `dataWithContentsOfFile` ->
   `-[NSData initWithContentsOfFile:options:maxLength:error:]` ->
   `NSData._readBytes(fromPath:maxLength:bytes:length:didMap:...)`.

   These call sites need only the Mach-O header and load commands — the
   first few kilobytes — but `NSData dataWithContentsOfFile:` is called
   without `NSDataReadingMappedIfSafe`, so Foundation allocates a private
   buffer the size of the entire file. `heap` confirms four such
   full-size buffers alive simultaneously (`525392KB[4]` for a 512 MB
   bundle), and `vmmap` shows a further 3.0 GB of dirty pages in *empty*
   `MALLOC_LARGE` regions: freed allocations whose pages were never
   returned to the OS. Four live copies plus roughly six retained copies
   accounts for the observed ~10x.

   For completeness: symbolication is not the cause. `CoreSymbolicationDT`
   objects are present (21,492 live `CSCppSymbolOwner`) but total single-digit
   megabytes.

   **The cost is avoidable, which shows it is not inherent.** Placing the same
   256 MB of padding in an embedded dynamic library
   (`App.app/Frameworks/libPadLib.dylib`, linked by the app so dyld must load
   it) instead of in the app or test binary costs nothing at all:

   | Padded binary | Peak | Multiplier |
   |---------------|-----:|-----------:|
   | baseline | 232 MB | — |
   | `App.app/App` (xctestrun `TestHostPath`) | 2543 MB | 9.03x |
   | `App.app/PlugIns/*.xctest/MemTests` (`TestBundlePath`) | 2799 MB | 10.03x |
   | `App.app/Frameworks/libPadLib.dylib` | **231 MB** | **0.00x** |

   The same bytes, loaded into the same running test session, cost 10x in one
   Mach-O and 0x in another. Only the paths named in the `.xctestrun` are
   probed; binaries reached later by dyld are not. Whatever the probe
   establishes about `TestHostPath` and `TestBundlePath` is evidently not
   required for the dynamic libraries those binaries go on to load.

2. **~14-26x the bytes a test writes to stdout** (multiplier grows with
   volume), retained for the duration of the session.

3. **~1.4-3x the size of XCTAttachment payloads that can never be used:**
   an attachment with `lifetime = .deleteOnSuccess` added by a passing
   test still costs multiples of its payload in host memory.

The practical impact is on CI and on large local projects: each concurrent
`xcodebuild` test session carries gigabytes of host-side overhead, so
simulator test parallelism is capped by host memory rather than CPU, even
though the simulators themselves and the app under test are comparatively
small. On a 48 GB machine, a 400 MB app with a 700 MB test bundle permits
roughly four concurrent sessions. Because the pages are dirty rather than
evictable, a project that previously fit in RAM degrades into swap once it
crosses the threshold, rather than losing cache gracefully.

There is no public option to disable, defer, or cache this work — nothing in
`xcodebuild` flags, xctestrun keys, or documented environment variables
changes it.

## Regression history

The binary-size multiplier is not constant across Xcode releases. Measuring
the same fixture on the same machine and OS, with the host app binary padded
by 256 MB of inert `__TEXT` data:

| Xcode | Build | Simulator runtime | Peak, unpadded | Peak, +256 MB | Multiplier |
|-------|-------|-------------------|----------------|---------------|------------|
| 16.1  | 16B40 | iOS 18.6 | 229 MB | 2025 MB | **7.02x** |
| 16.4  | 16F6  | iOS 18.6 | 200 MB | 2508 MB | **9.02x** |
| 26.2  | 17C52 | iOS 26.2 | 232 MB | 2543 MB | **9.03x** |

Each row was measured twice; repeat runs agreed to within 1-2 MB
(16.1: 7.02x / 7.02x, 16.4: 9.02x / 9.02x). The 16.1 and 16.4 rows are
directly comparable: same macOS build, same iOS 18.6 runtime, same fixture
size, differing only in toolchain.

So roughly two additional whole-binary-sized allocations per test session
were introduced between Xcode 16.1 and 16.4 — a ~29% increase in the
dominant memory term — and the cost has remained at ~9x through 26.2.
For a 400 MB app binary that step alone is ~800 MB of extra host memory
per concurrent test session. Xcode 16.2 and 16.3 have not been measured,
so the change lands somewhere in 16.2...16.4.

The regression also made the two binaries in a session cost *different*
amounts, which was not previously the case. Padding the `.xctest` bundle
binary instead of the host app binary, same 256 MB, same machine:

| Xcode | Padding in host app | Padding in .xctest bundle |
|-------|---------------------|---------------------------|
| 16.1  | 7.01x               | 7.01x                     |
| 26.2  | 9.00x / 9.02x       | 10.01x / 10.02x           |

In 16.1 both binaries cost an identical 7x. In 26.2 the host app costs 9x
and the test bundle 10x — that is, the change added roughly two extra
whole-binary reads for the app and three for the test bundle. Test bundle
size therefore matters more than app size per megabyte, which is
significant for projects whose test bundles statically link large amounts
of code.

In every version the growth completes ~1 second into the run, before the
test body executes, which is consistent with it happening during test
session setup rather than during test execution.

`scripts/06_bisect_version.sh` reproduces this table:
`DEVELOPER_DIR=/Applications/Xcode_16.1.app scripts/06_bisect_version.sh`.

## Steps to reproduce

1. `git clone https://github.com/erneestoc/xcodebuild-memory-repro`
2. `cd xcodebuild-memory-repro && ./scripts/run_all.sh`

The scripts build a minimal app + app-hosted XCTest bundle with `swiftc`
(no Xcode project), generate an `.xctestrun`, run
`xcodebuild test-without-building`, and sample RSS of the session's
processes. Each experiment isolates one variable:

- `scripts/03_experiment_binary_size.sh` — pads the host app binary with
  0 / 64 / 256 MB of inert `__TEXT` data and shows peak RSS growing ~9x
  the added size (measured: 235 MB baseline → 2531 MB at +256 MB).
- `scripts/04_experiment_console_output.sh` — the test writes N MB to
  stdout; peak grows ~14-26x N.
- `scripts/05_experiment_attachments.sh` — the test adds one N MB
  attachment with `lifetime = .deleteOnSuccess` and passes; peak still
  grows ~1.4-3x N.
- `scripts/07_experiment_test_bundle_size.sh` — moves the same 256 MB of
  padding between the host app binary and the `.xctest` bundle binary,
  showing the multiplier applies to both (9x and 10x respectively on 26.2).
- `scripts/08_matrix.sh` — sweeps both binaries independently and together
  and fits the linear model, holding out the mixed cases.
- `STACK_LOGGING=1 scripts/09_memory_map.sh` — holds a session at peak and
  captures `footprint`, `vmmap`, `heap`, `malloc_history` and `vm_stat`
  deltas, producing the attribution above.
- `scripts/10_experiment_dylib.sh` — puts the same padding in the app binary,
  the test bundle binary and an embedded dylib, showing 9x / 10x / 0x.
- `scripts/11_experiment_discovery.sh` — confirms an `XCTestCase` subclass
  hosted in an embedded dylib is still discovered and run.

`ANALYSIS.md` in the repository collects the full breakdown.

## Expected results

- Header inspection should read the Mach-O header and load commands, not the
  whole file. Any of the following would materially reduce the peak:
  1. read only the header/load commands;
  2. pass `NSDataReadingMappedIfSafe` so the pages are clean and evictable
     rather than dirty and swappable;
  3. cache the per-path result so independent call sites do not each re-read
     the same binary;
  4. return large transient buffers to the OS rather than leaving dirty pages
     in empty `MALLOC_LARGE` regions.
- Console output streamed with O(1) buffering.
- Attachment payloads that will be discarded (passing test,
  `.deleteOnSuccess`) not buffered in multiples on the host.

## Actual results

Peak host-side RSS per session: `~234 MB + 9.01x(host app binary bytes) +
10.02x(.xctest binary bytes) + ~14-26x(stdout bytes) +
~1.4-3x(attachment bytes)`, concentrated in the `xcodebuild` process itself
and consisting almost entirely of dirty, unreclaimable `MALLOC_LARGE` pages.
Both binary terms were ~7x as recently as Xcode 16.1, so this has regressed
rather than improved. Full per-case logs, per-process breakdowns, RSS
timelines, and the memory-attribution captures are produced by the repro
scripts under `results/`.
