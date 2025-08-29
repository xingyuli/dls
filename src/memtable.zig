const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const LogEntry = @import("model.zig").LogEntry;

pub const MemTable = struct {
    entries: std.ArrayList(LogEntry),

    pub fn init(allocator: Allocator) MemTable {
        return MemTable{
            .entries = std.ArrayList(LogEntry).init(allocator),
        };
    }

    pub fn deinit(self: *MemTable, allocator: Allocator) void {
        for (self.entries.items) |*it| {
            it.deinit(allocator);
        }
        self.entries.deinit();
    }

    /// Appends a log entry to the memtable.
    pub fn writeLog(self: *MemTable, entry: LogEntry) !void {
        try self.entries.append(entry);
    }

    /// Reads log entries within the specified time range [start_ts, end_ts].
    /// Returns an array of log entries that fall within the range.
    pub fn readLog(self: *const MemTable, start_ts: u64, end_ts: u64) ![]const LogEntry {
        var result = std.ArrayList(LogEntry).init(self.entries.allocator);
        defer result.deinit();

        for (self.entries.items) |it| {
            if (it.timestamp >= start_ts and it.timestamp <= end_ts) {
                try result.append(it);
            }
        }

        return try result.toOwnedSlice();
    }
};

test "writeAndReadLog" {
    const a = testing.allocator;

    var t = MemTable.init(a);
    defer t.deinit(a);

    const entry1 = try LogEntry.init(a, "test log 1", null);
    const entry2 = try LogEntry.init(a, "test log 2", null);
    try t.writeLog(entry1);
    try t.writeLog(entry2);

    try testing.expectEqual(@as(usize, 2), t.entries.items.len);

    const logs = try t.readLog(0, std.math.maxInt(u64));
    defer a.free(logs);

    try testing.expectEqual(@as(usize, 2), logs.len);
    try testing.expectEqualStrings("test log 1", logs[0].message);
    try testing.expectEqualStrings("test log 2", logs[1].message);
}

test "readEmptyTimeRange" {
    const a = testing.allocator;

    var t = MemTable.init(a);
    defer t.deinit(a);

    try t.writeLog(try LogEntry.init(a, "test log", null));

    const logs = try t.readLog(100, 100);
    defer a.free(logs);

    try testing.expectEqual(@as(usize, 0), logs.len);
}

test "readInvalidTimeRange" {
    const a = testing.allocator;

    var t = MemTable.init(a);
    defer t.deinit(a);

    try t.writeLog(try LogEntry.init(a, "test log", null));

    const logs = try t.readLog(200, 100);
    defer a.free(logs);

    try testing.expectEqual(@as(usize, 0), logs.len);
}

test "writeManyLogs" {
    const a = testing.allocator;

    var t = MemTable.init(a);
    defer t.deinit(a);

    const entry_count = 10_000;

    var timer = try std.time.Timer.start();

    // Measure write time
    const write_start_ns = timer.read();
    for (0..entry_count) |i| {
        const message = try std.fmt.allocPrint(a, "INFO | test log {d}", .{i});
        defer a.free(message);

        try t.writeLog(try LogEntry.init(a, message, "{\"level\":\"INFO\"}"));
    }
    const write_time_ns = timer.read() - write_start_ns;

    try testing.expectEqual(@as(usize, entry_count), t.entries.items.len);

    // Measure read time
    const read_start_ns = timer.read();
    const logs = try t.readLog(0, std.math.maxInt(u64));
    defer a.free(logs);
    const read_time_ns = timer.read() - read_start_ns;

    try testing.expectEqual(@as(usize, entry_count), logs.len);

    // Log performance metrics (in nanoseconds)
    //
    // example result on my M1 laptop:
    //   writeManyLogs: wrote 10000 entries in 585515041 ns, read in 1236500 ns i.e., 585ms write, 1.2ms read
    //   writeManyLogs: wrote 10000 entries in 582988125 ns, read in 1116459 ns i.e., 582ms write, 1.1ms read
    //
    // write:read ratio is about 500:1
    //
    // analysis: writes are slower due to LogEntry.init allocations (message, metadata)
    std.debug.print("writeManyLogs: wrote {} entries in {} ns, read in {} ns\n", .{
        entry_count,
        write_time_ns,
        read_time_ns,
    });

    // Loose performance check (with write:read ratio of 50:1)
    try testing.expect(write_time_ns < 1_000_000_000); // 1s
    try testing.expect(read_time_ns < 20_000_000); // 20ms
}
