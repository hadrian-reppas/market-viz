const std = @import("std");
const Kalshi = @import("Kalshi.zig");
const secrets = @import("secrets.zig");
const types = @import("types.zig");
const Collator = @import("Collator.zig");
const Window = @import("Window.zig");

pub fn main() !void {
    var window = try Window.init(.{
        .draw = draw,
        .mode = .{ .windowed = .{ .width = 1280, .height = 720 } },
        .resizeable = true,
    });
    defer window.deinit();

    try window.run();
}

fn draw(canvas: Window.Canvas) void {
    const Data = struct { ts: u64, open: u16, close: u16, low: u16, high: u16 };
    const data: []const Data = @import("data.zon");
    var buckets: [data.len]Collator.Bucket = undefined;
    for (data, 0..) |d, i| {
        if (i >= buckets.len) break;
        buckets[i] = .{
            .start = d.ts,
            .open = .{ .value = d.open },
            .close = .{ .value = d.close },
            .low = .{ .value = d.low },
            .high = .{ .value = d.high },
            .volume = undefined,
            .notional = undefined,
        };
    }

    _ = canvas.frame(.{
        .x = 0,
        .y = 0,
        .width = 1280,
        .height = 720,
    });
    const frame = canvas.frameFull();

    @import("draw.zig").drawCandles(
        frame,
        &buckets,
        .{
            .up_color = .{ 223, 72, 76, 255 },
            .down_color = .{ 69, 151, 130, 255 },
            .flat_color = .{ 69, 151, 130, 255 },
            .min_price = types.Price.parse("0.5000") catch unreachable,
            .max_price = types.Price.parse("1.0000") catch unreachable,
        },
    );
}

test {
    _ = types;
}
