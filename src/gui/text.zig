const std = @import("std");
const Window = @import("Window.zig");
const fonts = @import("fonts");

pub const Alignment = struct {
    pub const Vertical = enum { top, center, baseline, bottom };
    pub const Horizontal = enum { left, center, right };

    vertical: Vertical,
    horizontal: Horizontal,
};

pub fn boundingBox(
    x: i32,
    y: i32,
    alignment: Alignment,
    font: fonts.Font,
    text: []const u8,
) Window.Rect {
    var width: i32 = 0;
    for (text, 0..) |c, i| {
        const char = font.chars[c].?;
        width += if (i + 1 < text.len)
            char.advance[text[i + 1]].?
        else
            char.width;
    }

    return .{
        .x = switch (alignment.horizontal) {
            .left => x,
            .center => x - @divFloor(width, 2),
            .right => x - width,
        },
        .y = switch (alignment.vertical) {
            .top => y,
            .center => y - font.center,
            .baseline => y - font.baseline,
            .bottom => y - font.bottom,
        },
        .width = width,
        .height = font.bottom,
    };
}

pub fn draw(
    canvas: Window.Canvas,
    x: i32,
    y: i32,
    alignment: Alignment,
    font: fonts.Font,
    text: []const u8,
) void {
    const box = boundingBox(x, y, alignment, font, text);

    var pen = box.x;
    for (text, 0..) |c, i| {
        const char = font.chars[c].?;
        if (char.bitmap.len > 0) {
            canvas.bitmap(
                pen + char.left,
                box.y + char.top,
                char.bitmap,
                .{ 0, 0, 0 },
                null,
            );
        }
        pen += if (i + 1 < text.len)
            char.advance[text[i + 1]].?
        else
            char.width;
    }
}
