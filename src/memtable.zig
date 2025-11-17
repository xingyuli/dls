// Copyright (c) 2025 Vic Lau
// Licensed under the MIT License

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const LogEntry = @import("./model.zig").LogEntry;
const Wal = @import("./wal.zig").Wal;

const Config = struct {
    /// The upper size limit in bytes of each log entry when write. Default to 1M. This is an estimated size.
    max_log_entry_write_size: u32 = 1024 * 1024,

    /// The upper size limit in bytes of each log entry when recover from WAL. Default to 10M.
    /// Recover size is intended to be larger than `max_log_entry_write_size` to allow fine-tune
    /// `max_log_entry_write_size`. But in general it is suggested to keep as a fixed value for all instances of
    /// MemTable. That is to say, `max_log_entry_write_size` should be set to a value smaller than recovery size.
    max_log_entry_recover_size: u32 = 1024 * 1024 * 10,

    /// Threshold for memtable flushing (number of entries). Default to 100 as a reasonable starting point to balance
    /// memory usage and I/O overhead.
    flush_threshold: u32 = 100,

    max_sstables_before_compact: usize = 4,
};

const MemTableError = error{
    LogEntryTooLarge,
    DiskFull,
    OutOfMemory,
    FileSystemError,
};

// TODO sstable filenames are lost when server restarts
pub const MemTable = struct {
    gpa: Allocator,

    arena: *ArenaAllocator,
    entry_allocator: Allocator,
    entries: std.ArrayList(LogEntry),

    // for single-node design: one MemTable owns one Wal
    wal: Wal,
    config: Config,

    // Track SSTable filenames, with tiered compaction
    sstable_files: std.ArrayList([]u8), // Level 0: recent flushes
    compacted_files: std.ArrayList([]u8), // Level 1: merged

    const CheckpointEntry = LogEntry{
        .timestamp = 0,
        .source_ts = 0,
        .message = "MARKER:CHECKPOINT",
        .version = 1,
    };

    /// Initializes a MemTable and recovers log entries from the specified WAL file.
    /// The caller owns the returned MemTable, deinitialize with `deinit`.
    pub fn init(gpa: Allocator, wal_filename: []const u8, config: Config) !MemTable {
        const arena = try gpa.create(ArenaAllocator);
        errdefer gpa.destroy(arena);

        arena.* = ArenaAllocator.init(gpa);
        errdefer arena.deinit();

        var self = MemTable{
            .gpa = gpa,

            .arena = arena,
            .entry_allocator = arena.allocator(),
            .entries = .empty,

            .wal = try Wal.init(wal_filename),
            .config = config,

            .sstable_files = .empty,
            .compacted_files = .empty,
        };
        try recover(&self, wal_filename);
        return self;
    }

    /// Deinitializes the MemTable, freeing all associated resources.
    pub fn deinit(self: *MemTable) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);

        self.wal.deinit();

        for (self.sstable_files.items) |filename| {
            self.gpa.free(filename);
        }
        self.sstable_files.deinit(self.gpa);

        for (self.compacted_files.items) |filename| {
            self.gpa.free(filename);
        }
        self.compacted_files.deinit(self.gpa);
    }

    /// Finds the insertion index for a new entry to maintain sorted order by timestamp.
    fn findInsertIndex(self: *const MemTable, timestamp: u64) usize {
        for (self.entries.items, 0..) |entry, i| {
            if (entry.timestamp > timestamp) {
                return i;
            }
        }
        return self.entries.items.len;
    }

    /// Appends a log entry to the MemTable and persists it to the WAL.
    /// The `entry` must be allocated using `self.entries.allocator()` (i.e., `self.arena.allocator()`),
    /// typically via `LogEntry.init(self.arena.allocator(), ...)`, as the arena manages entry lifetimes
    /// and is reset on `flush`, freeing all entries to prevent dangling pointers.
    pub fn writeLog(self: *MemTable, entry: LogEntry) !void {
        // TODO future: handle outdated timestamp values in MemTable entries, possible solutions are:
        //   1. discard if `current_timestamp - entry.timestamp > delay_allowed` ?
        //   2. backfill?
        //   3. combine discard and backfill by comparing the entry.timestamp's age and delay_allowed ?

        // Or ... Adjust Timestamps with Metadata Preservation
        //
        // How It Works:
        //
        // - In writeLog, compare entry.timestamp to the current system time (std.time.nanoTimestamp()).
        //
        // - If the difference exceeds a configurable threshold (delay_allowed, e.g., 24 hours), set entry.timestamp to
        // the current time and store the original timestamp in entry.metadata as client_timestamp.
        //
        // - Persist the adjusted entry in the WAL and memtable, ensuring SSTables are written in chronological order.
        //
        // - Apply the same validation in recover to handle WAL entries consistently.

        if (entry.message.len > self.config.max_log_entry_write_size) {
            // TODO future: report write discard via metrics
            std.log.warn(
                "Discarding oversized log entry when write (size: {d}, max: {d})",
                .{ entry.message.len, self.config.max_log_entry_write_size },
            );

            return MemTableError.LogEntryTooLarge;
        }

        // Write to WAL first for durability
        const max_retries: i32 = 3;
        var retries: i32 = max_retries;
        while (retries >= 0) : (retries -= 1) {
            self.wal.append(self.gpa, &entry) catch |err| {
                std.log.warn("WAL append failed (retries left: {d}), caused by: {}", .{ retries, err });

                switch (err) {
                    error.DiskFull => {
                        // TODO future: Metric increment discards due to disk full
                        std.log.warn("write_log_discard_disk_full: 1", .{});
                        if (retries == 0) return MemTableError.DiskFull;
                    },
                    error.OutOfMemory => {
                        std.log.warn("write_log_discard_oom: 1", .{});
                        if (retries == 0) return MemTableError.OutOfMemory;
                    },
                    else => {
                        std.log.warn("write_log_discard_filesystem: 1", .{});
                        if (retries == 0) return MemTableError.FileSystemError;
                    },
                }

                std.Thread.sleep(std.time.ns_per_ms * 100);
                continue;
            };

            break;
        }

        const index = self.findInsertIndex(entry.timestamp);

        // Then insert to MemTable
        try self.entries.insert(self.entry_allocator, index, entry);

        // TODO future: writeLog and flush must be guarded by a lock

        // Check if flush is needed
        if (self.entries.items.len >= self.config.flush_threshold) {
            try self.flush();
        }
    }

    /// Appends a log entry to the MemTable (used during recovery).
    fn writeLogRecover(self: *MemTable, entry: LogEntry) !void {
        const index = self.findInsertIndex(entry.timestamp);
        try self.entries.insert(self.entry_allocator, index, entry);
    }

    /// Flushes the memtable to an SSTable file, making entries durable.
    /// Clears the memtable and resets its arena, invalidating all prior LogEntry instances.
    /// The WAL retains all entries written in the current write-flush cycle until a future
    /// checkpoint or truncation, ensuring crash recovery can replay unflushed entries.
    fn flush(self: *MemTable) !void {
        if (self.entries.items.len == 0) return;

        // Generate uniq SSTable filename (e.g., sst_0001.bin)
        const filename = try std.fmt.allocPrint(
            self.gpa,
            "sst_{d:0>4}.bin",
            .{self.sstable_files.items.len + 1},
        );
        errdefer self.gpa.free(filename);

        try self.writeSstableFile(filename, self.entries.items);

        // Track SSTable file
        try self.sstable_files.append(self.gpa, filename);

        // compaction trigger
        if (self.sstable_files.items.len >= self.config.max_sstables_before_compact) {
            try self.compact();
        }

        // Clear memtable
        self.entries.clearAndFree(self.entry_allocator);
        _ = self.arena.reset(.free_all);

        // Append checkpoint to WAL
        try self.wal.append(self.gpa, &CheckpointEntry);

        // TODO future: clear content of wal once WAL-append and flush-to-SSTable is atomic
        //   This pattern is common in durable systems (e.g., Kafka logs checkpoint offsets)—it's why WALs often persist
        //   longer than needed until compaction.
    }

    // TODO future: background compaction
    fn compact(self: *MemTable) !void {
        // Safe guarantee: only compact L0 when full
        if (self.sstable_files.items.len < self.config.max_sstables_before_compact) return;

        var arena_allocator = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_allocator.deinit();

        const arena = arena_allocator.allocator();

        // 1. Merge all L0 files
        var merged_entries = std.ArrayList(LogEntry).empty;

        const buffer = try arena.alloc(u8, self.config.max_log_entry_recover_size);

        for (self.sstable_files.items) |filename| {
            // TODO remove duplication: extract function scanFile, but with filter fn
            const f = try std.fs.cwd().openFile(filename, .{ .mode = .read_only });
            defer f.close();

            var file_reader = f.reader(buffer);
            const reader = &file_reader.interface;

            while (true) {
                _ = reader.takeInt(u64, .little) catch |err| switch (err) {
                    error.EndOfStream => break,
                    error.ReadFailed => {
                        std.log.warn("Corrupted SSTable {s}: failed to read timestamp", .{filename});
                        break;
                    },
                };

                const len = reader.takeInt(u32, .little) catch |err| switch (err) {
                    error.EndOfStream, error.ReadFailed => {
                        std.log.warn("Corrupted SSTable {s}: failed to read length", .{filename});
                        break;
                    },
                };

                const serialized = try arena.alloc(u8, len);
                errdefer arena.free(serialized);

                reader.readSliceAll(serialized) catch {
                    std.log.warn("Corrupted SSTable {s}: failed to read entry", .{filename});

                    // Must be freed by manual as `errdefer` will not be executed
                    arena.free(serialized);

                    break;
                };

                const entry = try LogEntry.deser(arena, serialized);
                try merged_entries.append(arena, entry);
            }
        }

        // Sort by timestamp
        std.mem.sort(LogEntry, merged_entries.items, {}, struct {
            fn lessThan(_: void, lhs: LogEntry, rhs: LogEntry) bool {
                return lhs.timestamp < rhs.timestamp;
            }
        }.lessThan);

        // 2. Write to L1
        const merged_filename = try std.fmt.allocPrint(self.gpa, "sst_compacted_{d}.bin", .{std.time.milliTimestamp()});
        errdefer self.gpa.free(merged_filename);

        try self.writeSstableFile(merged_filename, merged_entries.items);

        // 3. Add to L1
        try self.compacted_files.append(self.gpa, merged_filename);

        // 4. Delete old L0 files
        for (self.sstable_files.items) |old_filename| {
            std.fs.cwd().deleteFile(old_filename) catch |err| {
                std.log.warn("Failed to delete old SSTable file: {s}, caused by: {}", .{ old_filename, err });
            };
            self.gpa.free(old_filename);
        }
        self.sstable_files.clearAndFree(self.gpa);

        // TODO future compact L1 if too big, e.g., compacted_files.items.len > 10
    }

    /// The caller owns the returned slice. Reads log entries within the specified time range [start_ts, end_ts].
    pub fn readLog(self: *const MemTable, arena: Allocator, start_ts: u64, end_ts: u64) ![]const LogEntry {
        // Why arena is used?
        //
        // This function both reads memory entries and scans SSTable files. And needs to clone and deserialize
        // them and return slice to the caller.
        //
        // Arena is used to avoid unnecessary memory copies and ease freeing memory at the caller site.

        // TODO future: In readLog's SSTable loop: If len > arena-available, arena.alloc could OOM—add a check if
        //   (len > some_reasonable_max) continue; mirroring config limits.

        var result = std.ArrayList(LogEntry).empty;
        defer result.deinit(arena);

        // Read from memtable
        for (self.entries.items) |it| {
            if (it.timestamp >= start_ts and it.timestamp <= end_ts) {
                const cloned = try it.clone(arena);
                try result.append(arena, cloned);
            }
        }

        const buffer = try self.gpa.alloc(u8, self.config.max_log_entry_recover_size);
        defer self.gpa.free(buffer);

        // Scan L0
        for (self.sstable_files.items) |filename| {
            try scanSstableFile(&result, filename, buffer, arena, start_ts, end_ts);
        }

        // Scan L1
        for (self.compacted_files.items) |filename| {
            try scanSstableFile(&result, filename, buffer, arena, start_ts, end_ts);
        }

        // Sort results by timestamp
        //   thus handle cases where SSTables and memtable entries are interleaved
        // TODO future: avoid global sort, as much as possible. NOTE: compacted file is guaranteed in sorted order
        std.sort.heap(LogEntry, result.items, {}, struct {
            fn lessThan(_: void, lhs: LogEntry, rhs: LogEntry) bool {
                return lhs.timestamp < rhs.timestamp;
            }
        }.lessThan);

        return try result.toOwnedSlice(arena);
    }

    /// Write entries in binary format: [timestamp: u64][length: u32][serialized_entry] .
    fn writeSstableFile(self: *const MemTable, filename: []const u8, entries: []const LogEntry) !void {
        const f = try std.fs.cwd().createFile(filename, .{});
        defer f.close();

        for (entries) |entry| {
            try f.writeAll(&std.mem.toBytes(entry.timestamp));

            // `self.gpa` is used for accurate memory control.
            const serialized = try entry.ser(self.gpa);
            defer self.gpa.free(serialized);
            try f.writeAll(&std.mem.toBytes(@as(u32, @intCast(serialized.len))));

            try f.writeAll(serialized);
        }
        try f.sync();
    }

    fn scanSstableFile(
        result: *std.ArrayList(LogEntry),
        filename: []const u8,
        buffer: []u8,
        arena: Allocator,
        start_ts: u64,
        end_ts: u64,
    ) !void {
        const f = try std.fs.cwd().openFile(filename, .{ .mode = .read_only });
        defer f.close();

        var file_reader = f.reader(buffer);
        const reader = &file_reader.interface;

        while (true) {
            // Read timestamp (u64)
            const timestamp = reader.takeInt(u64, .little) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => {
                    std.log.warn("Corrupted SSTable {s}: incomplete timestamp", .{filename});
                    break;
                },
            };

            // Read length (u32)
            const len = reader.takeInt(u32, .little) catch |err| switch (err) {
                error.EndOfStream, error.ReadFailed => {
                    std.log.warn("Corrupted SSTable {s}: incomplete length", .{filename});
                    break;
                },
            };

            // Read serialized entry
            const serialized = try arena.alloc(u8, len);
            errdefer arena.free(serialized);

            reader.readSliceAll(serialized) catch {
                std.log.warn("Corrupted SSTable {s}: incomplete entry", .{filename});

                // Must be freed by manual as `errdefer` will not be executed
                arena.free(serialized);
                break;
            };

            // Skip entries outside time range
            if (timestamp < start_ts or timestamp > end_ts) continue;

            // Deserialize and add to result
            const entry = try LogEntry.deser(arena, serialized);
            try result.append(arena, entry);
        }
    }

    /// Recovers log entries from the WAL file into the MemTable.
    fn recover(self: *MemTable, wal_filename: []const u8) !void {
        const f = try std.fs.cwd().openFile(wal_filename, .{ .mode = .read_only });
        defer f.close();

        const buffer = try self.gpa.alloc(u8, self.config.max_log_entry_recover_size);
        defer self.gpa.free(buffer);

        var file_reader = f.reader(buffer);
        const reader = &file_reader.interface;

        while (true) {
            if (reader.peekDelimiterExclusive('\n')) |_| {
                // Read CRC32 (u32)
                const expected_crc = reader.takeInt(u32, .little) catch |err| switch (err) {
                    error.EndOfStream => break,
                    error.ReadFailed => {
                        std.log.warn("Corrupted WAL: incomplete CRC32 at offset {}", .{try f.getPos()});
                        break;
                    },
                };

                const json_line = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
                    error.StreamTooLong => {
                        // TODO future: report recover discard via metrics
                        std.log.warn(
                            "Discarding oversized log entry when recover (max: {d})",
                            .{buffer.len},
                        );

                        // skip rest bytes of this long line
                        _ = reader.discardDelimiterInclusive('\n') catch unreachable;

                        continue;
                    },
                    error.EndOfStream, error.ReadFailed => return err,
                };

                // Verify CRC32
                const actual_crc = std.hash.Crc32.hash(json_line);
                if (actual_crc != expected_crc) {
                    std.log.warn("Corrupted WAL entry: CRC32 mismatch (expected: {x:8}, actual: {x:8})", .{ expected_crc, actual_crc });
                    continue;
                }

                const owned_json_line = try self.entry_allocator.dupe(u8, json_line);
                errdefer self.entry_allocator.free(owned_json_line);

                const entry = LogEntry.deser(self.entry_allocator, owned_json_line) catch |err| {
                    // There might be some memory leak, but it's okay as `MemTable.arena` will be reset in each
                    // writeLog-flush cycle.

                    std.log.warn("Skipping invalid log entry during recovery: {s}, caused by: {}", .{ json_line, err });

                    // Must be freed by manual as `errdefer` will not be executed
                    self.entry_allocator.free(owned_json_line);

                    continue;
                };

                if (std.mem.eql(u8, entry.message, CheckpointEntry.message) and entry.timestamp == CheckpointEntry.timestamp) {
                    // Checkpoint found: Clear memtable (prior entries are in SSTables)
                    self.entries.clearAndFree(self.entry_allocator);
                    _ = self.arena.reset(.free_all);
                    continue; // Continue to replay post-checkpoint entries
                }

                // Use recovery-specific writeLog
                try self.writeLogRecover(entry);
            } else |err| switch (err) {
                error.EndOfStream => break,
                error.StreamTooLong => {
                    // TODO future: report recover discard via metrics
                    std.log.warn(
                        "Discarding oversized log entry when recover (max: {d})",
                        .{buffer.len},
                    );

                    // skip rest bytes of this long line
                    _ = reader.discardDelimiterInclusive('\n') catch unreachable;
                },
                error.ReadFailed => return err,
            }
        }
    }
};

