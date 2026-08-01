const std = @import("std");
const Window = @import("Window.zig");
const fonts = @import("fonts");

pub const Alignment = struct {
    pub const Vertical = enum { top, center, baseline, bottom };
    pub const Horizontal = enum { left, center, right };

    vertical: Vertical,
    horizontal: Horizontal,
};

pub const test_drawer = @import("layout.zig").Drawer.stateless(drawTextTest);

// TODO: remove
fn drawTextTest(canvas: Window.Canvas) void {
    const text = "Hell$";

    canvas.fill(.{ 255, 255, 255 });
    for (std.enums.values(Alignment.Horizontal), 0..) |h, i| {
        for (std.enums.values(Alignment.Vertical), 0..) |v, j| {
            const alignment: Alignment = .{ .vertical = v, .horizontal = h };
            const x = 150 + 200 * @as(i32, @intCast(j));
            const y = 100 + 100 * @as(i32, @intCast(i));
            const box = boundingBox(x, y, alignment, fonts.roboto_light40, text);
            canvas.rect(box, .{ 200, 255, 200 });
            draw(canvas, x, y, alignment, fonts.roboto_light40, text);
            canvas.rect(
                .{ .x = x - 80, .y = y, .width = 160, .height = 1 },
                .{ 255, 0, 0 },
            );
            canvas.rect(
                .{ .x = x, .y = y - 40, .width = 1, .height = 80 },
                .{ 255, 0, 0 },
            );
        }
    }
}

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
