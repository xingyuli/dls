// Copyright (c) 2025 Vic Lau
// Licensed under the MIT License

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

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
};

pub const MemTable = struct {
    entries: std.ArrayList(LogEntry),

    // for single-node design: one MemTable owns one Wal
    wal: Wal,
    config: Config,

    // Track SSTable filenames
    sstable_files: std.ArrayList([]u8),

    /// Initializes a MemTable and recovers log entries from the specified WAL file.
    /// The caller owns the returned MemTable, deinitialize with `deinit`.
    pub fn init(allocator: Allocator, wal_filename: []const u8, config: Config) !MemTable {
        var self = MemTable{
            .entries = std.ArrayList(LogEntry).init(allocator),
            .wal = try Wal.init(wal_filename),
            .config = config,
            .sstable_files = std.ArrayList([]u8).init(allocator),
        };
        try recover(&self, allocator, wal_filename);
        return self;
    }

    /// Deinitializes the MemTable, freeing all associated resources.
    pub fn deinit(self: *MemTable, entry_allocator: Allocator) void {
        for (self.entries.items) |*it| {
            it.deinit(entry_allocator);
        }
        self.entries.deinit();

        self.wal.deinit();

        for (self.sstable_files.items) |filename| {
            self.sstable_files.allocator.free(filename);
        }
        self.sstable_files.deinit();
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

            return error.LogEntryTooLarge;
        }

        // Write to WAL first for durability
        const max_retries: i32 = 3;
        var retries: i32 = max_retries;
        while (retries >= 0) : (retries -= 1) {
            self.wal.append(self.entries.allocator, &entry) catch |err| {
                std.log.warn("WAL append failed (retries left: {d}), caused by: {}", .{ retries, err });

                // No rollback needed, as entries unchanged
                if (retries == 0) return err;

                std.time.sleep(std.time.ns_per_ms * 100);
                continue;
            };

            break;
        }

        const index = self.findInsertIndex(entry.timestamp);
        // TODO future: auto recover ? maybe unnecessary as MemTable is just a cache and currently not used anywhere else

        // Then insert to MemTable
        try self.entries.insert(index, entry);

        // Check if flush is needed
        if (self.entries.items.len >= self.config.flush_threshold) {
            try self.flush();
        }
    }

    /// Appends a log entry to the MemTable (used during recovery).
    fn writeLogRecover(self: *MemTable, entry: LogEntry) !void {
        const index = self.findInsertIndex(entry.timestamp);
        try self.entries.insert(index, entry);
    }

    /// Flush the memtable to an SSTable file.
    fn flush(self: *MemTable) !void {
        if (self.entries.items.len == 0) return;

        // Generate uniq SSTable filename (e.g., sst_0001.bin)
        const filename = try std.fmt.allocPrint(
            self.sstable_files.allocator,
            "sst_{d:0>4}.bin",
            .{self.sstable_files.items.len + 1},
        );

        const f = try std.fs.cwd().createFile(filename, .{});
        defer f.close();

        // Write entries in binary format: [timestamp: u64][length: u32][serialized_entry]
        for (self.entries.items) |entry| {
            try f.writeAll(&std.mem.toBytes(entry.timestamp));

            const serialized = try entry.ser(self.entries.allocator);
            defer self.entries.allocator.free(serialized);
            try f.writeAll(&std.mem.toBytes(@as(u32, @intCast(serialized.len))));

            try f.writeAll(serialized);
        }
        try f.sync();

        // Track SSTable file
        try self.sstable_files.append(filename);

        // Clear memtable
        for (self.entries.items) |*entry| {
            entry.deinit(self.entries.allocator);
        }
        self.entries.clearRetainingCapacity();
    }

    /// The caller owns the returned slice. Reads log entries within the specified time range [start_ts, end_ts].
    pub fn readLog(self: *const MemTable, start_ts: u64, end_ts: u64) ![]const LogEntry {
        var result = std.ArrayList(LogEntry).init(self.entries.allocator);
        defer result.deinit();

        // Read from memtable
        for (self.entries.items) |it| {
            if (it.timestamp >= start_ts and it.timestamp <= end_ts) {
                const cloned = try it.clone(self.entries.allocator);
                try result.append(cloned);
            }
        }

        // Read from SSTables
        for (self.sstable_files.items) |filename| {
            const f = try std.fs.cwd().openFile(filename, .{ .mode = .read_only });
            defer f.close();

            var reader = f.reader();

            while (true) {
                // Read timestamp (u64)
                var ts_bytes: [8]u8 = undefined;
                const ts_read = try reader.readAll(&ts_bytes);
                if (ts_read == 0) break;
                if (ts_read < 8) {
                    std.log.warn("Corrupted SSTable {s}: incomplete timestamp", .{filename});
                    break;
                }
                const timestamp = std.mem.readInt(u64, &ts_bytes, .little);

                // Read length (u32)
                var len_bytes: [4]u8 = undefined;
                if (try reader.readAll(&len_bytes) < 4) {
                    std.log.warn("Corrupted SSTable {s}: incomplete length", .{filename});
                    break;
                }
                const len = std.mem.readInt(u32, &len_bytes, .little);

                // Read serialized entry
                const serialized = try self.entries.allocator.alloc(u8, len);
                defer self.entries.allocator.free(serialized);
                if (try reader.readAll(serialized) < len) {
                    std.log.warn("Corrupted SSTable {s}: incomplete entry", .{filename});
                    break;
                }

                // Skip entries outside time range
                if (timestamp < start_ts or timestamp > end_ts) continue;

                // Deserialize and add to result
                const entry = try LogEntry.deser(self.entries.allocator, serialized);
                try result.append(entry);
            }
        }

        // Sort results by timestamp
        //   thus handle cases where SSTables and memtable entries are interleaved
        std.sort.heap(LogEntry, result.items, {}, struct {
            fn lessThan(_: void, lhs: LogEntry, rhs: LogEntry) bool {
                return lhs.timestamp < rhs.timestamp;
            }
        }.lessThan);

        return try result.toOwnedSlice();
    }

    /// Recovers log entries from the WAL file into the MemTable.
    fn recover(self: *MemTable, allocator: Allocator, wal_filename: []const u8) !void {
        const f = try std.fs.cwd().openFile(wal_filename, .{ .mode = .read_only });
        defer f.close();

        var reader = f.reader();

        while (true) {
            // Read 4-bytes CRC32
            var crc_bytes: [4]u8 = undefined;
            const crc_read = try reader.readAll(&crc_bytes);
            if (crc_read == 0) break;
            if (crc_read < 4) {
                std.log.warn("Corrupted WAL: incomplete CRC32 at offset {}", .{try f.getPos()});
                break;
            }
            const expected_crc = std.mem.readInt(u32, &crc_bytes, .little);

            const json_line = reader.readUntilDelimiterOrEofAlloc(
                allocator,
                '\n',
                self.config.max_log_entry_recover_size,
            ) catch |err| switch (err) {
                error.StreamTooLong => {
                    // TODO future: report recover discard via metrics
                    std.log.warn(
                        "Discarding oversized log entry when recover (max: {d})",
                        .{self.config.max_log_entry_recover_size},
                    );

                    // skip rest bytes of this long line
                    try reader.skipUntilDelimiterOrEof('\n');

                    continue;
                },
                else => return err,
            } orelse {
                std.log.warn("Corrupted WAL: incompelte entry after CRC32 at offset {}", .{try f.getPos()});
                break;
            };
            defer allocator.free(json_line);

            // Verify CRC32
            const actual_crc = std.hash.Crc32.hash(json_line);
            if (actual_crc != expected_crc) {
                std.log.warn("Corrupted WAL entry: CRC32 mismatch (expected: {x:8}, actual: {x:8})", .{ expected_crc, actual_crc });
                continue;
            }

            const entry = LogEntry.deser(allocator, json_line) catch |err| {
                std.log.warn("Skipping invalid log entry during recovery: {s}, caused by: {}", .{ json_line, err });
                continue;
            };
            // Use recovery-specific writeLog
            try self.writeLogRecover(entry);
        }
    }
};

