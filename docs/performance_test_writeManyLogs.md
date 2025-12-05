# Informal Performance Test: writeManyLogs

## Quick Glance Summary
| Version              | Scale | Write Latency | Read Latency |
|----------------------|-------|---------------|--------------|
| V8 (Optimized)       | 100k  | 75 µs         | 3.35 µs      |
| V8 (Initial CBOR)    | 100k  | 460 µs        | 4.5 µs       |
| V7 (Compaction)      | 100K  | 266 µs        | 12.2 µs      |
| V6 (Zig 0.15.1)      | 100k  | 125 µs        | 12.1 µs      |
| V5 (Arena)           | 100k  | 122 µs        | 29 µs        |
| V4 (Flush)           | 100k  | 241 µs        | 188 µs       |
| V3 (1KB Msg)         | 100k  | 178 µs        | 0.1 µs       |
| V2 (WAL)             | 10k   | 115 µs        | 0.11 µs      |
| V1 (Memory)          | 10k   | 58 µs         | 0.11 µs      |

## Overview
The `writeManyLogs` test in `memtable.zig` evaluates the performance of the Zig Log Store's write and read operations for a single-node LSM-Tree implementation. The test measures the time to write and read large numbers of log entries, with and without persistence and flushing, to assess the efficiency of memory management and storage mechanisms. V1 and V2 provide valuable baselines for single-threaded performance, representing the minimum achievable times for in-memory and WAL-persisted operations, respectively.

## Test Setup
- **Test Name**: `writeManyLogs`.
- **Purpose**: Measure write and read latency for 10k and 100k log entries.
- **Configuration**:
  - `MemTable` with `flush_threshold=1,000` (V4–V7) or no flush (V1–V3).
  - `max_log_entry_write_size=1MB`, `max_log_entry_recover_size=10MB`.
  - Entries: `LogEntry` with `message` size ranging from small to ~1KB (V3–V7), optional `metadata` (JSON object), and server-generated timestamps (u64, milliseconds).
  - WAL: Append-only with `fsync` for durability (V2–V7).
  - SSTables: Binary format (`[u64 timestamp][u32 length][JSON entry]`), created during flush (V4–V7, ~100 SSTables for 100k entries).
- **Versions**:
  - **V1**: Pure in-memory `ArrayList` operations.
  - **V2**: V1 + WAL persistence.
  - **V3**: V2 + 1KB message sizes.
  - **V4**: V3 + memtable flushing to SSTables (`flush_threshold=1,000`).
  - **V5**: V4 with arena-based memory management and optimized allocations.
  - **V6**: V5 with upgrade to Zig 0.15.1.
  - **V7**: V6 + SSTable compaction (merge on threshold).
  - **V8(Initial)**: V7 + CBOR persistence (replacing JSON).
  - **V8(Optimized)**: V8(Initial) + optimized CBOR encoding/decoding.
- **Hardware Assumptions**: Standard development machine (e.g., 4-core CPU, SSD, 16GB RAM), Zig 0.15.1 for V6-V7, Zig 0.14.1 for V1–V5.
- **Test Flow**:
  - Write `N` entries using `MemTable.writeLog`, appending to WAL (V2–V7) and inserting into sorted memtable.
  - Flush to SSTables every `flush_threshold=1,000` entries (V4–V7).
  - Read all entries using `MemTable.readLogs` with a broad timestamp range (0 to max u64).
  - Measure total time, compute per-entry latency (µs), and calculate write:read ratio.

## Results

### V8 (Optimized)
| Scale | Write Time | Write Latency | Read Time | Read Latency | Write:Read Ratio |
|-------|------------|---------------|-----------|--------------|------------------|
| 100k  | 7.48 s     | 74.76 µs      | 0.34 s    | 3.35 µs      | 22.30            |

**Detailed Metrics**:
- **MemTable**:
  - Flush time: 23,068 µs per flush
  - Flush count: 100
- **WAL**:
  - CBOR encode time: 3 µs per entry
  - Write time: 20 µs per entry
- **LogEntry**:
  - Push time: 2 µs per entry (300,100 operations)
  - Finish time: 0 µs per entry (300,100 operations)

