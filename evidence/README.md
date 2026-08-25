# evidence/

Raw captures from real runs, committed so the analysis can be checked without
reproducing anything first. Every file records the machine, the Xcode build,
and the command that produced it in its header.

Regenerate with `scripts/collect_evidence.sh` after running the experiments,
or `scripts/run_all.sh` to do both.

## The claim, and the file that supports it

| Claim | Evidence |
|---|---|
| Peak RSS is linear and additive in both binary sizes | `matrix.csv` |
| The multiplier regressed from 7x to 9x/10x across Xcode versions | `bisect.csv` |
| The memory is dirty, private and unreclaimable | `memmap-*/footprint.txt`, `memmap-*/vmmap.summary.txt` |
| Anonymous rather than file-backed, hence swap | `memmap-*/vm_stat.delta.txt` |
| Four full-size copies are live simultaneously | `memmap-*/heap.excerpt.txt` |
| The allocations come from Mach-O header inspection | `memmap-*/malloc_history.large.txt` |
| Reading the whole file is unnecessary: 3.5 KB gives the same answer | `header_only.txt` |
| The read passes `options: 0` instead of a mapped read | `disassembly.txt` |
| Only xctestrun-named binaries are charged; dylibs cost nothing | `placement/*.measure.txt` |
| A dylib-hosted XCTestCase is still discovered and run | `discovery/test_run.txt` |

## Reading the captures

**`matrix.csv`** — one row per measured cell: padding requested, resulting
binary sizes on disk, and peak host RSS. `scripts/fit_matrix.py` fits
`peak = base + A*app + B*test` on the rows where only one binary is padded and
reports the error on every cell, so the cells padding *both* binaries are
predictions the fit never saw.

**`memmap-*/footprint.txt`** — the kernel's own accounting for the
`xcodebuild` process at plateau, broken down by category with dirty / clean /
reclaimable columns. `MALLOC_LARGE` dominates and is entirely dirty.

**`memmap-*/vmmap.summary.txt`** — per-region detail. The `MALLOC ZONE` table
distinguishes live large allocations from `MALLOC_LARGE (empty)`: regions
whose allocations were freed but whose dirty pages were never returned to
the OS.

**`memmap-*/heap.excerpt.txt`** — live block sizes. The leading
`525392KB[4]`-style entry is four simultaneous allocations of exactly the
padded binary's size. The class table below it shows what everything else is.

**`memmap-*/malloc_history.large.txt`** — every live allocation over 50 MB
with the innermost frames of its allocating stack. This is the file that
identifies the cause; the full capture is ~100 MB and is excerpted here.

**`header_only.txt`** — where the platform/architecture data actually sits in
each Mach-O, how many bytes are needed to reach it, the resulting read
amplification, and a check that the bounded prefix yields the same answer as
`otool -l` parsing the whole file.

**`disassembly.txt`** — the shipped `DVTFoundation` code, with the raw
instruction bytes at the options argument decoded and verified against the
file on disk. Read-only inspection; regenerate with
`scripts/12_disassemble_dvt.sh`.

**`placement/*.measure.txt`** — peak RSS and per-process breakdown for the
same padding placed in the app binary, the test bundle, and an embedded
dylib. The dylib case also shows `TEST EXECUTE SUCCEEDED`, confirming the
library really was loaded rather than skipped.

**`discovery/test_run.txt`** — the suites and test cases that actually ran
when the whole bundle was executed with no `-only-testing`, including the
dylib-hosted case.