test "writeAndReadLog" {
    const a = testing.allocator;
    const wal_filename = "test_memtable_writeAndReadLog.wal";

    var t = try MemTable.init(a, wal_filename, .{});
    defer t.deinit(a);
    defer cleanupTestWalFile(wal_filename);

    const entry1 = try LogEntry.init(a, "test log 1", null);
    const entry2 = try LogEntry.init(a, "test log 2", null);
    try t.writeLog(entry1);
    try t.writeLog(entry2);

    try testing.expectEqual(@as(usize, 2), t.entries.items.len);

    const logs = try t.readLog(0, std.math.maxInt(u64));
    defer {
        for (logs) |*entry| {
            entry.deinit(a);
        }
        a.free(logs);
    }

    try testing.expectEqual(@as(usize, 2), logs.len);
    try testing.expectEqualStrings("test log 1", logs[0].message);
    try testing.expectEqualStrings("test log 2", logs[1].message);
}

test "readEmptyTimeRange" {
    const a = testing.allocator;
    const wal_filename = "test_memtable_readEmptyTimeRange.wal";

    var t = try MemTable.init(a, wal_filename, .{});
    defer t.deinit(a);
    defer cleanupTestWalFile(wal_filename);

    try t.writeLog(try LogEntry.init(a, "test log", null));

    const logs = try t.readLog(100, 100);
    defer {
        for (logs) |*entry| {
            entry.deinit(a);
        }
        a.free(logs);
    }

    try testing.expectEqual(@as(usize, 0), logs.len);
}

