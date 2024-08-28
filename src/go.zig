// SPDX-FileCopyrightText: 2024 vinymeuh
// SPDX-License-Identifier: MIT
const std = @import("std");

pub const Color = enum(u1) {
    black,
    white,

    pub inline fn opponent(self: Color) Color {
        return @enumFromInt(@intFromEnum(self) ^ 1);
    }

    pub inline fn asUsize(self: Color) usize {
        return @intFromEnum(self);
    }

    pub inline fn asStr(self: Color) []const u8 {
        switch (self) {
            .black => return "black",
            .white => return "white",
        }
    }
};

pub const Coordinate = struct {
    col: usize, // must be in [1..Board.size]
    row: usize, // must be in [1..Board.size]
};

pub const VertexTag = enum(u1) {
    pass,
    play,
};

pub const Vertex = union(VertexTag) {
    pass,
    play: Coordinate,

    pub fn asStr(self: Vertex, buf: []u8) []u8 {
        std.debug.assert(buf.len >= 4);
        if (self == .pass) {
            @memcpy(buf[0..4], "pass");
            return buf[0..4];
        }

        const coord = self.play;
        buf[0] = "ABCDEFGHJKLMNOPQRST"[coord.col - 1];
        if (coord.row < 10) {
            buf[1] = "123456789"[coord.row - 1];
            return buf[0..2];
        } else if (coord.row < 20) {
            buf[1] = '1';
            buf[2] = "0123456789"[coord.row - 10];
            return buf[0..3];
        }
        unreachable; // see Board.MAX_SIZE
    }
};

const GridPointTag = enum(u2) {
    none,
    stone,
    offboard,
};

const GridPoint = union(GridPointTag) {
    none: void,
    stone: Color,
    offboard: void,
};

const ChainData = struct {
    liberties: usize,
    stones: usize,
};

