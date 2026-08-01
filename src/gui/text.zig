const std = @import("std");
const Window = @import("Window.zig");
const fonts = @import("fonts");

pub fn draw(
    canvas: Window.Canvas,
    font: fonts.Font,
    text: []const u8,
    start_x: i32,
    y: i32,
) void {
    var x: i32 = start_x;
    for (text, 0..) |c, i| {
        const char = font.chars[c].?;
        canvas.bitmap(.{
            .x = x,
            .y = y,
            .width = @intCast(char.bitmap[0].len),
            .height = @intCast(char.bitmap.len),
        }, char.bitmap, .{ 0, 0, 0 }, .{ 255, 255, 255 });
        if (i + 1 < text.len)
            x += char.advance[text[i + 1]].?;
    }
}