test "writeAndReadLog" {
    const t_allocator = testing.allocator;
    const wal_filename = "test_memtable_writeAndReadLog.wal";

    var mt = try MemTable.init(t_allocator, wal_filename, .{});
    defer mt.deinit();
    defer cleanupTestWalFile(wal_filename);

    const entry1 = try createTestLogEntry(mt.entry_allocator, "test log 1");
    const entry2 = try createTestLogEntry(mt.entry_allocator, "test log 2");
    try mt.writeLog(entry1);
    try mt.writeLog(entry2);

    try testing.expectEqual(@as(usize, 2), mt.entries.items.len);

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const logs = try mt.readLog(arena.allocator(), 0, std.math.maxInt(u64));

    try testing.expectEqual(@as(usize, 2), logs.len);
    try testing.expectEqualStrings("test log 1", logs[0].message);
    try testing.expectEqualStrings("test log 2", logs[1].message);
}

test "readEmptyTimeRange" {
    const t_allocator = testing.allocator;
    const wal_filename = "test_memtable_readEmptyTimeRange.wal";

    var mt = try MemTable.init(t_allocator, wal_filename, .{});
    defer mt.deinit();
    defer cleanupTestWalFile(wal_filename);

    try mt.writeLog(try createTestLogEntry(mt.entry_allocator, "test log"));

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const logs = try mt.readLog(arena.allocator(), 100, 100);

    try testing.expectEqual(@as(usize, 0), logs.len);
}

