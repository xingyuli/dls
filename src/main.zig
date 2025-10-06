// Copyright (c) 2025 Vic Lau
// Licensed under the MIT License

const std = @import("std");
const MemTable = @import("./memtable.zig").MemTable;
const Server = @import("./server.zig").Server;

// TODO update to 0.15.1
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const allocator = gpa.allocator();

    var memtable = try MemTable.init(allocator, "log.wal", .{});
    defer memtable.deinit();

    const address = "127.0.0.1";
    const port = 5260;

    var server = try Server.init(allocator, &memtable, address, port);
    defer server.deinit();

    std.log.info("Server running on {s}:{d}", .{ address, port });
    try server.serve();
}
