// Copyright (c) 2025 Vic Lau
// Licensed under the MIT License

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub var timestamp_fn: *const fn () i64 = std.time.milliTimestamp;

/// Allocators are passing around to functions for these reasons:
/// - reduce memory usage, a pointer to an allocator typically uses 8 bytes on
///   64-bit system
/// - leave possiblity for future optimization, functions can use different
///   allocators for their purporse
pub const LogEntry = struct {

    // milli ts
    timestamp: u64,

    message: []const u8,

    // TODO future: store source ts in metadata
    // TODO next week: use `?std.json.Value` for performance ?
    metadata: ?std.json.Parsed(std.json.Value),

    // client code or agent should stick with 1
    version: u8,

    // Helper struct for serialization/deserialization
    const SerializableLogEntry = struct {
        timestamp: u64,
        message: []const u8,

        // `deser` relies on a default value for missing field
        metadata: ?std.json.Value = null,

        version: u8,
    };

    pub fn init(allocator: Allocator, message: []const u8, metadata_json: ?[]const u8) !LogEntry {
        const ts_i64 = timestamp_fn();
        if (ts_i64 < 0) {
            // Handle pre-1970 timestamps
            return error.InvalidTimestamp;
        }

        const ts_u64 = @as(u64, @intCast(ts_i64));

        const owned_message = try allocator.dupe(u8, message);

        var metadata: ?std.json.Parsed(std.json.Value) = null;
        if (metadata_json) |it| {
            metadata = try std.json.parseFromSlice(std.json.Value, allocator, it, .{});
        }

        return LogEntry{
            .timestamp = ts_u64,
            .message = owned_message,
            .metadata = metadata,
            .version = 1,
        };
    }

    pub fn deinit(self: *const LogEntry, allocator: Allocator) void {
        allocator.free(self.message);
        if (self.metadata) |meta| {
            meta.deinit();
        }
    }

    /// Call ownes the returned memory.
    pub fn ser(self: *const LogEntry, allocator: Allocator) ![]u8 {
        var out = std.ArrayList(u8).init(allocator);
        defer out.deinit();

        const serializable = SerializableLogEntry{
            .timestamp = self.timestamp,
            .message = self.message,
            .metadata = if (self.metadata) |meta| meta.value else null,
            .version = self.version,
        };

        try std.json.stringify(
            serializable,

            // reduce serialized memory by omiting null optional fields,
            // `metadata` in fact
            .{ .emit_null_optional_fields = false },

            out.writer(),
        );

        return try out.toOwnedSlice();
    }

    pub fn deser(allocator: Allocator, serialized: []const u8) !LogEntry {
        const deserialized = try std.json.parseFromSlice(
            SerializableLogEntry,
            allocator,
            serialized,
            .{},
        );
        defer deserialized.deinit();

        const dv = deserialized.value;

        const owned_message = try allocator.dupe(u8, dv.message);

        var owned_metadata: ?std.json.Parsed(std.json.Value) = null;
        if (dv.metadata) |meta| {
            owned_metadata = try cloneMetadata(allocator, meta);
        }

        return LogEntry{
            .timestamp = dv.timestamp,
            .message = owned_message,
            .metadata = owned_metadata,
            .version = dv.version,
        };
    }

    pub fn clone(self: *const LogEntry, allocator: Allocator) !LogEntry {
        const owned_message = try allocator.dupe(u8, self.message);

        var owned_metadata: ?std.json.Parsed(std.json.Value) = null;
        if (self.metadata) |meta| {
            owned_metadata = try cloneMetadata(allocator, meta.value);
        }

        return LogEntry{
            .timestamp = self.timestamp,
            .message = owned_message,
            .metadata = owned_metadata,
            .version = self.version,
        };
    }

    /// rebuild metadata: re-stringify + re-parse to own the memory
    fn cloneMetadata(allocator: Allocator, meta_value: std.json.Value) !std.json.Parsed(std.json.Value) {
        var out = std.ArrayList(u8).init(allocator);
        defer out.deinit();

        try std.json.stringify(meta_value, .{}, out.writer());
        return try std.json.parseFromSlice(std.json.Value, allocator, out.items, .{});
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
    const allocator = testing.allocator;

    // Mock timestamp_fn
    const mock_fn = struct {
        fn mock() i64 {
            return 123456789;
        }
    }.mock;
    const borrowed_fn = timestamp_fn;
    timestamp_fn = mock_fn;

    const entry = try LogEntry.init(allocator, "test log", null);
    defer entry.deinit(allocator);

    const s = try entry.ser(allocator);
    defer allocator.free(s);

    try testing.expectEqualStrings(
        "{\"timestamp\":123456789,\"message\":\"test log\",\"version\":1}",
        s,
    );

    // Reset timestamp_fn
    timestamp_fn = borrowed_fn;
}

test "serWithMetadata" {
    const allocator = testing.allocator;

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
    defer entry.deinit(allocator);

    const s = try entry.ser(allocator);
    defer allocator.free(s);

    try testing.expectEqualStrings(
        "{\"timestamp\":123456789,\"message\":\"INFO | test log\",\"metadata\":{\"level\":\"INFO\"},\"version\":1}",
        s,
    );

    // Reset timestamp_fn
    timestamp_fn = borrowed_fn;
}

test "deserWithoutMetadata" {
    const entry_json = "{\"timestamp\":123456789,\"message\":\"INFO | test log\",\"version\":1}";
    const entry = try LogEntry.deser(testing.allocator, entry_json);
    defer entry.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 123456789), entry.timestamp);
    try testing.expectEqualStrings("INFO | test log", entry.message);
    try testing.expectEqual(@as(?std.json.Parsed(std.json.Value), null), entry.metadata);
    try testing.expectEqual(@as(u8, 1), entry.version);
}