test "readInvalidTimeRange" {
    const t_allocator = testing.allocator;
    const wal_filename = "test_memtable_readInvalidTimeRange.wal";

    var mt = try MemTable.init(t_allocator, wal_filename, .{});
    defer mt.deinit();
    defer cleanupTestWalFile(wal_filename);

    try mt.writeLog(try createTestLogEntry(mt.entry_allocator, "test log"));

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const logs = try mt.readLog(arena.allocator(), 200, 100);

    try testing.expectEqual(@as(usize, 0), logs.len);
}

test "flushAndReadSSTable" {
    const t_allocator = testing.allocator;
    const wal_filename = "test_memtable_flushAndReadSSTable.wal";

    var mt = try MemTable.init(t_allocator, wal_filename, .{ .flush_threshold = 2 });
    defer mt.deinit();
    defer cleanupTestWalFile(wal_filename);
    defer cleanupSstableFiles(mt.sstable_files.items);

    const entry1 = try createTestLogEntry(mt.entry_allocator, "test log 1");
    try mt.writeLog(entry1);

    // guarantee the sort order by delaying 10 ms
    std.Thread.sleep(std.time.ns_per_ms * 10);
    const entry2 = try createTestLogEntry(mt.entry_allocator, "test log 2");
    try mt.writeLog(entry2); // triggers flush

    // guarantee the sort order by delaying 10 ms
    std.Thread.sleep(std.time.ns_per_ms * 10);
    const entry3 = try createTestLogEntry(mt.entry_allocator, "test log 3");
    try mt.writeLog(entry3);

    try testing.expectEqual(@as(usize, 1), mt.entries.items.len);
    try testing.expectEqual(@as(usize, 1), mt.sstable_files.items.len);

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const logs = try mt.readLog(arena.allocator(), 0, std.math.maxInt(u64));

    // 3 entries returned
    try testing.expectEqual(@as(usize, 3), logs.len);

    try testing.expectEqualStrings("test log 1", logs[0].message);
    try testing.expectEqualStrings("test log 2", logs[1].message);
    try testing.expectEqualStrings("test log 3", logs[2].message);
}