test "readInvalidTimeRange" {
    const a = testing.allocator;
    const wal_filename = "test_memtable_readInvalidTimeRange.wal";

    var t = try MemTable.init(a, wal_filename, .{});
    defer t.deinit(a);
    defer cleanupTestWalFile(wal_filename);

    try t.writeLog(try LogEntry.init(a, "test log", null));

    const logs = try t.readLog(200, 100);
    defer {
        for (logs) |*entry| {
            entry.deinit(a);
        }
        a.free(logs);
    }

    try testing.expectEqual(@as(usize, 0), logs.len);
}

test "flushAndReadSSTable" {
    const a = testing.allocator;
    const wal_filename = "test_memtable_flushAndReadSSTable.wal";

    var t = try MemTable.init(a, wal_filename, .{ .flush_threshold = 2 });
    defer t.deinit(a);
    defer cleanupTestWalFile(wal_filename);

    const entry1 = try LogEntry.init(a, "test log 1", null);

    // guarantee the sort order by delaying 10 ms
    std.time.sleep(std.time.ns_per_ms * 10);
    const entry2 = try LogEntry.init(a, "test log 2", null);

    // guarantee the sort order by delaying 10 ms
    std.time.sleep(std.time.ns_per_ms * 10);
    const entry3 = try LogEntry.init(a, "test log 3", null);

    try t.writeLog(entry1);
    try t.writeLog(entry2); // triggers flush
    try t.writeLog(entry3);

    try testing.expectEqual(@as(usize, 1), t.entries.items.len);
    try testing.expectEqual(@as(usize, 1), t.sstable_files.items.len);

    const logs = try t.readLog(0, std.math.maxInt(u64));
    defer {
        for (logs) |*entry| {
            entry.deinit(a);
        }
        a.free(logs);
    }

    // 3 entries returned
    try testing.expectEqual(@as(usize, 3), logs.len);

    try testing.expectEqualStrings("test log 1", logs[0].message);
    try testing.expectEqualStrings("test log 2", logs[1].message);
    try testing.expectEqualStrings("test log 3", logs[2].message);
}

