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
    const red: [4]u8 = .{ 223, 72, 76, 255 };
    const green: [4]u8 = .{ 69, 151, 130, 255 };

    const rect_width = 16;
    const rect_gap = 4;
    const line_width = 2;

    const line_offset = @divFloor(rect_width - line_width, 2);
    const candle_stride = rect_width + rect_gap;

    const Bucket = struct { ts: u64, open: u16, close: u16, low: u16, high: u16 };
    const buckets: []const Bucket = @import("data.zon");

    // const frame = canvas.frameFull();
    const frame = canvas.frame(.{
        .x = 200,
        .y = 50,
        .width = 1400,
        .height = 800,
    });

    frame.fill(.{ 255, 255, 255, 255 });

    for (buckets, 0..) |bucket, i| {
        const low: f32 = @floatFromInt(bucket.low);
        const high: f32 = @floatFromInt(bucket.high);
        const open: f32 = @floatFromInt(bucket.open);
        const close: f32 = @floatFromInt(bucket.close);
        const height_f: f32 = @floatFromInt(frame.frame.height);

        const rect_top = (10_000.0 - @max(open, close)) / 5_000.0;
        const rect_bottom = (10_000.0 - @min(open, close)) / 5_000.0;
        const rect_size = rect_bottom - rect_top;

        const line_top = (10_000.0 - high) / 5_000.0;
        const line_bottom = (10_000.0 - low) / 5_000.0;
        const line_size = line_bottom - line_top;

        const color = if (bucket.close > bucket.open)
            green
        else
            red;

        frame.rectangle(
            .{
                .x = i * candle_stride,
                .y = @round(height_f * rect_top),
                .width = rect_width,
                .height = @max(line_width, @as(usize, @round(height_f * rect_size))),
            },
            color,
        );
        frame.rectangle(
            .{
                .x = i * candle_stride + line_offset,
                .y = @round(height_f * line_top),
                .width = line_width,
                .height = @round(height_f * line_size),
            },
            color,
        );
    }
}

test {
    _ = types;
}