// Run this test manually with:
// `RUN_SLOW_TEST=1 zig test --test-filter writeManyLogs src/memtable.zig`
test "writeManyLogs" {
    const t_allocator = testing.allocator;
    const wal_filename = "test_memtable_writeManyLogs.wal";

    const env_var = std.process.getEnvVarOwned(t_allocator, "RUN_SLOW_TEST") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer t_allocator.free(env_var);

    var mt = try MemTable.init(t_allocator, wal_filename, .{ .flush_threshold = 1000 });
    defer mt.deinit();
    defer cleanupTestWalFile(wal_filename);
    defer cleanupSstableFiles(mt.sstable_files.items);
    defer cleanupSstableFiles(mt.compacted_files.items);

    const entry_count = 100_000;

    var timer = try std.time.Timer.start();

    var msg_1k: [1024]u8 = undefined;
    @memset(&msg_1k, 'x');

    var arena_write = ArenaAllocator.init(testing.allocator);
    defer arena_write.deinit();

    const allocator = arena_write.allocator();

    // Measure write time
    const write_start_ns = timer.read();
    for (0..entry_count) |i| {
        const message = try std.fmt.allocPrint(allocator, "INFO | test log {d} {s}", .{ i, msg_1k });

        try mt.writeLog(try createTestLogEntryWithMetadata(allocator, message, "{\"level\":\"INFO\"}"));
    }
    const write_time_ns = timer.read() - write_start_ns;

    // All entries have been flushed to SSTable files.
    try testing.expectEqual(@as(usize, 0), mt.entries.items.len);

    // Measure read time
    var arena_read = ArenaAllocator.init(testing.allocator);
    defer arena_read.deinit();
    const read_start_ns = timer.read();
    const logs = try mt.readLog(arena_read.allocator(), 0, std.math.maxInt(u64));
    const read_time_ns = timer.read() - read_start_ns;

    try testing.expectEqual(@as(usize, entry_count), logs.len);

    const ratio = @as(f64, @floatFromInt(write_time_ns)) / @as(f64, @floatFromInt(read_time_ns));
    std.debug.print(
        "writeManyLogs (threshold={d}): wrote {} entries in {} ns, read in {} ns, ratio={d:.2}\n",
        .{ mt.config.flush_threshold, entry_count, write_time_ns, read_time_ns, ratio },
    );

    // TODO future: for a logging system, write:read ratios of 10:1 to 100:1 are typicial for write-heavy workloads
    //   read performance needs improvement

    try testing.expect(write_time_ns < read_time_ns * 15);
}