// Run this test manually with:
// `RUN_SLOW_TEST=1 zig test --test-filter writeManyLogs src/memtable.zig`
test "writeManyLogs" {
    const a = testing.allocator;
    const wal_filename = "test_memtable_writeManyLogs.wal";

    const env_var = std.process.getEnvVarOwned(a, "RUN_SLOW_TEST") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer a.free(env_var);

    var t = try MemTable.init(a, wal_filename, .{ .flush_threshold = 1000 });
    defer t.deinit(a);
    defer cleanupTestWalFile(wal_filename);

    const entry_count = 100_000;

    var timer = try std.time.Timer.start();

    var msg_1k: [1024]u8 = undefined;
    @memset(&msg_1k, 'x');

    // Measure write time
    const write_start_ns = timer.read();
    for (0..entry_count) |i| {
        const message = try std.fmt.allocPrint(a, "INFO | test log {d} {s}", .{ i, msg_1k });
        defer a.free(message);

        try t.writeLog(try LogEntry.init(a, message, "{\"level\":\"INFO\"}"));
    }
    const write_time_ns = timer.read() - write_start_ns;

    // All entries have been flushed to SSTable files.
    try testing.expectEqual(@as(usize, 0), t.entries.items.len);

    // Measure read time
    const read_start_ns = timer.read();
    const logs = try t.readLog(0, std.math.maxInt(u64));
    defer {
        for (logs) |*entry| {
            entry.deinit(a);
        }
        a.free(logs);
    }
    const read_time_ns = timer.read() - read_start_ns;

    try testing.expectEqual(@as(usize, entry_count), logs.len);

    // Log performance metrics (in nanoseconds)
    //
    // example result on my M1 laptop

    // V1: pure memory manipulations against ArrayList
    //   writeManyLogs: wrote 10000 entries in 585515041 ns, read in 1236500 ns i.e., 585ms write (58us/w), 1.2ms read
    //   writeManyLogs: wrote 10000 entries in 582988125 ns, read in 1116459 ns i.e., 582ms write (58us/w), 1.1ms read
    //
    // write:read ratio is about 500:1
    //
    // analysis: writes are slower due to LogEntry.init allocations (message, metadata)

    // V2: V1 + WAL peristence
    //   writeManyLogs: wrote 10000 entries in 1151385167 ns, read in 1066625 ns i.e., 1151ms write (115us/w), 1.1ms read
    //   writeManyLogs: wrote 10000 entries in 1154585750 ns, read in 1074084 ns i.e., 1155ms write (115us/w), 1.1ms read
    //   writeManyLogs: wrote 10000 entries in 1158775833 ns, read in 1084625 ns i.e., 1159ms write (115us/w), 1.1ms read
    //
    // write:read ratio is about 1000:1
    //
    // analysis: file written contributes more time

    // V3: V2 + 1kb message per entry
    //   writeManyLogs: wrote 10000 entries in 1380758708 ns, read in 1147291 ns i.e., 1381ms write (138us/w), 1.1ms read
    //   writeManyLogs: wrote 10000 entries in 1378943916 ns, read in 1101416 ns i.e., 1379ms write (138us/w), 1.1ms read
    //   writeManyLogs: wrote 10000 entries in 1388833041 ns, read in 1147000 ns i.e., 1389ms write (139us/w), 1.1ms read
    //
    // write:read ratio is about 1300:1
    //
    //   writeManyLogs: wrote 100000 entries in 17,405,096,417 ns, read in 12,050,583 ns i.e., 17.4s write (174us/w), 12ms read
    //   writeManyLogs: wrote 100000 entries in 17,789,530,333 ns, read in  9,844,917 ns i.e., 17.8s write (178us/w), 9.8ms read
    //
    // write:read ratio is about 1600:1
    //
    // analysis:
    // - small to 1k message size  contributes more time
    // - 10,000 -> 100,000 entries contributes more time

    // V4: V3 + flush
    //
    //   compared with previous V3 at scale of 10000 entries
    //     V3 wrote 1388833041ns, read 1147000
    //     V4 wrote 2504444542ns, read 1478251041 ratio ~1.70
    //
    //   compared with previous V3 at scale of 100000 entries (thus 100 SSTable files)
    //     V3 wrote 17,405,096,417 ns, read     12,050,583 ns i.e., 17.4s write, 12ms  read
    //     V4 wrote 24,136,889,500 ns, read 18,805,935,500 ns i.e., 24.1s write, 18.8s read
    //
    // write:read ratio of V4 is:
    //   1.70 at  10000 entries
    //   1.28 at 100000 entries
    //
    // analysis: 100 SSTable I/O use a lot of time both when write and read (sequential disk access)

    const ratio = @as(f64, @floatFromInt(write_time_ns)) / @as(f64, @floatFromInt(read_time_ns));
    std.debug.print(
        "writeManyLogs (threshold={d}): wrote {} entries in {} ns, read in {} ns, ratio={d:.2}\n",
        .{ t.config.flush_threshold, entry_count, write_time_ns, read_time_ns, ratio },
    );

    // TODO future: for a logging system, write:read ratios of 10:1 to 100:1 are typicial for write-heavy workloads
    //  read performance needs improvement

    try testing.expect(write_time_ns < read_time_ns * 5);

    // Clean up SSTable files
    for (t.sstable_files.items) |filename| {
        std.fs.cwd().deleteFile(filename) catch |err| {
            std.log.warn("Unable to cleanup SSTable {s}, caused by: {}", .{ filename, err });
        };
    }
}

test "writeLogRetryFailure" {
    const a = testing.allocator;
    const wal_filename = "test_memtable_writeLogRetryFailure.wal";

    var t = try MemTable.init(a, wal_filename, .{});
    defer t.deinit(a);
    defer cleanupTestWalFile(wal_filename);

    // Configure WAL to fail append 4 times (to cover original append + 3 retries)
    t.wal.setTestingFailCount(4);

    // Expect failure and no entries change
    const entry = try LogEntry.init(a, "test log", null);
    try testing.expectError(error.DiskFull, t.writeLog(entry));
    try testing.expectEqual(@as(usize, 0), t.entries.items.len);

    // Expect empty WAL
    const f = try std.fs.cwd().openFile(wal_filename, .{ .mode = .read_only });
    defer f.close();
    try testing.expectEqual(@as(u64, 0), try f.getEndPos());

    // Test partial success (fail 3 times, succeed on last retry)
    t.wal.setTestingFailCount(3);
    try t.writeLog(entry);
    try testing.expectEqual(@as(usize, 1), t.entries.items.len);
    try testing.expectEqualStrings("test log", t.entries.items[0].message);
}

