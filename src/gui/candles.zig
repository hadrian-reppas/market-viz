const std = @import("std");
const types = @import("../market/types.zig");
const Candles = @import("../market/Candles.zig");
const Window = @import("Window.zig");
const border = @import("border.zig");

pub const bucket_count = 64;
const min_vertical_padding = types.Price.parse("0.015") catch unreachable;

pub fn draw(ptr: *anyopaque, canvas: Window.Canvas) void {
    var buckets: [bucket_count]Candles.Bucket = undefined;
    const candles: *Candles = @ptrCast(@alignCast(ptr));
    candles.lock();
    candles.copy(&buckets);
    candles.unlock();

    const cropped = canvas.crop(.{
        .x = 0,
        .y = 0,
        .width = canvas.width / 2,
        .height = canvas.height / 2,
    });
    border.draw(cropped, .{
        .background_color = .{ 10, 11, 12 },
        .border_color = .{ 36, 38, 41 },
        .padding = .{
            .left = border.edge_padding,
            .right = border.interior_padding,
            .top = border.edge_padding,
            .bottom = border.interior_padding,
        },
    });

    _ = getMinMax(&buckets);
}

fn getMinMax(buckets: []const Candles.Bucket) ?struct { types.Price, types.Price } {
    var out: ?struct { types.Price, types.Price } = null;
    for (buckets) |bucket| {
        if (bucket.isEmpty()) continue;
        if (out) |o| {
            out = .{ o.@"0".min(bucket.low), o.@"1".max(bucket.high) };
        } else {
            out = .{ bucket.low, bucket.high };
        }
    }
    return out;
}