test "writeLogRetryFailure" {
    const t_allocator = testing.allocator;
    const wal_filename = "test_memtable_writeLogRetryFailure.wal";

    var mt = try MemTable.init(t_allocator, wal_filename, .{});
    defer mt.deinit();
    defer cleanupTestWalFile(wal_filename);

    // Configure WAL to fail append 4 times (to cover original append + 3 retries)
    mt.wal.setTestingFailCount(4);

    // Expect failure and no entries change
    const entry = try createTestLogEntry(mt.entry_allocator, "test log");
    try testing.expectError(MemTableError.DiskFull, mt.writeLog(entry));
    try testing.expectEqual(@as(usize, 0), mt.entries.items.len);

    // Expect empty WAL
    const f = try std.fs.cwd().openFile(wal_filename, .{ .mode = .read_only });
    defer f.close();
    try testing.expectEqual(@as(u64, 0), try f.getEndPos());

    // Test partial success (fail 3 times, succeed on last retry)
    mt.wal.setTestingFailCount(3);
    try mt.writeLog(entry);
    try testing.expectEqual(@as(usize, 1), mt.entries.items.len);
    try testing.expectEqualStrings("test log", mt.entries.items[0].message);
}

test "writeOversizedLog" {
    const t_allocator = testing.allocator;
    const wal_filename = "test_memtable_writeOversizedLog.wal";

    var mt = try MemTable.init(
        t_allocator,
        wal_filename,
        .{ .max_log_entry_write_size = 10 },
    );
    defer mt.deinit();
    defer cleanupTestWalFile(wal_filename);

    const entry = try createTestLogEntry(mt.entry_allocator, "1234567890a");

    try testing.expectError(MemTableError.LogEntryTooLarge, mt.writeLog(entry));
    try testing.expectEqual(@as(usize, 0), mt.entries.items.len);
}