- **Observations**:
  - Write latency: ~75 µs → ~6.1x faster than V8 Initial (~460 µs), ~3.5x slower than V7 (~266 µs).
    - CBOR encoding optimized to just 3 µs per entry.
    - WAL write overhead is 20 µs per entry, dominating the write path.
  - Read latency: ~3.35 µs → ~1.3x faster than V8 Initial (~4.5 µs), ~3.6x faster than V7 (~12.2 µs).
    - Binary CBOR deserialization continues to outperform JSON.
  - Write:Read ratio: ~22.3 → Within the 10:1–100:1 target range.
  - **Key improvement**: Optimizations reduced write latency by 84% compared to V8 Initial.

### V8 (Initial CBOR persistency)
| Scale | Write Time | Write Latency | Read Time | Read Latency | Write:Read Ratio |
|-------|------------|---------------|-----------|--------------|------------------|
| 100k  | 45.50 s    | 455 µs        | 0.46 s    | 4.57 µs      | 99.64            |
| 100k  | 46.48 s    | 465 µs        | 0.45 s    | 4.46 µs      | 104.34           |
| 100k  | 45.98 s    | 460 µs        | 0.44 s    | 4.39 µs      | 104.64           |

- **Observations**:
  - Write latency: ~460 µs → ~1.7x slower than V7 (~266 µs).
    - Likely due to unoptimized CBOR serialization or overhead in the initial implementation.
  - Read latency: ~4.5 µs → ~2.7x faster than V7 (~12.2 µs).
    - Binary format (CBOR) significantly outperforms JSON parsing.
  - Write:Read ratio: ~103 → Excellent, hitting the upper bound of the 10:1–100:1 target.

### V7 (Week 6: SSTable Compaction)
| Scale | Write Time | Write Latency | Read Time | Read Latency | Write:Read Ratio |
|-------|------------|---------------|-----------|--------------|------------------|
| 100k  | 26.61 s    | 266 µs        | 1.22 s    | 12.2 µs      | 21.72            |

- **Observations**:
  - Write latency: 266 µs → ~2.1x slower than V6 (~129 µs).
    - Expected: Compaction runs in foreground during write path.
    - ~100 flushes → ~25 compactions → each merges ~4 SSTables (sort + write).
  - Read latency: 12.2 µs → identical to V6.
    - ~75% fewer SSTables (~25 vs ~100) → but no speedup.
    - Reason: `readLog()` still **scans every SSTable** → no indexing.
  - Write:Read ratio: 21.72 → better than V6, exceeds 10:1–100:1 target.
  - File count: ~25 SSTables vs ~100 → 75% reduction.

### V6 (Upgrade to Zig 0.15.1)
| Scale | Write Time | Write Latency | Read Time | Read Latency | Write:Read Ratio |
|-------|------------|---------------|-----------|--------------|------------------|
| 100k  | 12.95 s    | 129 µs        | 1.24 s    | 12.4 µs      | 10.47            |
| 100k  | 12.26 s    | 122 µs        | 1.20 s    | 12.0 µs      | 10.23            |
| 100k  | 12.33 s    | 123 µs        | 1.20 s    | 12.0 µs      | 10.30            |

- **Observations**:
  - Writes (~122–129 µs) are comparable to V5 (~114–122 µs), with a ~3–9% regression, possibly due to allocator or I/O changes in Zig 0.15.1.
  - Reads (~12.0–12.4 µs) are ~2.4x faster than V5 (~29–30 µs), likely due to optimized JSON parsing or file I/O in Zig 0.15.1.
  - Write:read ratio (~10.23–10.47) hits the lower end of the 10:1–100:1 target, driven by faster reads.

### V5 (Efficient Memory Management with Arena)
| Scale | Write Time | Write Latency | Read Time | Read Latency | Write:Read Ratio |
|-------|------------|---------------|-----------|--------------|------------------|
| 100k  | 12.2 s     | 122 µs        | 2.9 s     | 29 µs        | 4.26             |
| 100k  | 11.4 s     | 114 µs        | 3.0 s     | 30 µs        | 3.83             |

