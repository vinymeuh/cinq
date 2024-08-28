// SPDX-FileCopyrightText: 2024 vinymeuh
// SPDX-License-Identifier: MIT
const std = @import("std");

const go = @import("go.zig");
const genmove = @import("genmove.zig");

board: go.Board,
allocator: std.mem.Allocator,
out: std.fs.File.Writer,
bot: genmove.RandomBot,

move_history: std.ArrayList(Move),

const NAME = "cinq";
const VERSION = "0.0";
const PROTOCOL_VERSION = 2;

const Self = @This();

pub fn init(allocator: std.mem.Allocator) Self {
    return Self{
        .board = undefined,
        .allocator = allocator,
        .out = std.io.getStdOut().writer(),
        .bot = genmove.RandomBot.init(),
        .move_history = undefined,
    };
}

pub fn deinit(self: *Self) void {
    self.board.deinit();
    self.move_history.deinit();
}

const CommandName = enum {
    boardsize,
    clear_board,
    genmove,
    is_legal,
    known_command,
    komi,
    list_commands,
    name,
    play,
    protocol_version,
    quit,
    showboard,
    version,
};

pub fn gtploop(self: *Self) !void {
    self.board = try go.Board.create(self.allocator, go.Board.DEFAULT_SIZE);
    self.move_history = try std.ArrayList(Move).initCapacity(self.allocator, 500);

    const stdin = std.io.getStdIn().reader();
    var line_buf = std.ArrayList(u8).init(self.allocator);
    defer line_buf.deinit();

    while (true) {
        stdin.streamUntilDelimiter(line_buf.writer(), '\n', null) catch |err| switch (err) {
            error.EndOfStream => break, // Ctrl+C
            else => unreachable,
        };
        const raw_line = try line_buf.toOwnedSlice();
        defer self.allocator.free(raw_line);

        // discard comments
        if (raw_line.len > 1 and raw_line[0] == '#') continue;
        var tokens = std.mem.tokenizeScalar(u8, raw_line, '#');
        const line = tokens.next() orelse continue;

        // parse command
        tokens = std.mem.tokenizeScalar(u8, line, ' ');
        var token = tokens.next() orelse continue;

        const id = std.fmt.parseUnsigned(usize, token, 10) catch null;
        if (id != null) {
            token = tokens.next() orelse continue;
        }

        const command = std.meta.stringToEnum(CommandName, token) orelse {
            try self.printKo(id, "unknown command", .{});
            continue;
        };

        switch (command) {
            .boardsize => {
                const size = parseArgInt(&tokens) catch {
                    try self.printKo(id, "boardsize not an integer", .{});
                    continue;
                };
                if (size < go.Board.MIN_SIZE or size > go.Board.MAX_SIZE) {
                    try self.printKo(id, "unacceptable size", .{});
                    continue;
                }
                self.board.deinit();
                self.board = try go.Board.create(self.allocator, @intCast(size));
                try self.printOk(id, "", .{});
            },
            .clear_board => {
                self.board.clear();
                try self.printOk(id, "", .{});
            },
            .genmove => {
                const color = parseArgColor(self.allocator, &tokens) catch {
                    try self.printKo(id, "invalid color", .{});
                    continue;
                };
                const resp = self.bot.play(&self.board, color);
                switch (resp) {
                    .vertex => {
                        _ = self.board.play(color, resp.vertex);
                        self.move_history.appendAssumeCapacity(.{ .color = color, .vertex = resp.vertex });
                    },
                    .resign => {},
                }
                var buf: [8]u8 = undefined;
                try self.printOk(id, "{s}", .{resp.asStr(&buf)});
            },
            .is_legal => {
                const color = parseArgColor(self.allocator, &tokens) catch {
                    try self.printKo(id, "invalid color", .{});
                    continue;
                };
                const vertex = parseArgVertex(&tokens) catch {
                    try self.printKo(id, "invalid color or coordinate", .{});
                    continue;
                };
                if (self.board.isLegal(color, vertex)) {
                    try self.printOk(id, "1", .{});
                } else {
                    try self.printOk(id, "0", .{});
                }
            },
            .known_command => {
                _ = parseArgCommandName(&tokens) catch {
                    try self.printOk(id, "false", .{});
                    continue;
                };
                try self.printOk(id, "true", .{});
            },
            .komi => {
                const komi = parseArgFloat(&tokens) catch {
                    try self.printKo(id, "komi not a float", .{});
                    continue;
                };
                self.board.komi = komi;
                try self.printOk(id, "", .{});
            },
            .list_commands => {
                try self.out.writeAll("= ");
                inline for (std.meta.fields(CommandName)) |f| {
                    try self.out.print("{s}\n", .{@typeInfo(CommandName).Enum.fields[f.value].name});
                }
                try self.out.writeAll("\n");
            },
            .name => {
                try self.printOk(id, NAME, .{});
            },
            .play => {
                const color = parseArgColor(self.allocator, &tokens) catch {
                    try self.printKo(id, "invalid color", .{});
                    continue;
                };
                const vertex = parseArgVertex(&tokens) catch {
                    try self.printKo(id, "invalid color or coordinate", .{});
                    continue;
                };

                if (!self.board.play(color, vertex)) {
                    try self.printKo(id, "illegal move", .{});
                }
                self.move_history.appendAssumeCapacity(.{ .color = color, .vertex = vertex });
                try self.printOk(id, "", .{});
            },
            .protocol_version => {
                try self.printOk(id, "{d}", .{PROTOCOL_VERSION});
            },
            .quit => {
                break;
            },
            .showboard => {
                try self.out.writeAll("=\n");
                try self.board.print(self.out);
                if (self.board.komi > 0) {
                    try self.out.print("Komi    : {d:.1}\n", .{self.board.komi});
                }
                try self.out.print("Captures: B={d} W={d}\n", .{ self.board.captures[0], self.board.captures[1] });
                if (self.board.ko()) |ko| {
                    try self.out.print("Ko      : {c}{d})\n", .{ "abcdefghjklmnopqrst"[ko.row], ko.col });
                }
                try self.out.writeAll("\n");
            },
            .version => {
                try self.printOk(id, VERSION, .{});
            },
        }
    }
}