test "recoverSuccess" {
    const t_allocator = testing.allocator;
    const wal_filename = "test_memtable_recover.wal";

    defer cleanupTestWalFile(wal_filename);

    {
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        const allocator = arena.allocator();

        var wal = try Wal.init(wal_filename);
        defer wal.deinit();

        const entry = try createTestLogEntryWithMetadata(
            allocator,
            "INFO | test log",
            "{\"level\":\"INFO\"}",
        );

        try wal.append(allocator, &entry);
    }

    var mt = try MemTable.init(t_allocator, wal_filename, .{});
    defer mt.deinit();

    try testing.expectEqual(@as(usize, 1), mt.entries.items.len);

    const recovered_entry = mt.entries.items[0];
    try testing.expectEqualStrings("INFO | test log", recovered_entry.message);
    try testing.expect(recovered_entry.metadata != null);
    if (recovered_entry.metadata) |m| {
        try testing.expect(m == .object);
        try testing.expectEqualStrings("INFO", m.object.get("level").?.string);
    }
}

test "recoverOversizedLog" {
    const t_allocator = testing.allocator;
    const wal_filename = "test_memtable_recoverOversizedLog.wal";

    defer cleanupTestWalFile(wal_filename);

    {
        var wal = try Wal.init(wal_filename);
        defer wal.deinit();

        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        const allocator = arena.allocator();

        var message: [100]u8 = undefined;
        @memset(&message, 'x');
        const entry = try createTestLogEntry(allocator, &message);

        try wal.append(allocator, &entry);
    }

    var mt = try MemTable.init(
        t_allocator,
        wal_filename,
        .{ .max_log_entry_recover_size = 100 },
    );
    defer mt.deinit();

    try testing.expectEqual(@as(usize, 0), mt.entries.items.len);
}

test "recoverCorruptedLog" {
    const t_allocator = testing.allocator;
    const wal_filename = "test_memtable_recoverCorruptedLog.wal";

    defer cleanupTestWalFile(wal_filename);

    // Write a valid entry and a corrupted entry
    {
        var wal = try Wal.init(wal_filename);
        defer wal.deinit();

        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        const allocator = arena.allocator();

        // Valid entry
        const entry = try createTestLogEntry(allocator, "test log");
        try wal.append(allocator, &entry);

        // Corrupted entry (wrong CRC)
        const bad_crc = std.mem.toBytes(@as(u32, 0xDEADBEEF));
        try wal.f.writeAll(&bad_crc);
        try wal.f.writeAll("{\"timestamp\":1234567890,\"message\":\"bad\"}");
        try wal.f.writeAll("\n");
        try wal.f.sync();
    }

    var mt = try MemTable.init(t_allocator, wal_filename, .{});
    defer mt.deinit();

    try testing.expectEqual(@as(u32, 1), mt.entries.items.len);
    try testing.expectEqualStrings("test log", mt.entries.items[0].message);
}

