# Where the memory goes

This document records what `xcodebuild test-without-building` actually does
with host memory, measured rather than inferred. Every number below is
reproducible with the scripts in this repository.

## 0. Summary

- Running simulator tests costs
  `232 MB + 9.02 x (app binary MB) + 10.02 x (test bundle MB)` of host RAM per
  test session. Measured across a full 5 x 5 grid: linear to 700 MB per binary,
  additive, and predicting all sixteen held-out combinations to within 4 MB.
  A 400 MB app with a 700 MB test bundle costs **10.6 GB per session** before a
  single test runs; 700 MB in each costs **13.6 GB**.
- The memory belongs to the `xcodebuild` process, not the app under test, and
  is **dirty, private and unreclaimable** (`MALLOC_LARGE`, 0 bytes clean,
  0 reclaimable). It cannot be evicted under pressure, only compressed or
  swapped — which is why the symptom is swap rather than harmless cache use.
- The cause is not symbolication. The test harness validates the built products
  against the run destination (`XCTHTestRunSpecification`
  `_validateBuiltProductsForRunDestination:`), which asks which platforms and
  architectures each Mach-O supports — a question answered by the file's header.
  To answer it, **the entire file is read into malloc'd memory**, four separate
  times per session, with `options: 0` rather than `NSDataReadingMappedIfSafe`.
  Four full copies are live at once and roughly six more copies' worth of freed
  pages are never returned to the OS.
- The cost applies only to the binaries named in the `.xctestrun`. The same
  bytes in an embedded dynamic library cost **0.00x**, which both proves the
  cost is not inherent and provides a mitigation available today.
- It has regressed: the multiplier was a uniform **7.01x** for both binaries in
  Xcode 16.1 and is **9x / 10x** from 16.4 through 26.2.

## 1. The cost model

Sweeping the host app binary and the `.xctest` bundle binary independently and
together (`scripts/08_matrix.sh`) gives a strikingly simple result:

```
peak host RSS (MB) = 234 + 9.01 x (app binary MB) + 10.02 x (test bundle MB)
```

The full 5 x 5 grid, every cell measured
([`evidence/matrix.csv`](evidence/matrix.csv)). Peak host RSS in MB, with the
model's prediction and error underneath. Cells where **both** binaries are
padded were held out of the fit entirely:

| app \ test | 0 MB | 128 MB | 256 MB | 512 MB | 700 MB |
|-----------:|-----:|-------:|-------:|-------:|-------:|
| **0 MB**   | 233 | 1514 | 2798 | 5361 | 7247 |
| **128 MB** | 1385 | *2672* | *3953* | *6517* | *8401* |
| **256 MB** | 2542 | *3823* | *5106* | *7671* | *9555* |
| **512 MB** | 4848 | *6132* | *7415* | *9979* | *11865* |
| **700 MB** | 6544 | *7827* | *9110* | *11675* | *13562* |

*Italic cells were never seen by the fit.*

Fitted on the nine single-variable rows only:

```
peak_mb = 232 + 9.02 x app_mb + 10.02 x test_mb
```

Errors across all 25 cells, in MB:

| app \ test | 0 | 128 | 256 | 512 | 700 |
|-----------:|--:|----:|----:|----:|----:|
| **0**   | +1 | -1 | +1 | -1 | +1 |
| **128** | -1 | +3 | +2 | +0 | +1 |
| **256** | +2 | +0 | +0 | +0 | +1 |
| **512** | -1 | +1 | +1 | +0 | +2 |
| **700** | +0 | +1 | +1 | +1 | +4 |

Every one of the sixteen held-out combinations is predicted to within 4 MB —
0.1% at the top of the range. The two costs are genuinely independent and
additive, and the relationship stays linear all the way to 700 MB per binary:
it does not taper off at realistic sizes. The worst case measured here,
700 MB in each binary, is **13.6 GB for a single test session**.

