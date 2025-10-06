// Copyright (c) 2025 Vic Lau
// Licensed under the MIT License

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub var timestamp_fn: *const fn () i64 = std.time.milliTimestamp;

/// Allocators are passed explicitly to enable arena-based ownership (e.g., in MemTable), reducing global state while allowing future allocator swaps for optimization.
pub const LogEntry = struct {

    // milli ts
    timestamp: u64,

    message: []const u8,

    // TODO future: store source ts in metadata
    // `deser` relies on a default value for missing field
    metadata: ?std.json.Value = null,

    // client code or agent should stick with 1
    version: u8,

    /// Initializes a LogEntry with the current timestamp, message, and optional metadata.
    /// The `message` and `metadata_json` slices must outlive the LogEntry (or the arena's lifetime),
    /// as they are stored by reference. For safety and simplicity, they should be allocated by `arena`
    /// (e.g., via `arena.dupe` or `std.json.stringifyAlloc`), as the arena typically manages LogEntry
    /// lifetimes in MemTable, resetting on flush to free all memory.
    pub fn init(arena: Allocator, message: []const u8, metadata_json: ?[]const u8) !LogEntry {
        const ts_i64 = timestamp_fn();
        if (ts_i64 < 0) {
            // Handle pre-1970 timestamps
            return error.InvalidTimestamp;
        }

        const ts_u64 = @as(u64, @intCast(ts_i64));

        var metadata: ?std.json.Value = null;
        if (metadata_json) |it| {
            metadata = try std.json.parseFromSliceLeaky(std.json.Value, arena, it, .{});
        }

        return LogEntry{
            .timestamp = ts_u64,
            .message = message,
            .metadata = metadata,
            .version = 1,
        };
    }

    /// Serializes the LogEntry to JSON, using `allocator` for the returned slice.
    /// Call owns the returned memory.
    pub fn ser(self: *const LogEntry, allocator: Allocator) ![]u8 {
        var out = std.ArrayList(u8).init(allocator);
        defer out.deinit();

        try std.json.stringify(
            self,

            // reduce serialized memory by omiting null optional fields,
            // `metadata` in fact
            .{ .emit_null_optional_fields = false },

            out.writer(),
        );

        return try out.toOwnedSlice();
    }

    /// Deserializes a JSON string into a LogEntry, using `arena` for allocations.
    /// The `serialized` slice must remain valid until the next `MemTable.flush`,
    /// as LogEntry stores references to its contents. Typically, `arena` is the
    /// MemTable's arena, which manages the lifecycle of deserialized entries.
    pub fn deser(arena: Allocator, serialized: []const u8) !LogEntry {
        return try std.json.parseFromSliceLeaky(
            LogEntry,
            arena,
            serialized,
            .{},
        );
    }

    pub fn clone(self: *const LogEntry, arena: Allocator) !LogEntry {
        const owned_message = try arena.dupe(u8, self.message);
        errdefer arena.free(owned_message);

        var owned_metadata: ?std.json.Value = null;
        if (self.metadata) |m| {
            owned_metadata = try std.json.parseFromValueLeaky(std.json.Value, arena, m, .{});
        }

        return LogEntry{
            .timestamp = self.timestamp,
            .message = owned_message,
            .metadata = owned_metadata,
            .version = self.version,
        };
    }
};

test "initInvalidTimestamp" {
    // Mock timestamp_fn
    const mock_fn = struct {
        fn mock() i64 {
            return -1;
        }
    }.mock;
    const borrowed_fn = timestamp_fn;
    timestamp_fn = mock_fn;

    const result = LogEntry.init(testing.allocator, "test log", null);
    try testing.expectError(error.InvalidTimestamp, result);

    // Reset timestamp_fn
    timestamp_fn = borrowed_fn;
}

test "serWithoutMetadata" {
    const t_allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    // Mock timestamp_fn
    const mock_fn = struct {
        fn mock() i64 {
            return 123456789;
        }
    }.mock;
    const borrowed_fn = timestamp_fn;
    timestamp_fn = mock_fn;

    const entry = try LogEntry.init(allocator, "test log", null);

    const s = try entry.ser(t_allocator);
    defer t_allocator.free(s);

    try testing.expectEqualStrings(
        "{\"timestamp\":123456789,\"message\":\"test log\",\"version\":1}",
        s,
    );

    // Reset timestamp_fn
    timestamp_fn = borrowed_fn;
}

