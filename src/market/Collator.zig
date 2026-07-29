const std = @import("std");
const t = @import("../network/types.zig");
const Listener = @import("../network/Kalshi.zig").Listener;

mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
buckets: []Bucket,
resolution: Resolution,
head: usize,

const Self = @This();

pub fn init(gpa: std.mem.Allocator, n: usize, resolution: Resolution) !Self {
    const buckets = try gpa.alloc(Bucket, n);
    @memset(buckets, .init(0));
    return .{ .buckets = buckets, .resolution = resolution, .head = 0 };
}

pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
    gpa.free(self.buckets);
    _ = std.c.pthread_mutex_destroy(&self.mutex);
    self.* = undefined;
}

fn indexOf(self: *Self, ts: t.Ts) usize {
    return ts / self.resolution.toMilliseconds();
}

fn get(self: *Self, index: usize) *Bucket {
    return &self.buckets[index % self.buckets.len];
}

pub fn lock(self: *Self) void {
    _ = std.c.pthread_mutex_lock(&self.mutex);
}

pub fn unlock(self: *Self) void {
    _ = std.c.pthread_mutex_unlock(&self.mutex);
}

pub fn insert(self: *Self, ts: t.Ts, price: t.Price, size: t.Size) void {
    self.touch(ts);
    const index = self.indexOf(ts);
    self.get(index).insert(price, size);
}

pub fn touch(self: *Self, ts: t.Ts) void {
    const new_head = self.indexOf(ts);
    for (0..self.buckets.len) |i| {
        const expected = (new_head - i) * self.resolution.toMilliseconds();
        const bucket = self.get(new_head - i);
        if (bucket.start == expected) {
            break;
        } else {
            bucket.* = .init(expected);
        }
    }
    self.head = new_head;
}

pub fn copy(self: *Self, buckets: []Bucket) void {
    const n = @min(self.buckets.len, buckets.len, self.head);
    const self_start = self.head - n + 1;
    const buckets_start = self.buckets.len - n;
    for (0..buckets_start) |i| {
        buckets[i] = .init(0);
    }
    for (0..n) |i| {
        buckets[buckets_start + i] = self.get(self_start + i).*;
    }
    for (n..buckets.len) |i| {
        buckets[i] = .init(0);
    }
}

pub fn realloc(self: *Self, gpa: std.mem.Allocator, n: usize) !void {
    _ = self;
    _ = gpa;
    _ = n;
    @panic("todo");
}

pub fn listener(self: *Self) Listener {
    return .{ .ptr = self, .notify = insertTrade };
}

fn insertTrade(ptr: *anyopaque, trade: t.Trade) void {
    const collator: *Self = @ptrCast(@alignCast(ptr));

    collator.lock();
    defer collator.unlock();

    collator.insert(trade.ts, trade.yes_price, trade.size);

    // TODO: remove
    // for (0..collator.buckets.len) |i| {
    //     const index = (collator.head - i) % collator.buckets.len;
    //     var buf: [999]u8 = undefined;
    //     var writer = std.Io.Writer.fixed(&buf);
    //     collator.buckets[index].print(&writer) catch unreachable;
    //     std.debug.print("{s}\n", .{writer.buffered()});
    // }
    // std.debug.print("\n", .{});
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

    pub fn toMilliseconds(self: Resolution) t.Ts {
        return switch (self) {
            .@"1s" => 1000,
            .@"5s" => 5 * 1000,
            .@"10s" => 10 * 1000,
            .@"30s" => 30 * 1000,
            .@"1m" => 60 * 1000,
            .@"5m" => 5 * 60 * 1000,
            .@"10m" => 10 * 60 * 1000,
            .@"30m" => 30 * 60 * 1000,
            .@"1h" => 60 * 60 * 1000,
        };
    }
};

pub const Bucket = struct {
    start: t.Ts,
    open: t.Price,
    close: t.Price,
    low: t.Price,
    high: t.Price,
    volume: t.Size,
    notional: t.Notional,

    pub fn init(start: t.Ts) Bucket {
        return .{
            .start = start,
            .open = .zero,
            .close = .zero,
            .low = .one,
            .high = .zero,
            .volume = .zero,
            .notional = .zero,
        };
    }

    pub fn insert(self: *Bucket, price: t.Price, size: t.Size) void {
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
        try w.print(".{{ start = {}", .{self.start});
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