The padding is inert `__TEXT` data: no code, no symbols, no relocations,
never executed and never read by the test. Only the *size* of the file
changes.

## 2. It is the build tool's memory, not the app's

At +256 MB of padding the host-side `xcodebuild` process goes from 220 MB to
2528 MB. Every other process in the session is flat: `DTServiceHub` stays at
12 MB, and the app running inside the simulator does not grow at all when its
own binary grows, because the padded pages are mapped and never faulted in.

The cost is attached to the *files*, not to anything executing.

## 3. The memory is dirty and private, not cached file pages

This is the distinction that decides whether the memory is harmful.

`footprint` on the process at plateau, with a 512 MB test bundle:

```
xcodebuild [59537]: Footprint: 5237 MB

  Dirty      Clean  Reclaimable    Regions    Category
5133 MB        0 B          0 B         51    MALLOC_LARGE
  65 MB        0 B          0 B         27    MALLOC_SMALL
  18 MB      80 KB          0 B       1048    __DATA_CONST
```

98% of the footprint is `MALLOC_LARGE`, and it is **100% dirty, 0 bytes
clean, 0 bytes reclaimable**. System-wide `vm_stat` over the same window
agrees: anonymous memory grew ~7.6 GB while file-backed memory grew only
~226 MB.

Had the binaries been memory-mapped, their pages would be clean and
file-backed: the kernel could evict them instantly under pressure and they
would never reach swap. Anonymous dirty pages have no such escape — under
pressure they can only be compressed or written to swap. This is why the
symptom is swap rather than harmless page cache growth.

## 4. What the allocations are

`heap` shows the live large blocks with a 512 MB test bundle:

```
All zones: 430307 nodes malloced - Sizes: 525392KB[4] 512KB[1] 272KB[1] ...
```

Four live allocations of 525,392 KB — exactly the padded binary's size —
held **simultaneously**.

The `vmmap` zone table accounts for the rest:

```
MALLOC_LARGE            2.0G   2.0G dirty   20 regions
MALLOC_LARGE (empty)    3.0G   3.0G dirty   31 regions
```

So of ~5.1 GB: about 2 GB is four live copies, and about 3 GB sits in
*empty* malloc regions — allocations that were already freed but whose dirty
pages were never returned to the OS. Roughly six further copies' worth of RAM
is held by memory the process is no longer using. Four live copies plus about
six retained copies is the observed ~10x.

## 5. Root cause: whole files read to parse their headers

With `MallocStackLogging` enabled, `malloc_history` attributes every large
block. With a 256 MB test bundle, four live 257 MB allocations account for
1,026 MB, and every one of them is the test harness validating the built
products against the run destination. Full stacks are in
[`evidence/memmap-test256/malloc_history.large.txt`](evidence/memmap-test256/malloc_history.large.txt);
innermost Foundation frames are identical in all four and elided here:

```
[1]  -[DVTDevice(IDETestHarnessConformance) supportsRunningExecutableAtURL:…]
       -[DVTDevice(IDEFoundationAdditions) supportsRunningExecutableAtPath:…]
         DVTPlatformFamilyForMachO
           DVTMachOPlatformsForExecutable
             dataWithContentsOfFile                                  257 MB

[2]  -[XCTHTestRunSpecification _isValidBundleAtFilePath:forRunDestination:…]
       -[DVTDevice(IDETestHarnessConformance) supportsRunningExecutableAtURL:…]
         -[DVTDevice(IDEFoundationAdditions) supportsRunningExecutableAtPath:…]
           DVTPlatformFamilyForMachO
             dataWithContentsOfFile                                  257 MB

[3]  -[XCTHTestRunSpecification _validateBuiltProductsForRunDestination:…]
       -[XCTHTestRunSpecification _isValidBundleAtFilePath:forRunDestination:…]
         -[DVTDevice(IDETestHarnessConformance) supportsRunningExecutableAtURL:…]
           -[DVTDevice(IDEFoundationAdditions) supportsRunningExecutableAtPath:…]
             +[NSData dataWithContentsOfFile:options:error:]         257 MB

[4]  XCTHTestRunSpecification.populateiOSMacProperty()
       DVTMachOPlatformForExecutable
         DVTMachOPlatformsForExecutable
           dataWithContentsOfFile                                    257 MB

  all four then:
    -[NSData initWithContentsOfFile:options:maxLength:error:]
      NSData._readBytes(fromPath:maxLength:bytes:length:didMap:options:…)
        readBytesFromFile(path:reportProgress:maxLength:options:…)
          _malloc_zone_malloc_instrumented_or_legacy
```

