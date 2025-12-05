// Copyright (c) 2025 Vic Lau
// Licensed under the MIT License

const std = @import("std");
const zbor = @import("zbor");
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub var timestamp_fn: *const fn () i64 = std.time.milliTimestamp;

// TODO future: any measurement library available?
pub var tu_push: i128 = 0;
pub var cnt_push: i128 = 0;

pub var tu_finish: i128 = 0;
pub var cnt_finish: i128 = 0;

/// Allocators are passed explicitly to enable arena-based ownership (e.g., in MemTable), reducing global state while allowing future allocator swaps for optimization.
pub const LogEntry = struct {

    // server timestamp in millis
    timestamp: u64,

    // TODO future: build indices on source_ts
    // source timestamp in millis
    source_ts: u64,

    message: []const u8,

    metadata: ?std.json.Value = null,

    // client code or agent should stick with 1
    version: u8,

    /// Initializes a LogEntry with the source timestamp, message, and optional metadata.
    /// The `message` and `metadata_json` slices must outlive the LogEntry (or the arena's lifetime),
    /// as they are stored by reference. For safety and simplicity, they should be allocated by `arena`
    /// (e.g., via `arena.dupe` or `std.json.Stringify.valueAlloc`), as the arena typically manages LogEntry
    /// lifetimes in MemTable, resetting on flush to free all memory.
    pub fn init(arena: Allocator, source_ts: u64, message: []const u8, metadata_json: ?[]const u8) !LogEntry {
        // Why arena is used?
        //
        // For efficient memory management, this function implies the caller site passes duplicated message and
        // metadata_json slices. Thus don't duplicate any more. The created entry is intended to be appended to
        // `Memtable.entries` (which is managed by an arena). And Memtable' arena fully controlls the entries.
        //
        // Typically, Memtable frees memory of all entries on each flush cycle, efficiently. There is no need to
        // duplicate anything before flushing.

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
            .source_ts = source_ts,
            .message = message,
            .metadata = metadata,
            .version = 1,
        };
    }

    /// Serializes the LogEntry to JSON, using `allocator` for the returned slice.
    ///
    /// Caller owns the returned memory.
    pub fn serJson(self: *const LogEntry, allocator: Allocator) ![]u8 {
        // Any allocator is fine, as the result of `serJson` is usually used when written to a file or sent over the
        // network.

        return try std.json.Stringify.valueAlloc(
            allocator,
            self,

            // reduce serialized memory by omitting null optional fields,
            // `metadata` in fact
            .{ .emit_null_optional_fields = false },
        );
    }

    /// Deserializes a JSON string into a LogEntry, using `arena` for allocations.
    ///
    /// The `serialized` slice must remain valid until the next `MemTable.flush`,
    /// as LogEntry stores references to its contents. Typically, `arena` is the
    /// MemTable's arena, which manages the lifecycle of deserialized entries.
    pub fn deserJson(arena: Allocator, serialized: []const u8) !LogEntry {
        // Why is arena used?
        // `deserJson` is just another form of instantiation.

        return try std.json.parseFromSliceLeaky(
            LogEntry,
            arena,
            serialized,
            .{},
        );
    }

    /// Serializes the LogEntry to CBOR format, using `allocator` for the returned slice.
    /// Metadata is currently serialized as a JSON string within the CBOR map.
    ///
    /// Caller owns the returned memory.
    pub fn encodeCbor(self: *const @This(), allocator: Allocator) ![]u8 {
        var b = try zbor.Builder.withType(allocator, .Map);

        const x = std.time.nanoTimestamp();

        try b.pushTextString("timestamp");
        try b.pushInt(@intCast(self.timestamp));

        try b.pushTextString("source_ts");
        try b.pushInt(@intCast(self.source_ts));

        try b.pushTextString("message");
        try b.pushByteString(self.message);

        if (self.metadata) |m| {
            // TODO now: encode from JSON to CBOR recursively ?
            // const m_json = try std.json.Stringify.valueAlloc(allocator, m, .{});
            // defer allocator.free(m_json);

            try b.pushTextString("metadata");

            try b.enter(.Map);

            try b.pushTextString("level");
            try b.pushByteString(m.object.get("level").?.string);

            try b.leave();

            // try b.pushByteString(m_json);
        }

        try b.pushTextString("version");
        try b.pushInt(self.version);

        tu_push += std.time.nanoTimestamp() - x;
        cnt_push += 1;

        const y = std.time.nanoTimestamp();
        const result = try b.finish();
        tu_finish += std.time.nanoTimestamp() - y;
        cnt_finish += 1;

        return result;
    }

    /// Deserializes a CBOR-encoded slice into a LogEntry, using `arena` for allocations.
    ///
    /// The `encoded` slice must remain valid until the next `MemTable.flush`,
    /// as LogEntry stores references to its contents. Typically, `arena` is the
    /// MemTable's arena, which manages the lifecycle of deserialized entries.
    pub fn decodeCbor(arena: Allocator, encoded: []const u8) !@This() {
        var timestamp: ?u64 = null;
        var source_ts: ?u64 = null;
        var message: ?[]const u8 = null;
        var metadata: ?std.json.Value = null;
        var version: ?u8 = null;

        const di = try zbor.DataItem.new(encoded);
        var map_iter = di.map() orelse return error.ExpectedMap;
        while (map_iter.next()) |pair| {
            const key = pair.key.string() orelse continue;

            if (std.mem.eql(u8, key, "timestamp")) {
                const val = pair.value.int() orelse return error.InvalidTimestamp;
                timestamp = @intCast(val);
            } else if (std.mem.eql(u8, key, "source_ts")) {
                const val = pair.value.int() orelse return error.InvalidSourceTs;
                source_ts = @intCast(val);
            } else if (std.mem.eql(u8, key, "message")) {
                message = pair.value.string() orelse return error.InvalidMessage;
            } else if (std.mem.eql(u8, key, "metadata")) {
                // TODO now: decode from CBOR to JSON recursively ?
                var o = std.json.ObjectMap.init(arena);

                var m_iter = pair.value.map() orelse unreachable;
                while (m_iter.next()) |m_pair| {
                    try o.put(m_pair.key.string() orelse unreachable, std.json.Value{ .string = m_pair.value.string() orelse unreachable });
                }

                metadata = std.json.Value{ .object = o };

                // const val = pair.value.string() orelse return error.InvalidMetadata;
                // metadata = try std.json.parseFromSliceLeaky(std.json.Value, arena, val, .{});

            } else if (std.mem.eql(u8, key, "version")) {
                const val = pair.value.int() orelse return error.InvalidVersion;
                version = @intCast(val);
            }
        }

        return LogEntry{
            .timestamp = timestamp orelse return error.MissingTimestamp,
            .source_ts = source_ts orelse return error.MissingSourceTs,
            .message = message orelse return error.MissingMessage,
            .metadata = metadata,
            .version = version orelse return error.MissingVersion,
        };
    }

    pub fn clone(self: *const LogEntry, arena: Allocator) !LogEntry {
        // Why is arena used?
        // Clone is just another form of instantiation.

        const owned_message = try arena.dupe(u8, self.message);
        errdefer arena.free(owned_message);

        var owned_metadata: ?std.json.Value = null;
        if (self.metadata) |m| {
            owned_metadata = try std.json.parseFromValueLeaky(std.json.Value, arena, m, .{});
        }

        return LogEntry{
            .timestamp = self.timestamp,
            .source_ts = self.source_ts,
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

    const result = LogEntry.init(testing.allocator, 1762072995675, "test log", null);
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

    const entry = try LogEntry.init(allocator, 1762072995675, "test log", null);

    const s = try entry.serJson(t_allocator);
    defer t_allocator.free(s);

    try testing.expectEqualStrings(
        "{\"timestamp\":123456789,\"source_ts\":1762072995675,\"message\":\"test log\",\"version\":1}",
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
        1762072995675,
        "INFO | test log",
        "{\"level\": \"INFO\"}",
    );

    const s = try entry.serJson(t_allocator);
    defer t_allocator.free(s);

    try testing.expectEqualStrings(
        "{\"timestamp\":123456789,\"source_ts\":1762072995675,\"message\":\"INFO | test log\",\"metadata\":{\"level\":\"INFO\"},\"version\":1}",
        s,
    );

    // Reset timestamp_fn
    timestamp_fn = borrowed_fn;
}

test "deserWithoutMetadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const entry_json = "{\"timestamp\":123456789,\"source_ts\":1762072995675,\"message\":\"INFO | test log\",\"version\":1}";
    const entry = try LogEntry.deserJson(allocator, entry_json);

    try testing.expectEqual(@as(u64, 123456789), entry.timestamp);
    try testing.expectEqual(@as(u64, 1762072995675), entry.source_ts);
    try testing.expectEqualStrings("INFO | test log", entry.message);
    try testing.expectEqual(@as(?std.json.Value, null), entry.metadata);
    try testing.expectEqual(@as(u8, 1), entry.version);
}

test "deserWithNullMetadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const entry_json = "{\"timestamp\":123456789,\"source_ts\":1762072995675,\"message\":\"INFO | test log\",\"metadata\":null,\"version\":1}";
    const entry = try LogEntry.deserJson(allocator, entry_json);

    try testing.expectEqual(@as(u64, 123456789), entry.timestamp);
    try testing.expectEqual(@as(u64, 1762072995675), entry.source_ts);
    try testing.expectEqualStrings("INFO | test log", entry.message);
    try testing.expectEqual(@as(?std.json.Value, null), entry.metadata);
    try testing.expectEqual(@as(u8, 1), entry.version);
}

test "deserWithMetadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const entry_json = "{\"timestamp\":123456789,\"source_ts\":1762072995675,\"message\":\"INFO | test log\",\"metadata\":{\"level\":\"INFO\"},\"version\":1}";
    const entry = try LogEntry.deserJson(allocator, entry_json);

    try testing.expectEqual(@as(u64, 123456789), entry.timestamp);
    try testing.expectEqual(@as(u64, 1762072995675), entry.source_ts);
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
        .data = "{\"timestamp\":123456789,\"source_ts\":1762072995675,\"message\":\"INFO | test log\",\"metadata\":{\"level\":\"INFO\"},\"version\":1}",
    });

    defer std.fs.cwd().deleteFile(filename) catch |err| {
        std.log.warn("Unable to cleanup the file: {s}, caused by: {}", .{ filename, err });
    };

    const file_content = try std.fs.cwd().readFileAlloc(t_allocator, filename, 128);
    defer t_allocator.free(file_content);

    const entry = try LogEntry.deserJson(allocator, file_content);

    try testing.expectEqualStrings("INFO | test log", entry.message);
    try testing.expectEqualStrings("INFO", entry.metadata.?.object.get("level").?.string);
}

