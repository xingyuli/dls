
# Week 1: Project Setup and Data Model Implementation

**Goals**: Establish the project foundation, define the data model, and implement basic log entry handling.

**Tasks**:

- ~~Set up Zig project structure (init build.zig, main.zig, modules for data model and SDK) – 2 hours.~~
- ~~Define `LogEntry` struct with fields like timestamp (u64), message ([]u8), level (enum), and version (u8); add comptime validation – 3 hours.~~
- ~~Implement basic JSON serialization/deserialization using `std.json` for LogEntry – 3 hours.~~
- ~~Write unit tests for LogEntry creation and serialization using `std.testing` – 2 hours.~~

**Deliverables**: Working Zig module for LogEntry with tests passing.

**Dependencies/Notes**: Ensure Zig is installed (latest version). Use `GeneralPurposeAllocator` for any dynamic allocations. This aligns with the Data Model section.

**Completed at**: 2025.08.23


# Week 2: Basic SDK for Writes and Reads

**Goals**: Build the imperative SDK for basic log operations.

**Tasks**:

- ~~Define SDK functions: `write_log(entry: LogEntry) -> Result<void, Error>` and `read_logs(start_ts: u64, end_ts: u64) -> []LogEntry` – 3 hours.~~
- ~~Implement in-memory storage using `std.ArrayList(LogEntry)` for initial writes/reads (no persistence yet) – 3 hours.~~
- ~~Add simple time-range filtering in `read_logs` via sequential scan – 2 hours.~~
- ~~Unit tests for SDK functions, including edge cases like empty ranges – 2 hours.~~

**Deliverables**: Functional SDK with in-memory operations and tests.

**Dependencies/Notes**: Builds on Week 1. Use allocators for dynamic arrays. This covers the Query Language section's imperative SDK.

**Viclau Bonus**:

`writeManyLogs` performance test result
- Run 1: Wrote 10,000 entries in 585ms (58.5 µs/entry), read in 1.2ms (0.12 µs/entry).
- Run 2: Wrote 10,000 entries in 582ms (58.2 µs/entry), read in 1.1ms (0.11 µs/entry).
- Write:read ratio (~500:1) indicates writes are slower due to `LogEntry.init` allocations (message, metadata JSON parsing). Consider batching or optimizing allocations in Week 4.

**Completed at**: 2025.08.27
