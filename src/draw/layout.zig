const std = @import("std");
const Canvas = @import("Window.zig").Canvas;

pub const Drawer = struct {
    ptr: *anyopaque,
    func: *const fn (*anyopaque, Canvas) void,

    pub const nop = stateless(drawNothing);

    pub fn draw(self: Drawer, canvas: Canvas) void {
        self.func(self.ptr, canvas);
    }

    pub fn stateless(func: *const fn (Canvas) void) Drawer {
        return .{ .ptr = @ptrCast(@constCast(func)), .func = drawStateless };
    }
};

fn drawStateless(ptr: *anyopaque, canvas: Canvas) void {
    const func: *const fn (Canvas) void = @ptrCast(@alignCast(ptr));
    func(canvas);
}

fn drawNothing(_: Canvas) void {}

pub const Grid = struct {
    children: []const []const Drawer,

    fn draw(ptr: *anyopaque, canvas: Canvas) void {
        const self: *Grid = @ptrCast(@alignCast(ptr));

        const canvas_width: usize = @intCast(canvas.width);
        const canvas_height: usize = @intCast(canvas.height);

        std.debug.assert(self.children.len > 0 and self.children[0].len > 0);
        std.debug.assert(canvas_width % self.children[0].len == 0);
        std.debug.assert(canvas_height % self.children.len == 0);

        const width = @divExact(canvas_width, self.children[0].len);
        const height = @divExact(canvas_height, self.children.len);

        for (self.children, 0..) |row, i| {
            for (row, 0..) |child, j| {
                const cropped = canvas.crop(.{
                    .x = @intCast(j * width),
                    .y = @intCast(i * height),
                    .width = @intCast(width),
                    .height = @intCast(height),
                });
                child.draw(cropped);
            }
        }
    }

    pub fn drawer(self: *const Grid) Drawer {
        return .{ .ptr = @ptrCast(@constCast(self)), .func = draw };
    }
};