test "writeOversizedLog" {
    const a = testing.allocator;
    const wal_filename = "test_memtable_writeOversizedLog.wal";

    var t = try MemTable.init(
        a,
        wal_filename,
        .{ .max_log_entry_write_size = 10 },
    );
    defer t.deinit(a);
    defer cleanupTestWalFile(wal_filename);

    const entry = try LogEntry.init(a, "1234567890a", null);
    defer entry.deinit(a);

    try testing.expectError(error.LogEntryTooLarge, t.writeLog(entry));

    try testing.expectEqual(@as(usize, 0), t.entries.items.len);
}

test "recover" {
    const a = testing.allocator;
    const wal_filename = "test_memtable_recover.wal";

    defer cleanupTestWalFile(wal_filename);

    {
        var wal = try Wal.init(wal_filename);
        defer wal.deinit();

        const entry = try LogEntry.init(
            a,
            "INFO | test log",
            "{\"level\":\"INFO\"}",
        );
        defer entry.deinit(a);

        try wal.append(a, &entry);
    }

    var t = try MemTable.init(a, wal_filename, .{});
    defer t.deinit(a);

    try testing.expectEqual(@as(usize, 1), t.entries.items.len);

    const recovered_entry = t.entries.items[0];
    try testing.expectEqualStrings("INFO | test log", recovered_entry.message);
    try testing.expect(recovered_entry.metadata != null);
    if (recovered_entry.metadata) |meta| {
        try testing.expect(meta.value == .object);
        try testing.expectEqualStrings("INFO", meta.value.object.get("level").?.string);
    }
}

test "recoverOversizedLog" {
    const a = testing.allocator;
    const wal_filename = "test_memtable_recoverOversizedLog.wal";

    defer cleanupTestWalFile(wal_filename);

    {
        var wal = try Wal.init(wal_filename);
        defer wal.deinit();

        var message: [100]u8 = undefined;
        @memset(&message, 'x');
        const entry = try LogEntry.init(a, &message, null);
        defer entry.deinit(a);

        try wal.append(a, &entry);
    }

    var t = try MemTable.init(
        a,
        wal_filename,
        .{ .max_log_entry_recover_size = 100 },
    );
    defer t.deinit(a);

    try testing.expectEqual(@as(usize, 0), t.entries.items.len);
}

test "recoverCorruptedLog" {
    const a = testing.allocator;
    const wal_filename = "test_memtable_recoverCorruptedLog.wal";

    defer cleanupTestWalFile(wal_filename);

    // Write a valid entry and a corrupted entry
    {
        var wal = try Wal.init(wal_filename);
        defer wal.deinit();

        // Valid entry
        const entry = try LogEntry.init(a, "test log", null);
        defer entry.deinit(a);
        try wal.append(a, &entry);

        // Corrupted entry (wrong CRC)
        const bad_crc = std.mem.toBytes(@as(u32, 0xDEADBEEF));
        try wal.f.writeAll(&bad_crc);
        try wal.f.writeAll("{\"timestamp\":1234567890,\"message\":\"bad\"}");
        try wal.f.writeAll("\n");
        try wal.f.sync();
    }

    var t = try MemTable.init(a, wal_filename, .{});
    defer t.deinit(a);

    try testing.expectEqual(@as(u32, 1), t.entries.items.len);
    try testing.expectEqualStrings("test log", t.entries.items[0].message);
}

test "recoverMalformedLog" {
    const a = testing.allocator;
    const wal_filename = "test_memtable_recoverMalformedLog.wal";

    defer cleanupTestWalFile(wal_filename);

    // Write a valid entry and a malformed entry
    {
        var wal = try Wal.init(wal_filename);
        defer wal.deinit();

        // Valid entry
        const entry = try LogEntry.init(a, "test log", null);
        defer entry.deinit(a);
        try wal.append(a, &entry);

        // Malformed entry
        const malformed_json = "{\"timestamp\":1234567890,\"message\":,}";
        const crc = std.hash.Crc32.hash(malformed_json);
        try wal.f.writeAll(&std.mem.toBytes(crc));
        try wal.f.writeAll(malformed_json);
        try wal.f.writeAll("\n");
        try wal.f.sync();
    }

    var t = try MemTable.init(a, wal_filename, .{});
    defer t.deinit(a);

    try testing.expectEqual(@as(usize, 1), t.entries.items.len);
    try testing.expectEqualStrings("test log", t.entries.items[0].message);
}

fn cleanupTestWalFile(filename: []const u8) void {
    std.fs.cwd().deleteFile(filename) catch |err| {
        std.log.warn("Unable to cleanup the wal file: {s}, caused by: {}", .{ filename, err });
    };
}
