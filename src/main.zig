const std = @import("std");
const model = @import("./model.zig");

pub fn main() !void {
    std.debug.print("Hello, {s}!\n", .{"DLS"});
}
