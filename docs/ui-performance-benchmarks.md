# UI performance benchmark results

These measurements compare the pre-optimization algorithms with the implementations on `agent/ui-quality-performance`. They are CPU microbenchmarks, not emulator frame traces. Each reported value is the median of per-process medians, with warm-up iterations before sampling.

## Environment and method

- Date: 2026-08-17
- Linux x86_64 container
- Node.js 22.16.0, five fresh processes
- OpenJDK 21.0.11 with Kotlin/JVM, seven fresh processes
- Generated libraries: 1,000, 10,000, and 50,000 tracks
- Search batches: six title, artist, album, path, broad-match, and no-match queries
- Correctness: every indexed result was checked against the previous search policy before timing

The raw aggregate data is in `benchmarks/results/ui-quality-performance-2026-08-17.json`.

## Android Library search

The final implementation builds one immutable folded-text index whenever the library snapshot changes, then reuses it for each keystroke.

| Tracks | Index build | Previous six-query batch | Indexed six-query batch | Speedup |
|---:|---:|---:|---:|---:|
| 1,000 | 0.740 ms | 0.681 ms | 0.128 ms | 5.34× |
| 10,000 | 2.530 ms | 5.843 ms | 0.957 ms | 6.10× |
| 50,000 | 7.392 ms | 28.910 ms | 6.133 ms | 4.71× |

At 10,000 tracks, the one-time index cost is recovered after roughly three search updates. At 50,000 tracks, it is recovered after roughly two. Blank searches still return the original list without allocation, and result ordering remains unchanged.

The first prototype retained one wrapper object per track. A second benchmark pass replaced those wrappers with a parallel string array. Retained heap overhead fell from about 0.92 MiB to 0.69 MiB at 10,000 tracks, and from 6.14 MiB to 5.00 MiB at 50,000 tracks. The branch uses the lower-memory version.

## Previously implemented list work

The repeatable renderer model also confirmed the direction of the earlier changes:

| Workload at 10,000 tracks | Previous median | Candidate median | Speedup |
|---|---:|---:|---:|
| Recently Added top six | 1.530 ms | 0.091 ms | 16.89× |
| Storage filter and sort batch | 10.233 ms | 1.586 ms | 6.45× |
| Row presentation work, all rows versus 24 visible rows | 1.268 ms | 0.003 ms | 388.88× |

The row number is a synthetic CPU-work proxy. It demonstrates the scaling difference between eager and viewport-bounded work, but it is not an Android frame-time or jank measurement.

## Decisions from the benchmark

1. Shipped the Android Library index because both Node and Kotlin/JVM measurements showed a consistent multi-fold improvement.
2. Refined the index after measuring retained heap, replacing per-track wrappers with a parallel array.
3. Kept keyed lazy Library and Storage rows and the bounded Recently Added selection.
4. Rejected a proposed Windows nested-mutation coalescer. It improved nested batches but regressed wide sibling batches, so it was not committed.

## Remaining runtime validation

A device-level Android Macrobenchmark should still measure first-open time, search keystroke latency, recomposition counts, scrolling jank, and peak memory on representative phones. The microbenchmarks isolate the algorithms and establish that the committed search path is faster, but they do not substitute for end-to-end rendering traces.
