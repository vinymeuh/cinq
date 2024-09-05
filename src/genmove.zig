// SPDX-FileCopyrightText: 2024 vinymeuh
// SPDX-License-Identifier: MIT
const std = @import("std");

const go = @import("go.zig");

pub const ResponseTag = enum(u1) {
    vertex,
    resign,
};

pub const Response = union(ResponseTag) {
    vertex: go.Vertex,
    resign,

    pub inline fn asStr(self: Response, buf: []u8) []u8 {
        std.debug.assert(buf.len >= 6);
        if (self == .resign) {
            @memcpy(buf, "resign");
            return buf[0..6];
        }
        return self.vertex.asStr(buf);
    }
};

pub const RandomBot = struct {
    seed: u64,
    prng: std.Random.Xoshiro256,

    pub fn init(init_s: u64) RandomBot {
        return RandomBot{
            .seed = init_s,
            .prng = std.Random.DefaultPrng.init(init_s),
        };
    }

    pub fn play(self: *RandomBot, board: *go.Board, color: go.Color) Response {
        var legal_xpoints: [go.Board.MAX_SIZE * go.Board.MAX_SIZE]usize = undefined;
        var legal_count: usize = 0;

        for (1..board.size + 1) |row| {
            for (1..board.size + 1) |col| {
                const xpoint = col + row * board.xsize;
                const vertex = go.Vertex{ .play = .{ .col = col, .row = row } };
                if (board.isLegal(color, vertex) and !board.isAnEye(color, vertex.play)) {
                    legal_xpoints[legal_count] = xpoint;
                    legal_count += 1;
                }
            }
        }

        if (legal_count == 0) {
            return Response{ .vertex = .pass };
        } else if (legal_count == 1) {
            const xpoint = legal_xpoints[0];
            return Response{ .vertex = go.Vertex{ .play = board.asCoordinate(xpoint) } };
        } else {
            const choice = self.prng.random().uintLessThan(usize, legal_count - 1);
            std.debug.print("choice = {d}, legal_count = {d}\n", .{ choice, legal_count });
            const xpoint = legal_xpoints[choice];
            return Response{ .vertex = go.Vertex{ .play = board.asCoordinate(xpoint) } };
        }
    }
};
