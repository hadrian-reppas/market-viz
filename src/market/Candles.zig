const std = @import("std");
const types = @import("types.zig");
const util = @import("../util.zig");
const layout = @import("../draw/layout.zig");

mutex: util.Mutex,
buckets: []Bucket,
resolution: Resolution,
head: usize,

const Self = @This();

pub fn init(buckets: []Bucket, resolution: Resolution) Self {
    @memset(buckets, .init(.zero));
    return .{
        .mutex = .init,
        .buckets = buckets,
        .resolution = resolution,
        .head = 0,
    };
}

pub fn deinit(self: *Self) void {
    self.mutex.deinit();
    self.* = undefined;
}

fn indexOf(self: *const Self, ts: types.Ts) usize {
    return ts.microseconds / self.resolution.toMicroseconds();
}

fn get(self: *Self, index: usize) *Bucket {
    return &self.buckets[index % self.buckets.len];
}

// Consider calling `mutex.lock()`
pub fn insert(self: *Self, trade: types.Trade) void {
    self.touch(trade.ts);
    const index = self.indexOf(trade.ts);
    self.get(index).insert(trade.price, trade.size);
}

// Consider calling `mutex.lock()`
pub fn touch(self: *Self, ts: types.Ts) void {
    const new_head = self.indexOf(ts);
    for (0..self.buckets.len) |i| {
        const expected = (new_head - i) * self.resolution.toMicroseconds();
        const bucket = self.get(new_head - i);
        if (bucket.start.microseconds == expected) {
            break;
        } else {
            bucket.* = .init(.{ .microseconds = expected });
        }
    }
    self.head = new_head;
}

// Consider calling `mutex.lock()`
pub fn touchNow(self: *Self) void {
    const now = std.Io.Clock.real.now(std.Options.debug_io);
    self.touch(.{ .microseconds = @intCast(now.toMicroseconds()) });
}

// Consider calling `Candles.lock`
pub fn copy(self: *Self, dest: []Bucket) void {
    std.debug.assert(self.buckets.len == dest.len);
    if (self.head == 0) {
        @memset(dest, .init(.zero));
        return;
    }

    const start = self.head - dest.len + 1;
    for (0..dest.len) |i| {
        dest[i] = self.get(start + i).*;
    }
}

pub fn listener(self: *Self) types.TradeListener {
    return .{ .ptr = self, .func = insertTrade };
}

pub const Resolution = enum {
    @"1s",
    @"5s",
    @"10s",
    @"30s",
    @"1m",
    @"5m",
    @"10m",
    @"30m",
    @"1h",

    pub fn toMicroseconds(self: Resolution) u64 {
        return switch (self) {
            .@"1s" => 1_000_000,
            .@"5s" => 5 * 1_000_000,
            .@"10s" => 10 * 1_000_000,
            .@"30s" => 30 * 1_000_000,
            .@"1m" => 60 * 1_000_000,
            .@"5m" => 5 * 60 * 1_000_000,
            .@"10m" => 10 * 60 * 1_000_000,
            .@"30m" => 30 * 60 * 1_000_000,
            .@"1h" => 60 * 60 * 1_000_000,
        };
    }
};

pub const Bucket = struct {
    start: types.Ts,
    open: types.Price,
    close: types.Price,
    low: types.Price,
    high: types.Price,
    volume: types.Size,
    notional: types.Notional,

    pub fn init(start: types.Ts) Bucket {
        return .{
            .start = start,
            .open = .zero,
            .close = .zero,
            .low = .infinity,
            .high = .zero,
            .volume = .zero,
            .notional = .zero,
        };
    }

    pub fn insert(self: *Bucket, price: types.Price, size: types.Size) void {
        if (self.isEmpty()) self.open = price;
        self.close = price;
        self.low = self.low.min(price);
        self.high = self.high.max(price);
        self.volume = self.volume.add(size);
        self.notional = self.notional.add(price.mul(size));
    }

    pub fn isEmpty(self: Bucket) bool {
        return self.volume.eql(.zero);
    }

    pub fn print(self: *const Bucket, w: *std.Io.Writer) !void {
        try w.writeAll("{ start = ");
        try self.start.print(w);
        if (self.isEmpty()) {
            try w.writeAll(" }");
            return;
        }
        try w.writeAll(", open = ");
        try self.open.print(w);
        try w.writeAll(", close = ");
        try self.close.print(w);
        try w.writeAll(", low = ");
        try self.low.print(w);
        try w.writeAll(", high = ");
        try self.high.print(w);
        try w.writeAll(", volume = ");
        try self.volume.print(w);
        try w.writeAll(", notional = ");
        try self.notional.print(w);
        try w.writeAll(" }");
    }
};

fn insertTrade(ptr: *anyopaque, trade: types.Trade) void {
    const candles: *Self = @ptrCast(@alignCast(ptr));

    candles.mutex.lock();
    candles.insert(trade);
    candles.mutex.unlock();
}

pub fn drawer(self: *Self) layout.Drawer {
    return .{
        .ptr = @ptrCast(self),
        .func = @import("../draw/candles.zig").draw,
    };
}