The purpose is narrow and identical throughout: establishing **which platforms
and architectures a Mach-O supports**, so the harness can decide whether the
bundle can run on the chosen destination, plus one query for an iOSMac
property. That answer lives in the Mach-O header and load commands — the first
few kilobytes of the file.

To obtain it, each path calls `NSData dataWithContentsOfFile:` without
`NSDataReadingMappedIfSafe`, so Foundation allocates a private buffer the size
of the entire file and reads all of it. The `didMap:` parameter visible in the
Foundation frames is precisely the switch that would have made these pages
mapped, clean and evictable; it is not requested.

Two details matter for anyone fixing this:

- **The reads are redundant with each other.** Stacks [1], [2] and [3] pass
  through `supportsRunningExecutableAtPath:` for the same file within the same
  validation, and [4] asks a related question about the same file. Nothing
  caches the answer between them, so one logical question costs four full
  reads.
- **There is more than one call site.** Stacks [1], [2] and [4] route through
  `DVTFoundation`'s shared `dataWithContentsOfFile` helper, but [3] calls
  `+[NSData dataWithContentsOfFile:options:error:]` directly from
  `supportsRunningExecutableAtPath:`. Changing only the shared helper would
  therefore reduce the cost but not eliminate it.

Note that this is **not** symbolication. Symbolication machinery is present in
the process — `heap` shows 21,492 live `CSCppSymbolOwner` objects from
`CoreSymbolicationDT` — but those objects total single-digit megabytes. The
multi-gigabyte term is Mach-O platform probing, and an earlier version of this
repository attributed it incorrectly before stack logging was available.

## 6. Is the cost justified?

On the evidence, no, and the reasons are specific:

1. **The data read is thousands of times larger than the data needed.**
   Platform and architecture information is in the header. Reading 700 MB to
   examine the first few kilobytes is pure waste, and it scales with a number
   nobody expects to matter: the size of a binary's inert payload.
2. **The cheaper path was available at the same call.** `NSData` supports
   mapped reads. Choosing a mapped read would make the pages clean and
   evictable even if the whole file were still "read", removing the swap
   pressure entirely without changing any logic.
3. **The same file is read repeatedly by independent call sites.** At least
   three distinct entry points each perform their own full read, with no
   shared cache of the answer.
4. **Most of the memory is not even in use.** ~3 of ~5 GB is freed
   allocations whose dirty pages were never released. No workload benefits
   from this; it is a consequence of large short-lived buffers churning
   through the allocator.

None of this indicates a deliberate trade-off. There is no feature being
bought with the memory, no cache being warmed, no speed being gained — the
work is redundant on its own terms. The most consistent explanation is that
these call sites were written against binaries small enough for the
difference to be invisible, and were never profiled against large ones. The
version data supports that reading: the multiplier was a uniform 7x for both
binaries in Xcode 16.1 and became 9x for the app and 10x for the test bundle
by 16.4, which is what adding call sites over time looks like.

## 7. Version history

| Xcode | Build | App binary | Test bundle |
|-------|-------|-----------:|------------:|
| 16.1  | 16B40 | 7.01x | 7.01x |
| 16.4  | 16F6  | 9.02x | (not measured) |
| 26.2  | 17C52 | 9.00x / 9.02x | 10.01x / 10.02x |

