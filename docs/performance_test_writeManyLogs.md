# Informal Performance Test: writeManyLogs

**Tested on**: 2025-10-05

## Quick Glance Summary
| Version       | Scale | Write Latency | Read Latency |
|---------------|-------|---------------|--------------|
| V5 (Arena)    | 100k  | 122 µs        | 29 µs        |
| V4 (Flush)    | 100k  | 241 µs        | 188 µs       |
| V3 (1KB Msg)  | 100k  | 178 µs        | 0.1 µs       |
| V2 (WAL)      | 10k   | 115 µs        | 0.11 µs      |
| V1 (Memory)   | 10k   | 58 µs         | 0.11 µs      |

## Overview
The `writeManyLogs` test in `memtable.zig` evaluates the performance of the Zig Log Store's write and read operations for a single-node LSM-Tree implementation. The test measures the time to write and read large numbers of log entries, with and without persistence and flushing, to assess the efficiency of memory management and storage mechanisms. V1 and V2 provide valuable baselines for single-threaded performance, representing the minimum achievable times for in-memory and WAL-persisted operations, respectively.

## Test Setup
- **Test Name**: `writeManyLogs` (commented out in `memtable.zig`).
- **Purpose**: Measure write and read latency for 10k and 100k log entries.
- **Configuration**:
  - `MemTable` with `flush_threshold=1,000` (V4–V5) or no flush (V1–V3).
  - `max_log_entry_write_size=1MB`, `max_log_entry_recover_size=10MB`.
  - Entries: `LogEntry` with `message` size ranging from small to ~1KB (V3–V5), optional `metadata` (JSON object), and server-generated timestamps (u64, milliseconds).
  - WAL: Append-only with `fsync` for durability (V2–V5).
  - SSTables: Binary format (`[u64 timestamp][u32 length][JSON entry]`), created during flush (V4–V5, ~100 SSTables for 100k entries).
- **Versions**:
  - **V1**: Pure in-memory `ArrayList` operations.
  - **V2**: V1 + WAL persistence.
  - **V3**: V2 + 1KB message sizes.
  - **V4**: V3 + memtable flushing to SSTables (`flush_threshold=1,000`).
  - **V5**: V4 with arena-based memory management and optimized allocations.
- **Hardware Assumptions**: Standard development machine (e.g., 4-core CPU, SSD, 16GB RAM), Zig 0.14.0, tested on 2025-10-05.
- **Test Flow**:
  - Write `N` entries using `MemTable.writeLog`, appending to WAL (V2–V5) and inserting into sorted memtable.
  - Flush to SSTables every `flush_threshold=1,000` entries (V4–V5).
  - Read all entries using `MemTable.readLogs` with a broad timestamp range (0 to max u64).
  - Measure total time, compute per-entry latency (µs), and calculate write:read ratio.

## Results
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
- **Arena-Based Memory Management (V5)**:
  - **Success**: V5’s arena allocator (`self.arena` in `MemTable`) with `flush_threshold=1,000` reduces allocation overhead, achieving ~114–122 µs/write and ~29–30 µs/read at 100k entries. The arena reset (`arena.reset(.free_all)`) bounds memory usage (~10–20 MB peak for 1,000 entries at 1KB each).
  - **Lifecycle Alignment**: `LogEntry` lifetimes align with the write-flush cycle, preventing leaks and simplifying caller code (e.g., `Server`).
  - **Evidence**: No OOM errors at 100k entries, with ~2x write and ~6x read improvements over V4.

- **Write Performance**:
  - **Progression**: V1 (~58 µs, in-memory baseline) → V2 (~115 µs, WAL) → V3 (~138–178 µs, 1KB messages) → V4 (~241–250 µs, flush) → V5 (~114–122 µs, arena). V5’s write latency approaches V2, despite flushing, due to optimized allocations.
  - **Weakness**: JSON serialization (`LogEntry.ser`) and WAL `fsync` remain costly, though V5 mitigates this.

- **Read Performance**:
  - **Progression**: V1–V3 (~0.11–0.12 µs, in-memory baseline) → V4 (~148–188 µs, ~100 SSTables) → V5 (~29–30 µs, ~100 SSTables). V5’s ~6x read improvement over V4 due to optimized parsing, but sequential SSTable access is a bottleneck (2.9–3.0 s for 100k).
  - **Baseline**: V1’s ~0.11 µs/read represents the single-threaded minimum, unachievable with persistence.

- **Write:Read Ratio**:
  - V1 (~500:1) → V2 (~1,000:1) → V3 (~1,300–1,600:1) → V4 (~1.28–1.70:1) → V5 (~3.83–4.26:1). V5’s ratio is a step toward the 10:1–100:1 target, but absolute read times are too high.

- **V5 Optimizations**:
  - The ~2x write and ~6x read improvements highlight arena efficiency and reduced overhead.

## Next Steps
- **Read Optimization (Week 8)**:
  - Implement sparse indexing (e.g., min/max timestamps per SSTable in a header) to skip irrelevant files, targeting <100 ms read latency for 100k entries.
  - Temporary hack: Limit scanned SSTables (e.g., last 10) for recent logs.

- **Write Optimization (Week 6)**:
  - If not in V5, batch WAL appends (e.g., write 10 entries, then `fsync`) to target <100 µs/write.
  - Explore binary metadata format (e.g., CBOR) to reduce `LogEntry.ser/deser` overhead.

- **WAL Management (Week 6)**:
  - Implement checkpointing (e.g., `{"checkpoint": {"sst_file": "sst_0001.bin"}}` in WAL) to enable safe truncation, addressing unbounded WAL growth (~100 MB for 100k 1KB entries).

- **Additional Tests**:
  - Measure peak memory usage in `writeManyLogs` using `GeneralPurposeAllocator` with `.report_leaks = true` (expect ~10–20 MB per flush cycle in V5).
  - Add crash-recovery test mid-flush (e.g., kill after `f.writeAll` but before `f.sync`) to validate WAL recovery.
  - Test specific timestamp ranges (e.g., last 1,000 entries) to assess read performance for typical queries.

## Conclusion

- The `writeManyLogs` test shows significant progress, with V5’s arena-based memory management achieving ~114–122 µs/write and ~29–30 µs/read at 100k entries, a ~2x write and ~6x read improvement over V4.
- V1 (~58 µs/write, ~0.11 µs/read at 10k) and V2 (~115 µs/write, ~0.11 µs/read at 10k) provide critical single-threaded baselines, highlighting the overhead of persistence and flushing.
- V5's ~4:1 write:read ratio nears the 10:1–100:1 target, but read performance (2.9–3.0 s) requires sparse indexing (Week 8). These results guide Week 6 optimizations (timestamp support, WAL checkpointing).
