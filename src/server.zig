// Copyright (c) 2025 Vic Lau
// Licensed under the MIT License

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Connection = std.net.Server.Connection;
const LogEntry = @import("./model.zig").LogEntry;
const MemTable = @import("./memtable.zig").MemTable;

const ErrorCode = enum {
    request_too_large,
    read_error,
    invalid_json,
    write_log_error,

    // protocol related
    missing_action,
    unknown_action,

    // `write` request
    missing_message,
    message_too_large,

    // `read` request
    missing_start_ts,
    missing_end_ts,
    invalid_start_ts,
    invalid_end_ts,
};

const ProtocolAction = enum {
    write,
    read,

    const all_actions: []const u8 = "write,read";
};

pub const Server = struct {
    allocator: Allocator,
    memtable: *MemTable,
    s: std.net.Server,

    // For manually shutdown
    should_stop: std.atomic.Value(bool),

    // Max buffer size: max_log_entry_write_size + 2KB for JSON overhead
    const max_overhead = 2 * 1024;

    pub fn init(allocator: Allocator, memtable: *MemTable, address: []const u8, port: u16) !Server {
        const addr = try std.net.Address.resolveIp(address, port);
        const server = try addr.listen(.{ .reuse_address = true });

        return Server{
            .allocator = allocator,
            .memtable = memtable,
            .s = server,
            .should_stop = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Server) void {
        self.s.deinit();
    }

    pub fn stop(self: *Server) void {
        self.should_stop.store(true, .release);
    }

    pub fn serve(self: *Server) !void {
        while (!self.should_stop.load(.acquire)) {
            const conn = self.s.accept() catch |err| {
                std.log.warn("Failed to accept connection: {}", .{err});
                std.time.sleep(std.time.ns_per_ms * 100); // Prevent tight loop
                continue;
            };
            defer conn.stream.close();

            std.log.info("New connection from {}", .{conn.address});

            self.handleConnection(conn) catch |err| {
                std.log.warn("Error handling connection from {}: {}", .{ conn.address, err });
            };
        }
    }

    // Messaging Protocol
    //
    // - request
    //   {action:write,message:<str message>,metadata?:<json_obj_str metadata>}
    //   {action:read,start_ts:<u64 start_ts>,end_ts:<u64 end_ts>}
    //
    // - response
    //   {status:error,errmsg:<str message>}
    //   {status:ok,data?:<data>}

    fn handleConnection(self: *Server, conn: Connection) !void {
        const max_buf_size = self.memtable.config.max_log_entry_write_size + max_overhead;

        const reader = conn.stream.reader();

        while (true) {
            const line = reader.readUntilDelimiterOrEofAlloc(
                self.allocator,
                '\n',
                max_buf_size,
            ) catch |err| switch (err) {
                error.StreamTooLong => {
                    std.log.warn("Rejected oversized request (> {d} bytes)", .{max_buf_size});
                    try self.sendErr(conn, .request_too_large, .{ .max_size = max_buf_size, .unit = "byte" });
                    continue;
                },
                error.BrokenPipe, error.ConnectionResetByPeer => {
                    std.log.info("Connection closed by client {}", .{conn.address});
                    break;
                },
                else => {
                    std.log.warn("Read error: {}", .{err});
                    try self.sendErr(conn, .read_error, .{});
                    continue;
                },
            } orelse {
                std.log.info("Connection closed by client {} (empty request)", .{conn.address});
                break;
            };
            defer self.allocator.free(line);

            const trimmed_line = std.mem.trim(u8, line, "\t\n\r");
            if (trimmed_line.len == 0) {
                std.log.info("Ignoring empty or whitespace-only line from {}", .{conn.address});
                continue;
            }

            const request = std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                line,
                .{},
            ) catch |err| {
                std.log.warn("JSON parse error: {}", .{err});
                try self.sendErr(conn, .invalid_json, .{ .message = err });
                continue;
            };
            defer request.deinit();

            const obj = request.value.object;
            const action = obj.get("action") orelse {
                try self.sendErr(conn, .missing_action, .{});
                continue;
            };

            if (std.meta.stringToEnum(ProtocolAction, action.string)) |pa| {
                switch (pa) {
                    .write => try self.handleWriteRequest(conn, obj),
                    .read => try self.handleReadRequest(conn, obj),
                }
            } else {
                std.log.warn("Unknown action: {s}", .{action.string});
                try self.sendErr(
                    conn,
                    .unknown_action,
                    .{ .given_action = action.string, .supported_actions = ProtocolAction.all_actions },
                );
            }
        }
    }

    fn handleWriteRequest(self: *Server, conn: Connection, obj: std.json.ObjectMap) !void {
        const message = obj.get("message") orelse {
            try self.sendErr(conn, .missing_message, .{});
            return;
        };

        if (message.string.len > self.memtable.config.max_log_entry_write_size) {
            try self.sendErr(
                conn,
                .message_too_large,
                .{ .max_size = self.memtable.config.max_log_entry_write_size, .unit = "byte" },
            );
            std.log.warn(
                "Rejected message (size: {d}, max: {d})",
                .{ message.string.len, self.memtable.config.max_log_entry_write_size },
            );
            return;
        }

        // TODO future: source_ts

        const metadata = obj.get("metadata");

        const entry_arena = self.memtable.entries.allocator;

        const entry = try LogEntry.init(
            entry_arena,
            try entry_arena.dupe(u8, message.string),
            if (metadata) |m| try std.json.stringifyAlloc(entry_arena, m, .{}) else null,
        );

        self.memtable.writeLog(entry) catch |err| {
            std.log.warn("Failed to write log: {}", .{err});
            try self.sendErr(conn, .write_log_error, .{ .message = err });
            return;
        };

        try conn.stream.writeAll("{\"status\":\"ok\"}\n");
    }

    fn handleReadRequest(self: *Server, conn: Connection, obj: std.json.ObjectMap) !void {
        const start_ts = obj.get("start_ts") orelse {
            try self.sendErr(conn, .missing_start_ts, .{});
            return;
        };

        const end_ts = obj.get("end_ts") orelse {
            try self.sendErr(conn, .missing_end_ts, .{});
            return;
        };

        const start_ts_u64 = parseU64(start_ts) catch |err| {
            try self.sendErr(conn, .invalid_start_ts, .{ .message = err });
            return;
        };

        const end_ts_u64 = parseU64(end_ts) catch |err| {
            try self.sendErr(conn, .invalid_end_ts, .{ .message = err });
            return;
        };

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const allocator = arena.allocator();

        const logs = try self.memtable.readLog(
            allocator,
            start_ts_u64,
            end_ts_u64,
        );

        var response = std.ArrayList(u8).init(allocator);

        // TODO future: for large ranges, this could OOM the arena; consider streaming (write array open, per-entry
        //   stringify, close).
        try std.json.stringify(.{ .status = "ok", .data = logs }, .{}, response.writer());
        try conn.stream.writeAll(response.items);
        try conn.stream.writeAll("\n");
    }

    fn parseU64(v: std.json.Value) !u64 {
        return switch (v) {
            .integer => if (v.integer >= 0) @as(u64, @intCast(v.integer)) else error.InvalidU64,
            .number_string => std.fmt.parseInt(u64, v.number_string, 10) catch error.InvalidU64,
            .string => std.fmt.parseInt(u64, v.string, 10) catch error.InvalidU64,
            else => error.InvalidU64,
        };
    }

    fn sendErr(self: *Server, conn: Connection, err: ErrorCode, detail: anytype) !void {
        const has_any_detail = @typeInfo(@TypeOf(detail)).@"struct".fields.len > 0;

        const resp = try std.json.stringifyAlloc(
            self.allocator,
            if (has_any_detail) .{ .status = "error", .errcode = @tagName(err), .detail = detail } else .{ .status = "error", .errcode = @tagName(err) },
            .{},
        );
        defer self.allocator.free(resp);

        try conn.stream.writeAll(resp);
        try conn.stream.writeAll("\n");
    }
};

