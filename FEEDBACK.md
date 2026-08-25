# Feedback Assistant report (paste-ready)

**Title:** xcodebuild test-without-building: host-side memory scales ~9x with host app binary size due to eager symbolication; console output and unused attachments also multiply-buffered

**Area:** Developer Tools — Xcode / xcodebuild

**Type:** Unexpected behavior / performance

**Version:** Reproduced with Xcode 26.2 (17C52), 16.4 (16F6) and 16.1 (16B40) on macOS 26.2 (25C56), Apple silicon. The binary-size multiplier regressed from ~7x to ~9x between 16.1 and 16.4 (see "Regression history" below).

---

## Description

Running iOS simulator tests via `xcodebuild test-without-building -xctestrun ...`
allocates host-side (macOS) memory proportional to inputs that should not
require in-memory buffering:

1. **~9x the host app binary size, before the app under test launches.**
   The `xcodebuild` process's RSS grows ~9 MB per 1 MB of host app binary.
   Timeline sampling shows the growth completes before the test host
   process appears in the simulator, and padding the binary with inert
   `__TEXT` bytes (no extra code, no extra dSYM content) reproduces it —
   consistent with the test session's symbolication machinery
   (XCTOutOfProcessSymbolicationService) eagerly reading whole binaries
   into malloc'd memory instead of mmap'ing them and paging on demand.
   For a production app with a 400-500 MB binary this is 3.5-4.5 GB of
   host memory per test session — before any test runs. The multiplier
   was ~7x in Xcode 16.1 and is ~9x from 16.4 onward (see below).

2. **~14-26x the bytes a test writes to stdout** (multiplier grows with
   volume), retained for the duration of the session.

3. **~1.4-3x the size of XCTAttachment payloads that can never be used:**
   an attachment with `lifetime = .deleteOnSuccess` added by a passing
   test still costs multiples of its payload in host memory.

The practical impact is on CI: each concurrent `xcodebuild` test session
carries gigabytes of host-side overhead for a large app, so simulator test
parallelism is capped by host memory rather than CPU, even though the
simulators themselves and the app under test are comparatively small.

There is no public option to disable or defer the symbolication work
(nothing in `xcodebuild` flags, xctestrun keys, or documented environment
variables changes it).

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

## Expected results

- Host-side memory roughly independent of the size of the binaries under
  test: symbolication inputs mapped (mmap) and read lazily, or symbolication
  deferred until a failure actually needs symbolic frames — or at minimum an
  opt-out for sessions that do their own symbolication.
- Console output streamed with O(1) buffering.
- Attachment payloads that will be discarded (passing test,
  `.deleteOnSuccess`) not buffered in multiples on the host.

## Actual results

Peak host-side RSS per session: `~235 MB + ~9x(host binary bytes) +
~14-26x(stdout bytes) + ~1.4-3x(attachment bytes)`, concentrated in the
`xcodebuild` process itself. The binary-size term was ~7x as recently as
Xcode 16.1, so this has regressed rather than improved. Full per-case logs, per-process breakdowns,
and RSS timelines are produced by the repro scripts under `results/`.
