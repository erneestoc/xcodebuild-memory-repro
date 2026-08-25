# Where the memory goes

This document records what `xcodebuild test-without-building` actually does
with host memory, measured rather than inferred. All figures are from an
Apple M4 Max, 48 GB, macOS 26.2 (25C56), Xcode 26.2 (17C52), reproduced by the
scripts in this repository.

## 1. The cost model

Sweeping the host app binary and the `.xctest` bundle binary independently and
together (`scripts/08_matrix.sh`) gives a strikingly simple result:

```
peak host RSS (MB) = 234 + 9.01 x (app binary MB) + 10.02 x (test bundle MB)
```

| app pad | test pad | measured peak | predicted | error | held out of fit |
|--------:|---------:|--------------:|----------:|------:|:---------------:|
|   0 MB  |   0 MB   |    237 MB     |   234 MB  |  +3   |                 |
| 128 MB  |   0 MB   |   1386 MB     |  1387 MB  |  -1   |                 |
| 256 MB  |   0 MB   |   2542 MB     |  2541 MB  |  +1   |                 |
| 512 MB  |   0 MB   |   4848 MB     |  4848 MB  |  -0   |                 |
|   0 MB  | 128 MB   |   1514 MB     |  1516 MB  |  -2   |                 |
|   0 MB  | 256 MB   |   2797 MB     |  2798 MB  |  -1   |                 |
|   0 MB  | 512 MB   |   5363 MB     |  5363 MB  |  +0   |                 |
|   0 MB  | 700 MB   |   7247 MB     |  7246 MB  |  +1   |                 |
| 256 MB  | 256 MB   |   5106 MB     |  5106 MB  |  +0   | **yes**         |
| 400 MB  | 700 MB   |  10852 MB     | 10851 MB  |  +1   | **yes**         |

The coefficients were fitted only on rows where a single binary was padded.
The two mixed rows were held out and are still predicted to within 1 MB, so
the two costs are genuinely independent and additive. The relationship stays
linear all the way to 700 MB — it does not taper off at realistic sizes.

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
block. With a 256 MB test bundle, the four live 257 MB allocations come from
these call sites:

```
DVTMachOPlatformsForExecutable
  -> dataWithContentsOfFile
     -> -[NSData initWithContentsOfFile:options:maxLength:error:]
        -> NSData._readBytes(fromPath:maxLength:bytes:length:didMap:...)
           -> _malloc_zone_malloc_instrumented_or_legacy       [257 MB]

DVTPlatformFamilyForMachO
  -> dataWithContentsOfFile
     -> ... same path ...                                      [257 MB]

-[DVTDevice(IDEFoundationAdditions)
    supportsRunningExecutableAtPath:usingArchitecture:error:]
  -> +[NSData dataWithContentsOfFile:options:error:]
     -> ... same path ...                                      [257 MB]

DVTMachOPlatformsForExecutable  (second occurrence)             [257 MB]
```

Every one of these functions is asking the same narrow question: *which
platforms and architectures does this Mach-O support?* That answer lives in
the Mach-O header and load commands — the first few kilobytes of the file.

To obtain it, `DVTFoundation` calls `NSData dataWithContentsOfFile:` without
`NSDataReadingMappedIfSafe`, so Foundation allocates a private buffer the size
of the entire file and reads all of it. The `didMap:` parameter visible in the
Foundation frame is precisely the switch that would have made these pages
mapped, clean, and evictable; it is not requested.

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

Measured on one machine, same fixture, same simulator runtime for the two
16.x rows. Every figure was reproduced across independent runs agreeing to
within 1-2 MB. Xcode 16.2 and 16.3 have not been measured, so the step lands
somewhere in 16.2...16.4.

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
bundle's own tests. So it is not only the tests' dependencies that can move
out: test code itself can live in a dynamic library, as long as the library
is linked by the test bundle so dyld loads it with the bundle.

In practice most of the weight in a large `.xctest` is statically linked app
modules and third-party dependencies rather than the test classes, so moving
those alone captures most of the saving.

## 10. What a fix would look like

In rough order of impact and ease:

1. Read only the header and load commands, rather than the whole file.
2. Failing that, pass `NSDataReadingMappedIfSafe` so the pages are clean and
   evictable instead of dirty and swappable.
3. Cache the per-path result so independent call sites do not each re-read.
4. Release large transient buffers back to the OS rather than leaving dirty
   pages in empty malloc regions.

Any one of these would materially reduce the peak; the first would
effectively eliminate the term.

Option 2 is a single instruction. In `DVTFoundation`'s shared
`_dataWithContentsOfFile` helper, the options argument is a hardcoded zero:

```
mov  x3, #0x0                                              ; options = 0
bl   "_objc_msgSend$initWithContentsOfFile:options:error:"
```

`NSDataReadingMappedIfSafe` is `1 << 3`. Passing it would leave the logic
unchanged while making the pages file-backed, clean and evictable instead of
anonymous, dirty and swappable — which alone removes the swap pressure.
Because all three public entry points funnel through this one helper, fixing
it there fixes every call site at once. (This is an observation about the
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

## 12. Reproducing

```sh
scripts/08_matrix.sh                                   # the cost model
STACK_LOGGING=1 PAD=256 PAD_TARGET=test scripts/09_memory_map.sh   # attribution
DEVELOPER_DIR=/Applications/Xcode_16.1.app scripts/06_bisect_version.sh
```

Artifacts land in `results/`: per-case logs and RSS timelines, `matrix.csv`,
`bisect.csv`, and a `memmap-*/` directory per attribution run containing
`footprint`, `vmmap`, `heap`, `malloc_history` and `vm_stat` deltas.
