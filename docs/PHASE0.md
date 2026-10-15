# Phase 0 — results log

Hardware: Apple Silicon Mac, macOS 15.4.1, Swift 6.1.2 (Command Line Tools only), Rust 1.90.
Fixture: 100,000 entries in one folder (99,800 small files + 200 folders), generated with
`cargo run --release --example list_bench -- gen <dir> 100000`.

## S0 — build without Xcode ✅ PASS (2026-10-10)
- `scripts/build.sh` builds the Rust core → UniFFI Swift bindings → SwiftPM → `Filofinder.app`, codesigns it (ad-hoc for now) and verifies the signature. One command.
- The binary is 0.7 MB, and the Rust core is linked statically.
- Still open: whether XCTest or Swift Testing runs with the Command Line Tools only. XCTest.framework isn't installed, so this needs checking.

## S1 — listing speed + list view (partial)

### Core benchmark (`list_bench run`, warm cache, median of 7)

| Backend | List | Sort | Total |
|---|---|---|---|
| readdir + lstat | 238 ms | 32 ms | 270 ms |
| **getattrlistbulk** | **85 ms** | 31 ms | **125 ms** |

- **getattrlistbulk** is 2.8× faster at listing, which matches the research.
- **Sorting** started at 152 ms because the comparison allocated memory on every call. Removing the allocations and adding an ASCII fast path brought it to 31 ms.
- **Correctness:** both backends return identical names, kinds, sizes, dates and file IDs (`backends_agree` test).

### In-app (`FILOFINDER_BENCH=5`, request → rows laid out)

| Folder | On screen | Target |
|---|---|---|
| 13 items | 1.5 ms | — |
| 24 items | 4 ms | 1k items < 30 ms ✅ |
| 100k items | 126 ms | first rows < 100 ms ❌ (close) |
| First paint after launch (small folder) | ~190 ms | < 300 ms ✅ |

- **Memory:** 36 MB with the 100k folder loaded (`footprint`). Target < 60 MB ✅.
- **Open issue:** the first listing of the 100k folder in a new process takes about 470 ms; repeat listings take about 90 ms. Cause unknown so far: the macOS cache, CPU warm-up after launch, or QoS.

### Next for S1
- **Stream the listing:** send the first screen of rows before the full sort and list finish. This should bring the 100k first paint under 100 ms. Alternatively, a parallel sort.
- **Scroll smoothness:** this needs a person scrolling. Open the 100k folder, turn on the frame monitor (⌥⌘F), and fling-scroll. The pass condition is no dropped frames at 120 Hz.
- **Investigate** the slow first listing.
