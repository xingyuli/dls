// Copyright (c) 2025 Vic Lau
// Licensed under the MIT License

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const LogEntry = @import("./model.zig").LogEntry;

pub const Wal = struct {
    f: std.fs.File,

    /// Testing-only: simulate append failures
    testing_fail_count: i32 = 0,

    pub fn init(filename: []const u8) !Wal {
        const f = std.fs.cwd().openFile(
            filename,
            .{ .mode = .write_only },
        ) catch |err| switch (err) {
            error.FileNotFound => try std.fs.cwd().createFile(filename, .{}),
            else => return err,
        };

        // ensures append
        try f.seekFromEnd(0);

        return Wal{ .f = f };
    }

    pub fn deinit(self: *const Wal) void {
        self.f.close();
    }

    pub fn append(self: *Wal, allocator: Allocator, entry: *const LogEntry) !void {
        // Simulate failure if testing_fail_count > 0
        if (self.testing_fail_count > 0) {
            self.testing_fail_count -= 1;
            return error.DiskFull;
        }

        const s = try entry.ser(allocator);
        defer allocator.free(s);

        // TODO future `f.writeAll` is deprecated but new std.Io.Writer API is inconvenient

        const crc = std.hash.Crc32.hash(s);
        try self.f.writeAll(&std.mem.toBytes(crc));

        try self.f.writeAll(s);

        // CRITICAL: new line is a must
        try self.f.writeAll("\n");

        // wait for underlying fs completion
        try self.f.sync();
    }

    pub fn setTestingFailCount(self: *Wal, count: i32) void {
        if (!@import("builtin").is_test) @compileError("Testing function used outside tests");
        if (count < 0) @panic("Invalid fail count");
        self.testing_fail_count = count;
    }
};