Raw measurements behind the app-binary column, each an independent run
including a fresh fixture build and a fresh simulator device:

| Xcode | Build | Runtime | Unpadded | +256 MB | Multiplier |
|-------|-------|---------|---------:|--------:|-----------:|
| 16.1  | 16B40 | iOS 18.6 | 229 MB | 2025 MB | 7.02x |
| 16.1  | 16B40 | iOS 18.6 | 228 MB | 2026 MB | 7.02x |
| 16.4  | 16F6  | iOS 18.6 | 200 MB | 2508 MB | 9.02x |
| 16.4  | 16F6  | iOS 18.6 | 200 MB | 2510 MB | 9.02x |
| 16.4  | 16F6  | iOS 18.6 | 198 MB | 2507 MB | 9.02x |
| 26.2  | 17C52 | iOS 26.2 | 232 MB | 2543 MB | 9.03x |

The 16.1 and 16.4 rows share a macOS build, a simulator runtime and a fixture
size, so the toolchain is the only variable between them. Xcode 16.2 and 16.3
have not been measured, so the step lands somewhere in 16.2...16.4.

Two things changed at once. The multiplier rose by ~29%, and the two binaries
stopped costing the same: 16.1 charged an identical 7.01x for app and test
bundle bytes, while 26.2 charges 9x and 10x. That is the signature of call
sites being added — roughly two more whole-file reads for the app and three
for the test bundle — rather than of any single read becoming more expensive.

## 8. Practical consequences

Using the fitted model, for one test session:

| App binary | Test bundle | Peak host RSS |
|-----------:|------------:|--------------:|
|     50 MB  |      50 MB  |      1.2 GB   |
|    200 MB  |     300 MB  |      5.0 GB   |
|    400 MB  |     500 MB  |      8.8 GB   |
|    400 MB  |     700 MB  |     10.6 GB   |
|    500 MB  |     700 MB  |     11.5 GB   |

Consequences that follow directly:

- **Parallelism is capped by host RAM, not CPU.** On a 48 GB machine, a
  400 MB app with a 700 MB test bundle allows roughly four concurrent
  sessions before the machine is out of memory, on hardware with far more
  cores than that.
- **The cost is paid per session, not per test.** Splitting a suite into more
  targets multiplies this fixed cost rather than amortising it, so sharding
  for speed can make memory worse.
- **Test bundle size is the more expensive axis.** Each megabyte of `.xctest`
  binary costs more than a megabyte of app binary, which inverts the usual
  intuition that the app is the heavy artifact.
- **Growth is invisible until it is sudden.** Because the memory is dirty and
  unevictable, a project sits comfortably in RAM until it does not, and then
  degrades sharply into swap. Binary growth over time and the 16.x multiplier
  increase compound here.

## 9. Which Mach-Os are charged, and the mitigation that follows

The cost does not apply to every Mach-O in the app bundle. Placing the same
256 MB of inert padding in three different binaries within one bundle
(`scripts/10_experiment_dylib.sh`):

| Padded binary | Location | Peak | Multiplier |
|---------------|----------|-----:|-----------:|
| baseline      | —        | 232 MB | — |
| host app      | `App.app/App` (xctestrun `TestHostPath`) | 2543 MB | 9.03x |
| test bundle   | `App.app/PlugIns/*.xctest/MemTests` (`TestBundlePath`) | 2799 MB | 10.03x |
| **embedded dylib** | `App.app/Frameworks/libPadLib.dylib` | **231 MB** | **0.00x** |

In the dylib case the app links the library (`@rpath/libPadLib.dylib` appears
in its load commands via `-needed-l`, so dyld must resolve it at launch), the
app launches, and the test passes — the 257 MB library is genuinely loaded.
It simply costs nothing on the host.

