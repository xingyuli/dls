
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