test "deserWithNullMetadata" {
    const entry_json = "{\"timestamp\":123456789,\"message\":\"INFO | test log\",\"metadata\":null,\"version\":1}";
    const entry = try LogEntry.deser(testing.allocator, entry_json);
    defer entry.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 123456789), entry.timestamp);
    try testing.expectEqualStrings("INFO | test log", entry.message);
    try testing.expectEqual(@as(?std.json.Parsed(std.json.Value), null), entry.metadata);
    try testing.expectEqual(@as(u8, 1), entry.version);
}

test "deserWithMetadata" {
    const entry_json = "{\"timestamp\":123456789,\"message\":\"INFO | test log\",\"metadata\":{\"level\":\"INFO\"},\"version\":1}";
    const entry = try LogEntry.deser(testing.allocator, entry_json);
    defer entry.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 123456789), entry.timestamp);
    try testing.expectEqualStrings("INFO | test log", entry.message);

    try testing.expect(entry.metadata != null);
    if (entry.metadata) |meta| {
        try testing.expect(meta.value == .object);
        try testing.expectEqualStrings("INFO", meta.value.object.get("level").?.string);
    }

    try testing.expectEqual(@as(u8, 1), entry.version);
}

test "deserMissingRequiredFields" {
    const entry_json = "{\"version\":1}";
    const result = LogEntry.deser(testing.allocator, entry_json);

    try testing.expectError(std.json.ParseFromValueError.MissingField, result);
}

test "deserInvalidJSON" {
    const entry_json = "{\"timestamp\":123456789,\"message\":\"INFO | test log\",\"metadata\":{invalid},\"version\":1}";
    const result = LogEntry.deser(testing.allocator, entry_json);

    try testing.expectError(error.SyntaxError, result);
}

test "cloneWithoutMetadata" {
    const entry = try LogEntry.init(testing.allocator, "test log", null);
    defer entry.deinit(testing.allocator);

    const cloned = try entry.clone(testing.allocator);
    defer cloned.deinit(testing.allocator);

    try testing.expectEqualStrings("test log", cloned.message);
    try testing.expect(cloned.metadata == null);
}

test "cloneWithMetadata" {
    const entry = try LogEntry.init(
        testing.allocator,
        "test log",
        "{\"level\":\"INFO\"}",
    );
    defer entry.deinit(testing.allocator);

    const cloned = try entry.clone(testing.allocator);
    defer cloned.deinit(testing.allocator);

    try testing.expectEqualStrings("test log", cloned.message);
    try testing.expect(cloned.metadata != null);

    if (cloned.metadata) |meta| {
        try testing.expectEqualStrings("INFO", meta.value.object.get("level").?.string);
    }
}