- **Observations**:
  - Writes are ~2x faster than V4 (~114–122 µs vs. 241 µs), due to arena-based allocation.
  - Reads are ~6x faster than V4 (~29–30 µs vs. 188 µs), due to reduced parsing.
  - Write:read ratio (~4:1) nears the target 10:1–100:1, but read times (2.9–3.0 s) remain high.

### V4 (V3 + Flush)
| Scale | Write Time | Write Latency | Read Time | Read Latency | Write:Read Ratio |
|-------|------------|---------------|-----------|--------------|------------------|
| 10k   | 2.50 s     | 250 µs        | 1.48 s    | 148 µs       | 1.70             |
| 100k  | 24.1 s     | 241 µs        | 18.8 s    | 188 µs       | 1.28             |

- **Observations**:
  - Writes are ~1.4x slower than V3 due to SSTable flushes (`f.writeAll`, `f.sync`) every 1,000 entries.
  - Reads are significantly slower (1,000x vs. V3 at 100k) due to sequential disk access across ~100 SSTables.

### V3 (V2 + 1KB Message per Entry)
| Scale | Write Time | Write Latency | Read Time | Read Latency | Write:Read Ratio |
|-------|------------|---------------|-----------|--------------|------------------|
| 10k   | 1,381 ms   | 138 µs        | 1.1 ms    | 0.11 µs      | 1,300            |
| 10k   | 1,379 ms   | 138 µs        | 1.1 ms    | 0.11 µs      | 1,300            |
| 10k   | 1,389 ms   | 139 µs        | 1.1 ms    | 0.11 µs      | 1,300            |
| 100k  | 17.4 s     | 174 µs        | 12 ms     | 0.12 µs      | 1,600            |
| 100k  | 17.8 s     | 178 µs        | 9.8 ms    | 0.10 µs      | 1,600            |

- **Observations**:
  - Larger message sizes (small to 1KB) increase write time (~138–178 µs vs. 115 µs in V2).
  - Reads remain fast due to in-memory `ArrayList` scans.

### V2 (V1 + WAL Persistence)
| Scale | Write Time | Write Latency | Read Time | Read Latency | Write:Read Ratio |
|-------|------------|---------------|-----------|--------------|------------------|
| 10k   | 1,151 ms   | 115 µs        | 1.1 ms    | 0.11 µs      | 1,000            |
| 10k   | 1,155 ms   | 115 µs        | 1.1 ms    | 0.11 µs      | 1,000            |
| 10k   | 1,159 ms   | 116 µs        | 1.1 ms    | 0.11 µs      | 1,000            |

- **Observations**:
  - WAL persistence (`fsync`) doubles write latency compared to V1 (~115 µs vs. 58 µs).
  - Reads remain fast, as operations are in-memory.

### V1 (Pure Memory Manipulations against ArrayList)
| Scale | Write Time | Write Latency | Read Time | Read Latency | Write:Read Ratio |
|-------|------------|---------------|-----------|--------------|------------------|
| 10k   | 585 ms     | 58 µs         | 1.2 ms    | 0.12 µs      | 500              |
| 10k   | 582 ms     | 58 µs         | 1.1 ms    | 0.11 µs      | 500              |

- **Observations**:
  - Fastest writes due to in-memory `ArrayList` operations, representing the single-threaded baseline.
  - Writes slowed by `LogEntry.init` allocations (message, metadata JSON parsing).
  - Reads are fast with in-memory scans.

## Analysis
- **General Progression**:
  - **Writes**: V1 (~58 µs) → V2 (~115 µs) → V3 (~138–178 µs) → V4 (~241–250 µs) → V5 (~114–122 µs) → V6 (~122–129 µs) → V7 (~266 µs) → V8 Initial (~460 µs) → V8 Optimized (~75 µs). V8 Initial regression resolved through optimization.
  - **Reads**: V1–V3 (~0.11–0.12 µs) → V4 (~148–188 µs) → V5 (~29–30 µs) → V6 (~12.0–12.4 µs) → V7 (~12.2 µs) → V8 Initial (~4.5 µs) → V8 Optimized (~3.35 µs). CBOR provides significant speedup.
  - **Weakness**: Foreground compaction blocks writes; consider background threads (Week 7).

