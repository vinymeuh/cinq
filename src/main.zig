// SPDX-FileCopyrightText: 2024 vinymeuh
// SPDX-License-Identifier: MIT
const std = @import("std");

const Engine = @import("Engine.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    var engine = Engine.init(allocator);
    defer engine.deinit();
    engine.gtploop() catch |err| {
        std.debug.print("{}\n", .{err});
    };
}