This is strong evidence that the cost is not inherent to having large binaries
in a test session. It follows the paths named in the `.xctestrun`
(`TestHostPath`, `TestBundlePath`), which are the arguments handed to
`DVTMachOPlatformsForExecutable`, `DVTPlatformFamilyForMachO` and
`-[DVTDevice supportsRunningExecutableAtPath:usingArchitecture:error:]`.
Binaries reached later by dyld are never probed.

**Mitigation: move code out of the app and test binaries into embedded
dynamic frameworks.** Every megabyte relocated from the app binary saves
~9 MB of host RAM per session, and every megabyte moved out of the `.xctest`
binary saves ~10 MB. A project with a 400 MB app and a 700 MB test bundle
pays 10.6 GB per session; the same code split into dynamic frameworks with
thin app and test binaries approaches the ~234 MB baseline.

This works today, needs no cooperation from Apple, and is a normal
modularisation change rather than a hack.

### Test discovery still works

The obvious worry is that XCTest discovers tests by enumerating the test
bundle, so moving code out might hide it. `scripts/11_experiment_discovery.sh`
checks this directly by compiling an `XCTestCase` subclass into
`App.app/Frameworks/libDylibTests.dylib`, linking the `.xctest` binary against
it, and running the whole bundle with no `-only-testing`:

```
Test Suite 'Frameworks' started
Test Suite 'DylibHostedTests' started
Test Case '-[DylibTests.DylibHostedTests testFromDylib]' passed
```

The subclass is discovered and run, appearing as its own suite alongside the
bundle's own tests.

Static enumeration sees it too. `xcodebuild -enumerate-tests`, the interface
used to list tests without running them, reports:

```json
{ "kind": "class", "name": "DylibHostedTests",
  "children": [ { "kind": "test", "name": "testFromDylib()" } ] }
```

**One caveat, untested.** Both checks above go through the same runtime path:
enumeration launches the test host and asks the loaded images what tests
exist. Xcode's own test navigator is populated differently — from the source
index (IndexStoreDB) built from the project's targets — so a class in a
framework target may or may not get the same in-editor affordances (the run
diamonds, per-test re-run) even though `xcodebuild` and CI enumerate and run
it correctly. That link has not been verified here, because it requires a real
Xcode project and the GUI rather than a scripted fixture. Anyone adopting this
at scale should confirm it in their own project before moving test classes;
moving the tests' *dependencies* carries no such uncertainty, is where nearly
all the bytes are, and is the safer first step.

In practice most of the weight in a large `.xctest` is statically linked app
modules and third-party dependencies rather than the test classes, so moving
those alone captures most of the saving.

## 10. What a fix would look like

In rough order of impact and ease:

1. **Read only the header and load commands** rather than the whole file. The
   platform and architecture data the callers want is at the start of the
   file; this removes the term rather than shrinking it.
2. **Cache the answer per path.** One validation currently performs four full
   reads of the same file (section 5), so even without changing how the file
   is read, memoising the result cuts the cost roughly fourfold.
3. **Pass `NSDataReadingMappedIfSafe`** so the pages are file-backed, clean and
   evictable instead of anonymous, dirty and swappable. This does not reduce
   how much is read, but it removes the swap pressure, which is the part users
   actually feel.
4. **Return large transient buffers to the OS** rather than leaving dirty pages
   in empty `MALLOC_LARGE` regions — roughly 3 of 5 GB at peak.

Options 1 and 2 attack the waste; 3 and 4 mitigate its consequences. Any of
them materially reduces the peak.

Option 3 is close to a single constant. In `DVTFoundation`'s shared
`dataWithContentsOfFile` helper the options argument is a hardcoded zero
(verified against the bytes on disk in
[`evidence/disassembly.txt`](evidence/disassembly.txt)):

```
mov  x3, #0x0                                              ; options = 0
bl   "_objc_msgSend$initWithContentsOfFile:options:error:"
```