test "recoverMalformedLog" {
    const t_allocator = testing.allocator;
    const wal_filename = "test_memtable_recoverMalformedLog.wal";

    defer cleanupTestWalFile(wal_filename);

    // Write a valid entry and a malformed entry
    {
        var wal = try Wal.init(wal_filename);
        defer wal.deinit();

        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        const allocator = arena.allocator();

        // Valid entry
        const entry = try createTestLogEntry(allocator, "test log");
        try wal.append(allocator, &entry);

        // Malformed entry
        const malformed_json = "{\"timestamp\":1234567890,\"message\":,}";
        const crc = std.hash.Crc32.hash(malformed_json);
        try wal.f.writeAll(&std.mem.toBytes(crc));
        try wal.f.writeAll(malformed_json);
        try wal.f.writeAll("\n");
        try wal.f.sync();
    }

    var mt = try MemTable.init(t_allocator, wal_filename, .{});
    defer mt.deinit();

    try testing.expectEqual(@as(usize, 1), mt.entries.items.len);
    try testing.expectEqualStrings("test log", mt.entries.items[0].message);
}

test "recovery with checkpoint avoids duplicates" {
    const t_allocator = testing.allocator;
    const wal_filename = "test_memtable_recovery_with_checkpoint.wal";

    // Setup Memtable with low threshold
    var mt = try MemTable.init(t_allocator, wal_filename, .{ .flush_threshold = 2 });

    // flush (adds checkpoint)
    try mt.writeLog(try createTestLogEntry(mt.entry_allocator, "entry1"));
    std.Thread.sleep(std.time.ns_per_ms * 10);
    try mt.writeLog(try createTestLogEntry(mt.entry_allocator, "entry2"));

    // post-checkpoint
    std.Thread.sleep(std.time.ns_per_ms * 10);
    try mt.writeLog(try createTestLogEntry(mt.entry_allocator, "entry3"));

    // One SSTable created, prepare an additional sstable_files for cleanup, as `deinit` will free them.
    try testing.expectEqual(@as(usize, 1), mt.sstable_files.items.len);
    const sstable_file = try t_allocator.dupe(u8, mt.sstable_files.items[0]);
    defer t_allocator.free(sstable_file);
    var sstable_files = [_][]u8{sstable_file};

    // Simulate crash/recovery: Deinit and re-init
    mt.deinit();
    mt = try MemTable.init(t_allocator, wal_filename, .{ .flush_threshold = 2 });
    defer mt.deinit();

    // Verify: Only entry3 in memtable (entry1 and entry2 are in SST, not duplicated)
    try testing.expectEqual(@as(usize, 1), mt.entries.items.len);
    try testing.expectEqualStrings("entry3", mt.entries.items[0].message);

    cleanupTestWalFile(wal_filename);
    cleanupSstableFiles(&sstable_files);
}

test "compaction merge correctness and sort order" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const allocator = gpa.allocator();

    const wal_filename = "test_memtable_compaction.wal";
    defer cleanupTestWalFile(wal_filename);

    var mt = try MemTable.init(allocator, wal_filename, .{ .max_sstables_before_compact = 2 });
    defer mt.deinit();

    // Create mock entries
    const entries1 = [_]LogEntry{
        try createTestLogEntryWithTs(mt.entry_allocator, "msg1", 1000),
        try createTestLogEntryWithTs(mt.entry_allocator, "msg3", 3000),
    };
    const entries2 = [_]LogEntry{
        try createTestLogEntryWithTs(mt.entry_allocator, "msg2", 2000),
        try createTestLogEntryWithTs(mt.entry_allocator, "msg2.5", 2500), // Overlap
    };

    // Write mock SSTables
    const sst1 = "sst_test1.bin";
    const sst2 = "sst_test2.bin";
    try writeMockSstable(allocator, sst1, &entries1);
    try writeMockSstable(allocator, sst2, &entries2);
    defer std.fs.cwd().deleteFile(sst1) catch {};
    defer std.fs.cwd().deleteFile(sst2) catch {};

    // Mock sstable_files
    try mt.sstable_files.append(allocator, try allocator.dupe(u8, sst1));
    try mt.sstable_files.append(allocator, try allocator.dupe(u8, sst2));

    // Run compact
    try mt.compact();

    // Verify: L0 empty, L1 has 1 new file
    try testing.expectEqual(@as(usize, 0), mt.sstable_files.items.len);
    try testing.expectEqual(@as(usize, 1), mt.compacted_files.items.len);
    const new_sst = mt.compacted_files.items[0];

    var arena = ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Read new SST, check merged/sorted
    const read_entries = try readSstable(arena.allocator(), new_sst, 256);
    try testing.expectEqual(@as(usize, 4), read_entries.items.len);
    try testing.expectEqual(1000, read_entries.items[0].timestamp);
    try testing.expectEqualStrings("msg1", read_entries.items[0].message);
    try testing.expectEqual(2000, read_entries.items[1].timestamp);
    try testing.expectEqual(2500, read_entries.items[2].timestamp);
    try testing.expectEqual(3000, read_entries.items[3].timestamp);

    // Cleanup new file
    std.fs.cwd().deleteFile(new_sst) catch {};
}

