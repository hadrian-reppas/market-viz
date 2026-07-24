const std = @import("std");
const Window = @import("Window.zig");
const Collator = @import("Collator.zig");
const t = @import("types.zig");

pub const Options = struct {
    up_color: Window.Color,
    down_color: Window.Color,
    flat_color: Window.Color,
    max_price: t.Price,
    min_price: t.Price,
};

fn getCandleWidth(width: usize, n: usize) !usize {
    std.debug.assert(n >= 2);
    if (width < 7 * n - 1) return error.FrameTooSmall;

    const denominator = 5 * n - 1;
    const rounded_half =
        (2 * width + denominator / 2) / denominator;
    const max_half =
        (width - (n - 1)) / (2 * n);

    const half_candle_width = @min(rounded_half, max_half);
    const candle_width = 2 * half_candle_width;

    const remaining_width = width - n * candle_width;
    const gap =
        @as(f64, @floatFromInt(remaining_width)) /
        @as(f64, @floatFromInt(n - 1));

    std.debug.assert(candle_width % 2 == 0);
    std.debug.assert(candle_width >= 6);
    std.debug.assert(gap >= 1);

    return candle_width;
}

const Lerp = struct {
    x1: f64,
    x2: f64,
    y1: f64,
    y2: f64,

    fn eval(self: Lerp, x: f64) f64 {
        const a = (x - self.x1) / (self.x2 - self.x1);
        return (1 - a) * self.y1 + a * self.y2;
    }
};

pub fn drawCandles(
    frame: Window.Frame,
    buckets: []const Collator.Bucket,
    options: Options,
) void {
    const candle_width = getCandleWidth(
        frame.frame.width,
        buckets.len,
    ) catch return;
    const wick_offset = @divFloor(candle_width - 2, 2);

    const lerp: Lerp = .{
        .x1 = options.min_price.toFloat(f64),
        .x2 = options.max_price.toFloat(f64),
        .y1 = @floatFromInt(frame.frame.height),
        .y2 = 0,
    };

    const total_gap_width = frame.frame.width - buckets.len * candle_width;
    const gap_count = buckets.len - 1;
    for (buckets, 0..) |bucket, i| {
        if (bucket.isEmpty()) continue;

        const gap_width_before =
            @divFloor(i * total_gap_width + gap_count / 2, gap_count);
        const open = bucket.open.toFloat(f64);
        const close = bucket.close.toFloat(f64);
        const low = bucket.low.toFloat(f64);
        const high = bucket.high.toFloat(f64);

        const wick_top = lerp.eval(high);
        const wick_bottom = lerp.eval(low);
        const candle_top = lerp.eval(@max(open, close));
        const candle_bottom = lerp.eval(@min(open, close));
        const wick_height: usize = @round(wick_bottom - wick_top);
        const candle_height: usize = @round(candle_bottom - candle_top);

        const color = if (open > close)
            options.up_color
        else if (close > open)
            options.down_color
        else
            options.flat_color;

        const x = i * candle_width + gap_width_before;
        frame.rectangle(
            .{ .x = x + wick_offset, .y = @round(wick_top), .width = 2, .height = wick_height },
            color,
        );
        frame.rectangle(
            .{ .x = x, .y = @round(candle_top), .width = candle_width, .height = @max(2, candle_height) },
            color,
        );

        if (i == buckets.len - 1) {
            std.debug.assert(x + candle_width == frame.frame.width);
        }
    }
}

// frame.fill(.{ 255, 255, 255, 255 });

// for (buckets, 0..) |bucket, i| {
//     const low: f32 = @floatFromInt(bucket.low);
//     const high: f32 = @floatFromInt(bucket.high);
//     const open: f32 = @floatFromInt(bucket.open);
//     const close: f32 = @floatFromInt(bucket.close);
//     const height_f: f32 = @floatFromInt(frame.frame.height);

//     const rect_top = (10_000.0 - @max(open, close)) / 5_000.0;
//     const rect_bottom = (10_000.0 - @min(open, close)) / 5_000.0;
//     const rect_size = rect_bottom - rect_top;

//     const line_top = (10_000.0 - high) / 5_000.0;
//     const line_bottom = (10_000.0 - low) / 5_000.0;
//     const line_size = line_bottom - line_top;

//     const color = if (bucket.close > bucket.open)
//         green
//     else
//         red;

//     frame.rectangle(
//         .{
//             .x = i * candle_stride,
//             .y = @round(height_f * rect_top),
//             .width = rect_width,
//             .height = @max(line_width, @as(usize, @round(height_f * rect_size))),
//         },
//         color,
//     );
//     frame.rectangle(
//         .{
//             .x = i * candle_stride + line_offset,
//             .y = @round(height_f * line_top),
//             .width = line_width,
//             .height = @round(height_f * line_size),
//         },
//         color,
//     );