inline fn printOk(self: *Self, id: ?usize, comptime format: []const u8, args: anytype) !void {
    if (format.len > 0) {
        if (id == null) {
            try self.out.print("= " ++ format ++ "\n\n", args);
        } else {
            try self.out.print("={d} ", .{id.?});
            try self.out.print(format ++ "\n\n", args);
        }
    } else {
        if (id == null) {
            try self.out.writeAll("=\n\n");
        } else {
            try self.out.print("={d}\n\n", .{id.?});
        }
    }
}

inline fn printKo(self: *Self, id: ?usize, comptime format: []const u8, args: anytype) !void {
    if (id == null) {
        try self.out.print("? " ++ format ++ "\n\n", args);
    } else {
        try self.out.print("?{d} ", .{id.?});
        try self.out.print(format ++ "\n\n", args);
    }
}

const CommandLineTokens = std.mem.TokenIterator(u8, std.mem.DelimiterType.scalar);

fn parseArgInt(tokens: *CommandLineTokens) !usize {
    const str = tokens.next() orelse {
        return error.InvalidArgument;
    };
    const u = std.fmt.parseUnsigned(usize, str, 10) catch {
        return error.InvalidArgument;
    };
    return u;
}

fn parseArgFloat(tokens: *CommandLineTokens) !f32 {
    const str = tokens.next() orelse {
        return error.InvalidArgument;
    };
    const f = std.fmt.parseFloat(f32, str) catch {
        return error.InvalidArgument;
    };
    return f;
}

fn parseArgCommandName(tokens: *CommandLineTokens) !CommandName {
    const cmd_str = tokens.next() orelse {
        return error.InvalidArgument;
    };
    const cmd = std.meta.stringToEnum(CommandName, cmd_str) orelse {
        return error.InvalidArgument;
    };
    return cmd;
}

const Move = struct {
    color: go.Color,
    vertex: go.Vertex,
};

fn parseArgColor(allocator: std.mem.Allocator, tokens: *CommandLineTokens) !go.Color {
    const color_str = tokens.next() orelse {
        return error.InvalidArgument;
    };
    const lower_str = try std.ascii.allocLowerString(allocator, color_str);
    defer allocator.free(lower_str);
    const color = std.meta.stringToEnum(go.Color, lower_str) orelse {
        return error.InvalidArgument;
    };
    return color;
}

fn parseArgVertex(tokens: *CommandLineTokens) !go.Vertex {
    const vertex_str = tokens.next() orelse {
        return error.InvalidArgument;
    };

    if (std.mem.eql(u8, vertex_str, "pass")) {
        return .pass;
    }

    if (vertex_str.len < 2 or vertex_str.len > 3) {
        return error.InvalidArgument;
    }

    const letter = std.ascii.toLower(vertex_str[0]);
    var col1: usize = undefined;
    if (letter >= 'a' and letter < 'i') {
        col1 = 1 + std.ascii.toLower(letter) - 'a';
    } else if (letter > 'i' and letter <= 't') {
        col1 = std.ascii.toLower(letter) - 'a';
    } else {
        return error.InvalidArgument;
    }
    const col = col1;

    const number = vertex_str[1..];
    const row = std.fmt.parseUnsigned(usize, number, 10) catch {
        return error.InvalidArgument;
    };

    return go.Vertex{ .play = .{ .col = col, .row = row } };
}
