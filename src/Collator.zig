const std = @import("std");
const t = @import("types.zig");
const Listener = @import("Kalshi.zig").Listener;

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
}

fn indexOf(self: *Self, ts: t.Ts) usize {
    return ts / self.resolution.toMilliseconds();
}

fn get(self: *Self, index: usize) *Bucket {
    return &self.buckets[index % self.buckets.len];
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

pub fn listener(self: *Self) Listener {
    return .{ .ptr = self, .notify = insertTrade };
}

fn insertTrade(ptr: *anyopaque, trade: t.Trade) void {
    const collator: *Self = @ptrCast(@alignCast(ptr));
    collator.insert(trade.ts, trade.yes_price, trade.size);

    // TODO: remove
    for (0..collator.buckets.len) |i| {
        const index = (collator.head - i) % collator.buckets.len;
        var buf: [999]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        collator.buckets[index].print(&writer) catch unreachable;
        std.debug.print("{s}\n", .{writer.buffered()});
    }
    std.debug.print("\n", .{});
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

const Bucket = struct {
    start: t.Ts,
    open: t.Price,
    close: t.Price,
    min: t.Price,
    max: t.Price,
    volume: t.Size,
    vwtp: t.Notional,

    pub fn init(start: t.Ts) Bucket {
        return .{
            .start = start,
            .open = .zero,
            .close = .zero,
            .min = .one,
            .max = .zero,
            .volume = .zero,
            .vwtp = .zero,
        };
    }

    pub fn insert(self: *Bucket, price: t.Price, size: t.Size) void {
        if (self.volume.eql(.zero))
            self.open = price;
        self.close = price;
        self.min = self.min.min(price);
        self.max = self.max.max(price);
        self.volume = self.volume.add(size);
        self.vwtp = self.vwtp.add(price.mul(size));
    }

    pub fn print(self: *const Bucket, w: *std.Io.Writer) !void {
        try w.print(".{{ start = {}", .{self.start});
        if (self.volume.eql(.zero)) {
            try w.writeAll(" }");
            return;
        }
        try w.writeAll(", open = ");
        try self.open.print(w);
        try w.writeAll(", close = ");
        try self.close.print(w);
        try w.writeAll(", min = ");
        try self.min.print(w);
        try w.writeAll(", max = ");
        try self.max.print(w);
        try w.writeAll(", volume = ");
        try self.volume.print(w);
        try w.writeAll(", vwtp = ");
        try self.vwtp.print(w);
        try w.writeAll(" }");
    }
};