test "end-to-end compaction under load" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const allocator = gpa.allocator();

    const wal_filename = "test_memtable_compaction_e2e.wal";
    defer cleanupTestWalFile(wal_filename);

    var mt = try MemTable.init(
        allocator,
        wal_filename,
        .{ .flush_threshold = 5, .max_sstables_before_compact = 3 },
    );
    defer mt.deinit();

    const num_entries = 20; // 4 flushes (>=3 L0 triggers compact)
    for (0..num_entries) |i| {
        const ts = 1000 + i; // Increasing for sort
        try mt.writeLog(try createTestLogEntryWithTs(
            mt.entry_allocator,
            try std.fmt.allocPrint(mt.entry_allocator, "msg{d}", .{i}),
            ts,
        ));
    }

    // Verify compaction happened
    try testing.expectEqual(@as(usize, 1), mt.sstable_files.items.len);
    try testing.expectEqual(@as(usize, 1), mt.compacted_files.items.len);

    var arena = ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Read all, verify count/sort
    const read_logs = try mt.readLog(arena.allocator(), 0, std.math.maxInt(u64));
    try testing.expectEqual(@as(usize, 20), read_logs.len);
    for (1..read_logs.len) |j| {
        try testing.expectEqual(1000 + (j - 1), read_logs[j - 1].timestamp);
        try testing.expect(read_logs[j - 1].timestamp <= read_logs[j].timestamp);
    }

    cleanupSstableFiles(mt.sstable_files.items);
    cleanupSstableFiles(mt.compacted_files.items);
}

fn createTestLogEntry(allocator: Allocator, message: []const u8) !LogEntry {
    return LogEntry.init(
        allocator,
        1762072995675,
        message,
        null, // no metadata for simplicity
    );
}

fn createTestLogEntryWithTs(allocator: Allocator, message: []const u8, timestamp: u64) !LogEntry {
    var result = try LogEntry.init(
        allocator,
        1762072995675,
        message,
        null, // no metadata for simplicity
    );
    result.timestamp = timestamp;
    return result;
}

fn createTestLogEntryWithMetadata(allocator: Allocator, message: []const u8, metadata: []const u8) !LogEntry {
    return LogEntry.init(
        allocator,
        1762072995675,
        message,
        metadata,
    );
}

fn writeMockSstable(allocator: Allocator, filename: []const u8, entries: []const LogEntry) !void {
    const f = try std.fs.cwd().createFile(filename, .{});
    defer f.close();

    for (entries) |e| {
        try f.writeAll(&std.mem.toBytes(e.timestamp));

        const serialized = try e.ser(allocator);
        defer allocator.free(serialized);
        try f.writeAll(&std.mem.toBytes(@as(u32, @intCast(serialized.len))));

        try f.writeAll(serialized);
    }
    try f.sync();
}

fn readSstable(arena: Allocator, filename: []const u8, comptime buffer_size: u32) !std.ArrayList(LogEntry) {
    const f = try std.fs.cwd().openFile(filename, .{});
    defer f.close();

    var buffer: [buffer_size]u8 = undefined;
    var file_reader = f.reader(&buffer);
    const reader = &file_reader.interface;

    var entries = std.ArrayList(LogEntry).empty;
    errdefer entries.deinit(arena);

    while (true) {
        // timestamp
        _ = reader.takeInt(u64, .little) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        const len = try reader.takeInt(u32, .little);

        const serialized = try arena.alloc(u8, len);
        try reader.readSliceAll(serialized);

        const entry = try LogEntry.deser(arena, serialized);
        try entries.append(arena, entry);
    }

    return entries;
}

fn cleanupTestWalFile(filename: []const u8) void {
    std.fs.cwd().deleteFile(filename) catch |err| {
        std.log.warn("Unable to cleanup the wal file: {s}, caused by: {}", .{ filename, err });
    };
}

fn cleanupSstableFiles(filenames: [][]u8) void {
    for (filenames) |filename| {
        std.fs.cwd().deleteFile(filename) catch |err| {
            std.log.warn("Unable to cleanup SSTable {s}, caused by: {}", .{ filename, err });
        };
    }
}