test "serWithMetadata" {
    const t_allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    // Mock timestamp_fn
    const mock_fn = struct {
        fn mock() i64 {
            return 123456789;
        }
    }.mock;
    const borrowed_fn = timestamp_fn;
    timestamp_fn = mock_fn;

    const entry = try LogEntry.init(
        allocator,
        "INFO | test log",
        "{\"level\": \"INFO\"}",
    );

    const s = try entry.ser(t_allocator);
    defer t_allocator.free(s);

    try testing.expectEqualStrings(
        "{\"timestamp\":123456789,\"message\":\"INFO | test log\",\"metadata\":{\"level\":\"INFO\"},\"version\":1}",
        s,
    );

    // Reset timestamp_fn
    timestamp_fn = borrowed_fn;
}

test "deserWithoutMetadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const entry_json = "{\"timestamp\":123456789,\"message\":\"INFO | test log\",\"version\":1}";
    const entry = try LogEntry.deser(allocator, entry_json);

    try testing.expectEqual(@as(u64, 123456789), entry.timestamp);
    try testing.expectEqualStrings("INFO | test log", entry.message);
    try testing.expectEqual(@as(?std.json.Value, null), entry.metadata);
    try testing.expectEqual(@as(u8, 1), entry.version);
}

test "deserWithNullMetadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const entry_json = "{\"timestamp\":123456789,\"message\":\"INFO | test log\",\"metadata\":null,\"version\":1}";
    const entry = try LogEntry.deser(allocator, entry_json);

    try testing.expectEqual(@as(u64, 123456789), entry.timestamp);
    try testing.expectEqualStrings("INFO | test log", entry.message);
    try testing.expectEqual(@as(?std.json.Value, null), entry.metadata);
    try testing.expectEqual(@as(u8, 1), entry.version);
}

test "deserWithMetadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const entry_json = "{\"timestamp\":123456789,\"message\":\"INFO | test log\",\"metadata\":{\"level\":\"INFO\"},\"version\":1}";
    const entry = try LogEntry.deser(allocator, entry_json);

    try testing.expectEqual(@as(u64, 123456789), entry.timestamp);
    try testing.expectEqualStrings("INFO | test log", entry.message);

    try testing.expect(entry.metadata != null);
    if (entry.metadata) |m| {
        try testing.expect(m == .object);
        try testing.expectEqualStrings("INFO", m.object.get("level").?.string);
    }

    try testing.expectEqual(@as(u8, 1), entry.version);
}

test "deserFromFile" {
    const t_allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const filename = "test_model_deserFromFile.tmp";
    try std.fs.cwd().writeFile(.{
        .sub_path = filename,
        .data = "{\"timestamp\":123456789,\"message\":\"INFO | test log\",\"metadata\":{\"level\":\"INFO\"},\"version\":1}",
    });

    defer std.fs.cwd().deleteFile(filename) catch |err| {
        std.log.warn("Unable to cleanup the file: {s}, caused by: {}", .{ filename, err });
    };

    const file_content = try std.fs.cwd().readFileAlloc(t_allocator, filename, 100);
    defer t_allocator.free(file_content);

    const entry = try LogEntry.deser(allocator, file_content);

    try testing.expectEqualStrings("INFO | test log", entry.message);
    try testing.expectEqualStrings("INFO", entry.metadata.?.object.get("level").?.string);
}

test "deserMissingRequiredFields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const entry_json = "{\"version\":1}";
    const result = LogEntry.deser(allocator, entry_json);

    try testing.expectError(std.json.ParseFromValueError.MissingField, result);
}

test "deserInvalidJSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const entry_json = "{\"timestamp\":123456789,\"message\":\"INFO | test log\",\"metadata\":{invalid},\"version\":1}";
    const result = LogEntry.deser(allocator, entry_json);

    try testing.expectError(error.SyntaxError, result);
}

test "cloneWithoutMetadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const entry = try LogEntry.init(allocator, "test log", null);

    const cloned = try entry.clone(allocator);

    try testing.expectEqualStrings("test log", cloned.message);
    try testing.expect(cloned.metadata == null);
}

test "cloneWithMetadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const entry = try LogEntry.init(allocator, "test log", "{\"level\":\"INFO\"}");

    const cloned = try entry.clone(allocator);

    try testing.expectEqualStrings("test log", cloned.message);
    try testing.expect(cloned.metadata != null);

    if (cloned.metadata) |m| {
        try testing.expectEqualStrings("INFO", m.object.get("level").?.string);
    }
}