// Board handles 2 kind of points:
//  - point used to communicate "real" coordinates with the outside world
//  - xpoint used internally to represents coordinates on an extended board
//
// They are defined as:
//  - point = col + row * size
//  - xpoint = xcol + xrow * xsize
// So both values are never equals.
//
// But:
//  - point in "real" space are indexed starting from 1, so (col, row) in [1..size]x[1..size]
//  - xpoint in "extended" space are indexed starting from 0, so (xcol, xrow) in [0..xsize[x[0..xsize[
// Consequently for all "real" points (as to say not offboard) we have (col, row) = (xcol, xrow)
pub const Board = struct {
    size: usize = undefined, // real size
    xsize: usize = undefined, // extended size = size + offboard
    allocator: std.mem.Allocator = undefined,
    komi: f32 = 0.0,
    xko: usize = 0,
    captures: [2]usize = [_]usize{ 0, 0 }, // indexed by color (black for white stones captured by black player, etc)

    // all following arrays are indexed by xpoint
    grid: []GridPoint, // 0 is lower left corner, last is upper right
    chains_data: []ChainData, // access valid chain_data using index from chain_head
    chains_head: []usize, // all stones of a chain points to the same head which itself points to the chain data
    chains_next: []usize, // circular linked list of stones in a chain

    // black_captures: usize = 0, // white stones captured by black player
    // white_captures: usize = 0, // black stones captured by white player

    pub const MIN_SIZE = 1;
    pub const MAX_SIZE = 19;
    pub const DEFAULT_SIZE = 19;

    pub fn create(allocator: std.mem.Allocator, size: usize) !Board {
        std.debug.assert(size >= MIN_SIZE and size <= MAX_SIZE);
        const xsize = size + 2;

        // struct sizes
        // std.debug.print("Point        => @bitSizeOf: {} bits, @sizeOf: {} bytes\n", .{ @bitSizeOf(Point), @sizeOf(Point) });
        // std.debug.print("Color        => @bitSizeOf: {} bits, @sizeOf: {} bytes\n", .{ @bitSizeOf(Color), @sizeOf(Color) });
        // std.debug.print("GridPointTag => @bitSizeOf: {} bits, @sizeOf: {} bytes\n", .{ @bitSizeOf(GridPointTag), @sizeOf(GridPointTag) });
        // std.debug.print("GridPoint    => @bitSizeOf: {} bits, @sizeOf: {} bytes\n", .{ @bitSizeOf(GridPoint), @sizeOf(GridPoint) });
        // std.debug.print("Board        => @bitSizeOf: {} bits, @sizeOf: {} bytes\n", .{ @bitSizeOf(Board), @sizeOf(Board) });
        // std.debug.print("ChainData    => @bitSizeOf: {} bits, @sizeOf: {} bytes\n", .{ @bitSizeOf(ChainData), @sizeOf(ChainData) });

        const grid = try allocator.alloc(GridPoint, xsize * xsize);
        const chains_data = try allocator.alloc(ChainData, xsize * xsize);
        const chains_head = try allocator.alloc(usize, xsize * xsize);
        const chains_next = try allocator.alloc(usize, xsize * xsize);

        for (0..xsize) |xrow| {
            for (0..xsize) |xcol| {
                const xpoint = xcol + xrow * xsize;
                if (xrow == 0 or xrow == xsize - 1 or xcol == 0 or xcol == xsize - 1) {
                    grid[xpoint] = GridPoint.offboard;
                } else {
                    grid[xpoint] = GridPoint.none;
                }
                chains_data[xpoint].liberties = 0;
                chains_data[xpoint].stones = 0;
                chains_head[xpoint] = 0;
                chains_next[xpoint] = 0;
            }
        }

        return Board{
            .size = size,
            .xsize = xsize,
            .grid = grid,
            .allocator = allocator,
            .chains_data = chains_data,
            .chains_head = chains_head,
            .chains_next = chains_next,
        };
    }

    pub fn clear(self: *Board) void {
        for (0..self.xsize) |xrow| {
            for (0..self.xsize) |xcol| {
                const xpoint = xcol + xrow * self.xsize;
                if (xrow == 0 or xrow == self.xsize - 1 or xcol == 0 or xcol == self.xsize - 1) {
                    self.grid[xpoint] = GridPoint.offboard;
                } else {
                    self.grid[xpoint] = GridPoint.none;
                }
                self.chains_data[xpoint].liberties = 0;
                self.chains_data[xpoint].stones = 0;
                self.chains_head[xpoint] = 0;
                self.chains_next[xpoint] = 0;
            }
        }

        self.captures[0] = 0;
        self.captures[1] = 0;
        self.xko = 0;
    }

    pub fn deinit(self: *Board) void {
        self.allocator.free(self.grid);
        self.allocator.free(self.chains_data);
        self.allocator.free(self.chains_head);
        self.allocator.free(self.chains_next);
    }

    pub inline fn asCoordinate(self: *Board, xpoint: usize) Coordinate {
        std.debug.assert(self.grid[xpoint] != .offboard);
        const xrow = @divTrunc(xpoint, self.xsize);
        const xcol = xpoint - xrow * self.xsize;
        return .{ .row = xrow, .col = xcol };
    }

    pub inline fn ko(self: *Board) ?Coordinate {
        if (self.xko == 0) {
            return null;
        }
        return self.asCoordinate(self.xko);
    }

    pub fn print(self: *Board, out: std.fs.File.Writer) !void {
        const cols = " A B C D E F G H J K L M N O P Q R S T";

        var xrow: usize = self.xsize - 1;
        while (true) : (xrow -= 1) {
            if (xrow == 0 or xrow == self.xsize - 1) {
                try out.print("    {s}\n", .{cols[0 .. 2 * self.size]});
                if (xrow == 0) break;
                continue;
            }
            for (0..self.xsize) |xcol| {
                if (xcol == 0) {
                    try out.print(" {d: >2} ", .{xrow});
                } else if (xcol == self.xsize - 1) {
                    try out.print("  {d: <2}", .{xrow});
                } else {
                    const xpoint = xcol + xrow * self.xsize;
                    switch (self.grid[xpoint]) {
                        .none => try out.print(" .", .{}),
                        .stone => {
                            if (self.grid[xpoint].stone == .black) {
                                try out.print(" X", .{});
                            } else {
                                try out.print(" O", .{});
                            }
                        },
                        .offboard => try out.print(" #", .{}),
                    }
                }
            }
            try out.print("\n", .{});
        }
        try out.print("\n", .{});
    }

    pub fn play(self: *Board, color: Color, vertex: Vertex) bool {
        if (vertex == .pass) {
            self.xko = 0;
            return true;
        }

        if (!self.isLegal(color, vertex)) {
            return false;
        }
        const xpoint = vertex.play.col + vertex.play.row * self.xsize;
        self.playAssumeIsLegal(color, xpoint);
        return true;
    }

    pub fn isLegal(self: *Board, color: Color, vertex: Vertex) bool {
        if (vertex == .pass) return true;

        const col = vertex.play.col;
        const row = vertex.play.row;
        if (row < 1 or row > self.size or col < 1 or col > self.size) {
            return false;
        }

        const xpoint = col + row * self.xsize;
        if (self.grid[xpoint] != .none or self.isSuicide(color, xpoint) or self.isKo(xpoint)) {
            return false;
        }

        return true;
    }

    inline fn xNeighbors(self: *Board, xpoint: usize) [4]usize {
        std.debug.assert(self.grid[xpoint] != .offboard);
        const xp: isize = @intCast(xpoint);
        return [4]usize{
            @as(usize, @bitCast(xp - 1)),
            @as(usize, @bitCast(xp + 1)),
            @as(usize, @bitCast(xp - 1 * @as(isize, @intCast(self.xsize)))),
            @as(usize, @bitCast(xp + @as(isize, @intCast(self.xsize)))),
        };
    }

    fn isSuicide(self: *Board, color: Color, xpoint: usize) bool {
        for (self.xNeighbors(xpoint)) |neighbor| {
            switch (self.grid[neighbor]) {
                .none => return false,
                .stone => {
                    const nlib = self.chains_data[self.chains_head[neighbor]].liberties;
                    if (self.grid[neighbor].stone == color) {
                        if (nlib > 1) {
                            // we will consume one friend's liberty so it must have at least 2 to survive
                            return false;
                        }
                    } else {
                        if (nlib == 1) {
                            // neighbor is on opponent, if it only has 1 liberty we can capture it
                            return false;
                        }
                    }
                },
                .offboard => continue,
            }
        }
        return true;
    }

    inline fn isKo(self: *Board, xpoint: usize) bool {
        return xpoint == self.xko;
    }

    inline fn isAdjacent(self: *Board, xpoint: usize, xheader: usize) bool {
        std.debug.assert(self.grid[xheader] == .stone);
        for (self.xNeighbors(xpoint)) |neighbor| {
            if (self.grid[neighbor] == .stone and self.chains_head[neighbor] == xheader) {
                return true;
            }
        }
        return false;
    }

    fn playAssumeIsLegal(self: *Board, color: Color, xpoint: usize) void {
        std.debug.assert(self.grid[xpoint] == .none);
        self.grid[xpoint] = .{ .stone = color };

        // start with the stone as an isolated chain
        self.chains_data[xpoint].liberties = 0;
        self.chains_data[xpoint].stones = 1;
        self.chains_head[xpoint] = xpoint;
        self.chains_next[xpoint] = xpoint;

        const neighbors = self.xNeighbors(xpoint);

        // add all direct liberties
        for (neighbors) |neighbor| {
            if (self.grid[neighbor] == .none) {
                self.chains_data[xpoint].liberties += 1;
            }
        }

        // merge with surrounding friends
        for (neighbors) |neighbor| {
            if (self.grid[neighbor] == .stone and self.grid[neighbor].stone == color) {
                if (self.chains_head[xpoint] == self.chains_head[neighbor]) { // already merged
                    continue;
                }
                self.chains_data[self.chains_head[neighbor]].liberties -= 1; // consume one friend liberty for the link
                self.mergeChains(xpoint, neighbor);
            }
        }

        // remove captured chains
        var opponent_chains_index: usize = 0;
        var opponent_chains_seen = [4]usize{ 0, 0, 0, 0 };
        for (neighbors) |neighbor| {
            if (self.grid[neighbor] == .stone and self.grid[neighbor].stone != color) {
                const opponent_head = self.chains_head[neighbor];

                var seen = false;
                for (0..opponent_chains_index) |i| { // ensures we add liberty only one time to a chain
                    if (opponent_chains_seen[i] == opponent_head) {
                        seen = true;
                        break;
                    }
                }
                if (seen) {
                    continue;
                }

                opponent_chains_seen[opponent_chains_index] = opponent_head;
                opponent_chains_index += 1;
                self.chains_data[opponent_head].liberties -= 1;

                if (self.chains_data[opponent_head].liberties == 0) {
                    const captured = self.removeChain(opponent_head);
                    self.captures[color.asUsize()] += captured;

                    // possible ko
                    if (captured == 1) {
                        const data = self.chains_data[self.chains_head[xpoint]];
                        if (data.stones == 1 and data.liberties == 1) {
                            for (self.xNeighbors(xpoint)) |n| {
                                if (self.grid[n] == .none) {
                                    self.xko = n;
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        }

        // at the end we must be alive
        std.debug.assert(self.chains_data[self.chains_head[xpoint]].liberties > 0);
    }

    fn mergeChains(self: *Board, xpoint1: usize, xpoint2: usize) void {
        var header1 = self.chains_head[xpoint1];
        var header2 = self.chains_head[xpoint2];

        // we want 2 to be the smallest chain
        if (self.chains_data[header2].stones > self.chains_data[header1].stones) {
            const h = header1;
            header1 = header2;
            header2 = h;
        }

        // adjust data of the chains
        self.chains_data[header1].stones += self.chains_data[header2].stones;
        self.chains_data[header2].liberties = 0;
        self.chains_data[header2].stones = 0;

        // iterates over each stones of chain2 to
        // 1. add stone's liberties as new liberties to chain1
        // 2. then merge stone to chain1
        var xpoint = self.chains_next[header2];
        while (true) {
            // a xpoint's liberty is a new liberty for chain1 if it is not already adjacent to header1's chain
            for (self.xNeighbors(xpoint)) |neighbor| {
                if (self.grid[neighbor] == .none and !self.isAdjacent(neighbor, header1)) {
                    self.chains_data[header1].liberties += 1;
                }
            }

            // merge with chain1
            self.chains_head[xpoint] = header1;

            if (xpoint == header2) {
                break;
            }
            xpoint = self.chains_next[xpoint];
        }

        // merge the 2 circular linked lists
        var last2 = header2;
        var next2 = self.chains_next[header2];
        while (next2 != header2) {
            last2 = next2;
            next2 = self.chains_next[last2];
        }
        self.chains_next[last2] = self.chains_next[header1];
        self.chains_next[header1] = header2;
    }

    fn removeChain(self: *Board, xheader: usize) usize {
        std.debug.assert(self.grid[xheader] == .stone);
        const opponent_color = self.grid[xheader].stone.opponent();

        var opponent_chains_index: usize = 0;
        var opponent_chains_seen = [4]usize{ 0, 0, 0, 0 };

        var xpoint = self.chains_next[xheader];
        std.debug.assert(self.grid[xpoint] == .stone);
        while (true) {
            // add liberties to surrounding opponent chains
            opponent_chains_index = 0;
            for (self.xNeighbors(xpoint)) |neighbor| {
                if (self.grid[neighbor] == .stone and self.grid[neighbor].stone == opponent_color) {
                    const opponent_head = self.chains_head[neighbor];
                    var seen = false;
                    for (0..opponent_chains_index) |i| { // ensures we add liberty only one time to a chain
                        if (opponent_chains_seen[i] == opponent_head) {
                            seen = true;
                            break;
                        }
                    }
                    if (seen) {
                        continue;
                    }
                    self.chains_data[opponent_head].liberties += 1;
                    opponent_chains_seen[opponent_chains_index] = opponent_head;
                    opponent_chains_index += 1;
                }
            }

            // clear stone and pass to next
            const xnext = self.chains_next[xpoint];
            self.grid[xpoint] = .none;
            self.chains_head[xpoint] = 0;
            self.chains_next[xpoint] = 0;
            if (xpoint == xheader) {
                break;
            }
            xpoint = xnext;
            std.debug.assert(self.grid[xpoint] == .stone);
        }

        const captured = self.chains_data[xheader].stones;
        self.chains_data[xheader].stones = 0;
        self.chains_data[xheader].liberties = 0;
        return captured;
    }
};
