const std = @import("std");
const Window = @import("Window.zig");
const util = @import("../util.zig");

// TODO: compute these based on circle math (for any radius)
const top_left_bitmap: []const []const u8 = &.{
    &.{ 0, 0, 0, 0, 0, 0, 0, 37, 122, 188 },
    &.{ 0, 0, 0, 0, 0, 37, 160, 255, 255, 255 },
    &.{ 0, 0, 0, 0, 103, 255, 255, 255, 160, 66 },
    &.{ 0, 0, 0, 122, 255, 255, 160, 28, 0, 0 },
    &.{ 0, 0, 103, 255, 255, 103, 0, 0, 0, 0 },
    &.{ 0, 37, 255, 255, 103, 0, 0, 0, 0, 0 },
    &.{ 0, 160, 255, 160, 0, 0, 0, 0, 0, 0 },
    &.{ 37, 255, 255, 28, 0, 0, 0, 0, 0, 0 },
    &.{ 122, 255, 160, 0, 0, 0, 0, 0, 0, 0 },
    &.{ 188, 255, 66, 0, 0, 0, 0, 0, 0, 0 },
};
const top_right_bitmap = util.flip_horizontal(top_left_bitmap);
const bottom_left_bitmap = util.flip_vertical(top_left_bitmap);
const bottom_right_bitmap = util.flip_horizontal(bottom_left_bitmap);

pub const border_radius: i32 = top_left_bitmap.len;
pub const border_width = 2;
pub const edge_padding = 8;
pub const interior_padding = 4;

pub const Options = struct {
    pub const Padding = struct {
        left: i32,
        right: i32,
        top: i32,
        bottom: i32,
    };

    background_color: Window.Rgb,
    border_color: Window.Rgb,
    padding: Padding,
};

pub fn draw(canvas: Window.Canvas, options: Options) Window.Rect {
    const padding = options.padding;

    std.debug.assert(padding.left >= 0);
    std.debug.assert(padding.right >= 0);
    std.debug.assert(padding.top >= 0);
    std.debug.assert(padding.bottom >= 0);
    std.debug.assert(
        padding.left + padding.right + 2 * border_radius <= canvas.width,
    );
    std.debug.assert(
        padding.top + padding.bottom + 2 * border_radius <= canvas.width,
    );

    canvas.fill(options.background_color);
    drawLines(canvas, options.border_color, padding);
    drawCorners(canvas, options);

    return .{
        .x = padding.left + border_radius,
        .y = padding.top + border_radius,
        .width = canvas.width - padding.left - padding.right - 2 * border_radius,
        .height = canvas.height - padding.top - padding.bottom - 2 * border_radius,
    };
}

fn drawLines(canvas: Window.Canvas, color: Window.Rgb, padding: Options.Padding) void {
    canvas.rect(.{
        .x = padding.left,
        .y = padding.top + border_radius,
        .width = border_width,
        .height = canvas.height - padding.top - padding.bottom - 2 * border_radius,
    }, color);
    canvas.rect(.{
        .x = canvas.width - padding.right - border_width,
        .y = padding.top + border_radius,
        .width = border_width,
        .height = canvas.height - padding.top - padding.bottom - 2 * border_radius,
    }, color);
    canvas.rect(.{
        .x = padding.left + border_radius,
        .y = padding.top,
        .width = canvas.width - padding.left - padding.right - 2 * border_radius,
        .height = border_width,
    }, color);
    canvas.rect(.{
        .x = padding.left + border_radius,
        .y = canvas.height - padding.bottom - border_width,
        .width = canvas.width - padding.left - padding.right - 2 * border_radius,
        .height = border_width,
    }, color);
}

fn drawCorners(canvas: Window.Canvas, options: Options) void {
    const padding = options.padding;
    canvas.bitmap(
        padding.left,
        padding.top,
        top_left_bitmap,
        options.border_color,
        null,
    );
    canvas.bitmap(
        canvas.width - padding.right - border_radius,
        padding.top,
        top_right_bitmap,
        options.border_color,
        null,
    );
    canvas.bitmap(
        padding.left,
        canvas.height - padding.bottom - border_radius,
        bottom_left_bitmap,
        options.border_color,
        null,
    );
    canvas.bitmap(
        canvas.width - padding.right - border_radius,
        canvas.height - padding.bottom - border_radius,
        bottom_right_bitmap,
        options.border_color,
        null,
    );
}