test "serverWriteAndRead" {
    const a = std.testing.allocator;
    const wal_filename = "test_server_serverWriteAndRead.wal";

    var memtable = try MemTable.init(a, wal_filename, .{});
    defer memtable.deinit();
    defer std.fs.cwd().deleteFile(wal_filename) catch {};

    var server = try Server.init(a, &memtable, "127.0.0.1", 5260);
    defer server.deinit();

    const server_thread = try std.Thread.spawn(.{}, Server.serve, .{&server});
    defer server_thread.join();

    // Give server time to start listening
    std.time.sleep(std.time.ns_per_ms * 100);

    const addr = try std.net.Address.resolveIp("127.0.0.1", 5260);
    var conn = try std.net.tcpConnectToAddress(addr);
    defer conn.close();

    // Helper to send request and read response line
    const SendRecvHelper = struct {
        conn: std.net.Stream,
        allocator: Allocator,

        const Self = @This();

        pub fn sendRecv(self: *Self, req: []const u8) ![]u8 {
            try self.conn.writeAll(req);
            const result = try self.conn.reader().readUntilDelimiterOrEofAlloc(self.allocator, '\n', 2048);
            return result.?;
        }
    };
    var helper = SendRecvHelper{ .conn = conn, .allocator = a };

    // Test client: Write
    const write_req = "{\"action\":\"write\",\"message\":\"test log\",\"metadata\":{\"level\":\"INFO\"}}\n";
    const write_resp = try helper.sendRecv(write_req);
    defer a.free(write_resp);

    try testing.expect(std.mem.containsAtLeast(u8, write_resp, 1, "{\"status\":\"ok\"}"));

    // Test client: read (catches the log just written)
    const now_ms = @as(u64, @intCast(std.time.milliTimestamp()));
    const read_req = try std.fmt.allocPrint(
        a,
        "{{\"action\":\"read\",\"start_ts\":0,\"end_ts\":{d}}}\n",
        .{now_ms + 1000},
    );
    defer a.free(read_req);

    const read_resp_raw = try helper.sendRecv(read_req);
    defer a.free(read_resp_raw);

    const read_resp = try std.json.parseFromSlice(std.json.Value, a, read_resp_raw, .{});
    defer read_resp.deinit();

    const obj = read_resp.value.object;
    try testing.expectEqualStrings("ok", obj.get("status").?.string);

    const data = obj.get("data").?.array;
    try testing.expectEqual(@as(usize, 1), data.items.len);

    const first_log = data.items[0].object;
    try testing.expectEqualStrings("test log", first_log.get("message").?.string);
    try testing.expectEqualStrings("INFO", first_log.get("metadata").?.object.get("level").?.string);

    // Graceful stop
    server.stop();
}
