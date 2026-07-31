const std = @import("std");
const types = @import("../market/types.zig");
const Candles = @import("../market/Candles.zig");
const Window = @import("Window.zig");
const border = @import("border.zig");
const util = @import("../util.zig");

pub const bucket_count = 64;

const default_min_price = types.Price.parse("0") catch unreachable;
const default_max_price = types.Price.parse("1") catch unreachable;
const minimum_y_axis_padding = 0.015;
const y_axis_padding_proportion = 0.125;

const candle_width = 16;
const candle_gap = 2;
const candle_stride = candle_width + candle_gap;
const wick_width = 2;
const wick_offset = (candle_width - wick_width) / 2;

const background_color: Window.Rgb = .{ 10, 11, 12 };
const border_color: Window.Rgb = .{ 36, 38, 41 };
const up_color: Window.Rgb = .{ 69, 151, 130 };
const down_color: Window.Rgb = .{ 223, 72, 76 };
const flat_color = up_color;

pub fn draw(ptr: *anyopaque, canvas: Window.Canvas) void {
    var buckets: [bucket_count]Candles.Bucket = undefined;
    const candles: *Candles = @ptrCast(@alignCast(ptr));
    candles.mutex.lock();
    candles.touchNow();
    candles.copy(&buckets);
    candles.mutex.unlock();

    const cropped = canvas.crop(.{
        .x = 0,
        .y = 0,
        .width = canvas.width / 2,
        .height = canvas.height / 2,
    });
    const interior = border.draw(cropped, .{
        .background_color = background_color,
        .border_color = border_color,
        .padding = .{
            .left = border.edge_padding,
            .right = border.interior_padding,
            .top = border.edge_padding,
            .bottom = border.interior_padding,
        },
    });

    const min_price, const max_price = getPriceBounds(&buckets) orelse
        .{ default_min_price, default_max_price };
    const y_min, const y_max = getYAxisBounds(min_price, max_price);

    drawCandles(
        cropped.crop(interior),
        &buckets,
        .{
            .x1 = y_min,
            .x2 = y_max,
            .y1 = @floatFromInt(interior.height),
            .y2 = 0,
        },
    );
}

fn drawCandles(
    canvas: Window.Canvas,
    buckets: []const Candles.Bucket,
    lerp: util.Lerp(f32),
) void {
    for (buckets, 0..) |bucket, i| {
        if (bucket.isEmpty()) continue;

        const open = bucket.open.toFloat(f32);
        const close = bucket.close.toFloat(f32);
        const low = bucket.low.toFloat(f32);
        const high = bucket.high.toFloat(f32);

        const candle_top = lerp.eval(@max(open, close));
        const candle_bottom = lerp.eval(@min(open, close));
        const candle_height = @max(wick_width, candle_bottom - candle_top);

        const wick_top = lerp.eval(high);
        const wick_bottom = lerp.eval(low);
        const wick_height = wick_bottom - wick_top;

        const color = if (close > open)
            up_color
        else if (close < open)
            down_color
        else
            flat_color;

        canvas.rect(.{
            .x = i * candle_stride,
            .y = @round(candle_top),
            .width = candle_width,
            .height = @round(candle_height),
        }, color);

        canvas.rect(.{
            .x = i * candle_stride + wick_offset,
            .y = @round(wick_top),
            .width = wick_width,
            .height = @round(wick_height),
        }, color);
    }
}

fn getPriceBounds(buckets: []const Candles.Bucket) ?struct { types.Price, types.Price } {
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

fn getYAxisBounds(min_price: types.Price, max_price: types.Price) struct { f32, f32 } {
    const min = min_price.toFloat(f32);
    const max = max_price.toFloat(f32);
    if (min == max) {
        const lower_bound = @max(0, min - minimum_y_axis_padding);
        return .{ lower_bound, lower_bound + 2 * minimum_y_axis_padding };
    }

    const range = max - min;
    const padding = @max(
        y_axis_padding_proportion * range,
        minimum_y_axis_padding,
    );

    return .{ @max(0, min - padding), max + padding };
}