`NSDataReadingMappedIfSafe` is `1 << 3`. Note, however, that this helper is not
the only path: stack [3] in section 5 calls
`+[NSData dataWithContentsOfFile:options:error:]` directly from
`supportsRunningExecutableAtPath:`, so the helper alone accounts for three of
the four copies. A complete fix needs every call site, which is an argument for
options 1 and 2 over 3. (This is an observation about the
shipped code, offered to make the report actionable; patching a local Xcode
is not a supported workaround, see below.)

## 11. Why local patching is not a workaround

For completeness, since it is a natural question: modifying `xcodebuild`'s
behaviour on a stock macOS install is blocked twice over.

- `xcodebuild` is signed with `flags=0x2000 (library-validation)`, so
  `DYLD_INSERT_LIBRARIES` is ignored and no self-signed dylib can be loaded
  into it for swizzling. Clearing that would mean re-signing `xcodebuild`
  itself ad hoc, discarding its Apple identity.
- macOS App Management (TCC) prevents modifying files inside an application
  bundle. `touch`, `cp` and `codesign` inside `Xcode.app` all fail with
  `Operation not permitted` even for a copy the user expanded themselves,
  unless the terminal is granted App Management in
  System Settings > Privacy & Security, or SIP is disabled.

A patched Xcode would also break the signature chain, revert on every update,
and leave an ad-hoc `xcodebuild` whose other behaviour is unverified. The
dynamic-framework mitigation in section 9 achieves the same result with none
of that, and is the recommended path.

## 12. Method and environment

All measurements: Apple M4 Max, 48 GB, macOS 26.2 (25C56). Toolchains
Xcode 26.2 (17C52), 16.4 (16F6), 16.1 (16B40); simulator runtimes iOS 26.2
(23C54) and iOS 18.6 (22G86).

The fixture is deliberately minimal and built without an Xcode project: a
UIKit app and an app-hosted XCTest bundle compiled with `swiftc`, plus a
hand-written `.xctestrun`. Size is varied by linking an inert `__TEXT`
section (`-sectcreate`) into a chosen binary, so between two cases only the
file's size differs — no extra code, symbols, relocations or resources, and
nothing the test reads or executes.

Each case runs `xcodebuild test-without-building` against an already-booted
simulator with everything prebuilt, so the measurement covers the test session
only and not compilation. `scripts/measure_rss.py` samples every 0.25 s via
`ps`, tracking the process tree plus session helpers spawned outside it, and
separately reports processes the run created that fall outside the tracked
set, so simulator-side processes cannot go unnoticed. Reported figures are
peak aggregate RSS.

Caveats worth stating plainly:

- Single machine and single OS build. Absolute megabytes will differ
  elsewhere; the multipliers are the portable result.
- Peak RSS is a coarse instrument. It is corroborated here by `footprint`,
  `vmmap`, `heap` and system-wide `vm_stat`, which agree.
- Xcode 16.2 and 16.3 were not measured, so the regression window is
  16.2...16.4 rather than a single release.
- Xcode's test navigator UI was not tested; see the caveat in section 9.
- The disassembly is of shipped Apple code and is offered as evidence for the
  report, not as a supported interface.

## 13. Reproducing

```sh
scripts/08_matrix.sh                     # the cost model
scripts/10_experiment_dylib.sh           # which binaries are charged
scripts/11_experiment_discovery.sh       # dylib-hosted test discovery
STACK_LOGGING=1 PAD=256 PAD_TARGET=test scripts/09_memory_map.sh   # attribution
DEVELOPER_DIR=/Applications/Xcode_16.1.app scripts/06_bisect_version.sh
```

Artifacts land in `results/`: per-case logs and RSS timelines, `matrix.csv`,
`bisect.csv`, and a `memmap-*/` directory per attribution run containing
`footprint`, `vmmap`, `heap`, `malloc_history` and `vm_stat` deltas.