- **Write Performance**:
  - **Progression**: V1 (~58 µs, in-memory baseline) → V2 (~115 µs, WAL) → V3 (~138–178 µs, 1KB messages) → V4 (~241–250 µs, flush) → V5 (~114–122 µs, arena) → V6 (~122–129 µs) → V7 (~266 µs) → V8 Initial (~460 µs) → V8 Optimized (~75 µs).
  - **V8 Optimized breakdown**: CBOR encoding (3 µs) + WAL write (20 µs) + LogEntry operations (2 µs) + flush overhead (~23 ms per 1,000 entries).
  - **Weakness**: WAL `fsync` overhead (20 µs per entry) remains the dominant cost. Compaction adds sort/write overhead.

- **Read Performance**:
  - **Progression**: V1–V3 (~0.11–0.12 µs, in-memory baseline) → V4 (~148–188 µs, ~100 SSTables) → V5 (~29–30 µs) → V6 (~12.0–12.4 µs) → V7 (~12.2 µs) → V8 Initial (~4.5 µs) → V8 Optimized (~3.35 µs).
  - **Baseline**: V1's ~0.11 µs/read is the single-threaded minimum, unachievable with persistence.
  - **V8 Optimized**: Total read time of 0.34 s for 100k entries shows excellent performance with CBOR deserialization.
  - **Weakness**: Sequential SSTable access remains a bottleneck, requiring sparse indexing.

- **Write:Read Ratio**:
  - V1 (~500:1) → V2 (~1,000:1) → V3 (~1,300–1,600:1) → V4 (~1.28–1.70:1) → V5 (~3.83–4.26:1) → V6 (~10.23–10.47) → V7 (~21.72) → V8 Initial (~103) → V8 Optimized (~22.3). V8 Optimized maintains excellent balance within target range.

- **V7 Optimizations**:
  - Tiered compaction reduces file count (~25 vs ~100). Write slowdown (~110%) due to foreground merges; consider background compaction. Read stable, ready for indexing.

## Next Steps
- **Read Optimization (Week 8)**:
  - Implement sparse indexing (e.g., min/max timestamps per SSTable in a header) to skip irrelevant files, targeting <100 ms read latency for 100k entries.
  - Temporary hack: Limit scanned SSTables (e.g., last 10) for recent logs.

- **Write Optimization (Week 6)**:
  - Batch WAL appends (e.g., write 10 entries, then `fsync`) to target <100 µs/write, addressing V7’s compaction overhead.
  - Explore binary metadata format (e.g., CBOR, as discussed previously) to reduce `LogEntry.ser/deser` overhead.

- **WAL Management (Week 6)**:
  - Implement checkpointing (e.g., `{"checkpoint": {"sst_file": "sst_0001.bin"}}` in WAL) to enable safe truncation, addressing unbounded WAL growth (~100 MB for 100k 1KB entries).

- **Additional Tests**:
  - Measure peak memory usage in `writeManyLogs` using `GeneralPurposeAllocator` with `.report_leaks = true` (expect ~10–20 MB per flush cycle).
  - Add crash-recovery test mid-flush (e.g., kill after `f.writeAll` but before `f.sync`) to validate WAL recovery.
  - Test specific timestamp ranges (e.g., last 1,000 entries) to assess read performance for typical queries.

## Conclusion
The `writeManyLogs` test continues to evolve, with V8 introducing and optimizing CBOR persistence. V8 (Optimized) achieves ~75 µs/write and ~3.35 µs/read at 100k entries. Compared to V8 Initial (~460 µs/write), the optimized version is 6.1x faster on writes through improved CBOR encoding (3 µs per entry). Reads improved by 1.3x (~3.35 µs vs ~4.5 µs). The write:read ratio of ~22.3 sits comfortably within the 10:1–100:1 target range. The main bottleneck is now WAL write overhead (20 µs per entry), suggesting batched WAL writes as the next optimization opportunity.

**Tested on**: December 6, 2025