test "deserMissingRequiredFields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const entry_json = "{\"version\":1}";
    const result = LogEntry.deserJson(allocator, entry_json);

    try testing.expectError(std.json.ParseFromValueError.MissingField, result);
}

test "deserInvalidJSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const entry_json = "{\"timestamp\":123456789,\"source_ts\":1762072995675,\"message\":\"INFO | test log\",\"metadata\":{invalid},\"version\":1}";
    const result = LogEntry.deserJson(allocator, entry_json);

    try testing.expectError(error.SyntaxError, result);
}

test "cloneWithoutMetadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const entry = try LogEntry.init(allocator, 1762072995675, "test log", null);

    const cloned = try entry.clone(allocator);

    try testing.expectEqualStrings("test log", cloned.message);
    try testing.expect(cloned.metadata == null);
}

test "cloneWithMetadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const entry = try LogEntry.init(allocator, 1762072995675, "test log", "{\"level\":\"INFO\"}");

    const cloned = try entry.clone(allocator);

    try testing.expectEqualStrings("test log", cloned.message);
    try testing.expect(cloned.metadata != null);

    if (cloned.metadata) |m| {
        try testing.expectEqualStrings("INFO", m.object.get("level").?.string);
    }
}

test "cbor encode and decode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // without metadata
    {
        const entry = try LogEntry.init(arena.allocator(), 1762072995675, "test log", null);

        const encoded = try entry.encodeCbor(testing.allocator);
        defer testing.allocator.free(encoded);

        const decoded = try LogEntry.decodeCbor(arena.allocator(), encoded);

        try std.testing.expectEqual(1762072995675, decoded.source_ts);
        try std.testing.expectEqualStrings("test log", decoded.message);
        try std.testing.expectEqual(@as(u8, 1), decoded.version);
    }

    // with metadata
    {
        const entry = try LogEntry.init(arena.allocator(), 1762072995675, "test log", "{\"level\":\"INFO\"}");

        const encoded = try entry.encodeCbor(testing.allocator);
        defer testing.allocator.free(encoded);

        const decoded = try LogEntry.decodeCbor(arena.allocator(), encoded);

        try std.testing.expect(decoded.metadata != null);
        try std.testing.expectEqualStrings("INFO", decoded.metadata.?.object.get("level").?.string);
    }
}

// TODO future: add edge cases for cbor
