const std = @import("std");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

userdata: *anyopaque,
draw: *const fn (*anyopaque, Canvas) void,
window: *c.SDL_Window,
renderer: *c.SDL_Renderer,
texture: *c.SDL_Texture,
width: c_int,
height: c_int,

const Self = @This();

pub const Mode = union(enum) {
    fullscreen,
    windowed: struct { width: u32, height: u32 },
};

pub const Options = struct {
    userdata: *anyopaque,
    draw: *const fn (*anyopaque, Canvas) void,
    name: [:0]const u8 = "MarketViz",
    mode: Mode = .fullscreen,
    resizeable: bool = false,
    high_pixel_density: bool = false,
    borderless: bool = false,
};

fn expect(ok: bool) !void {
    if (!ok) return error.SdlError;
}

pub fn init(options: Options) !Self {
    try expect(c.SDL_Init(c.SDL_INIT_VIDEO));
    errdefer c.SDL_Quit();

    var flags: c.SDL_WindowFlags = 0;
    if (options.resizeable)
        flags |= c.SDL_WINDOW_RESIZABLE;
    if (options.high_pixel_density)
        flags |= c.SDL_WINDOW_HIGH_PIXEL_DENSITY;
    if (options.borderless)
        flags |= c.SDL_WINDOW_BORDERLESS;

    // TODO: set minimum window size if resizable
    const initial_width, const initial_height = switch (options.mode) {
        .fullscreen => .{ 1280, 720 },
        .windowed => |size| .{ size.width, size.height },
    };
    const window = c.SDL_CreateWindow(
        options.name,
        @intCast(initial_width),
        @intCast(initial_height),
        flags,
    ) orelse return error.SdlError;
    errdefer c.SDL_DestroyWindow(window);

    if (options.mode == .fullscreen) {
        try expect(c.SDL_SetWindowFullscreen(window, true));
        try expect(c.SDL_HideCursor());
        try expect(c.SDL_SetHint(c.SDL_HINT_VIDEO_MAC_FULLSCREEN_MENU_VISIBILITY, "1"));
    }

    const renderer = c.SDL_CreateRenderer(window, null) orelse return error.SdlError;
    errdefer c.SDL_DestroyRenderer(renderer);

    // TODO: figure out what this does
    // if (!c.SDL_SetRenderVSync(renderer, 1)) return error.SdlError;

    var width: c_int = undefined;
    var height: c_int = undefined;
    try expect(c.SDL_GetCurrentRenderOutputSize(renderer, &width, &height));

    const texture = try createTexture(renderer, width, height);
    errdefer c.SDL_DestroyTexture(texture);

    return .{
        .userdata = options.userdata,
        .draw = options.draw,
        .window = window,
        .renderer = renderer,
        .texture = texture,
        .width = width,
        .height = height,
    };
}

fn createTexture(renderer: *c.SDL_Renderer, width: c_int, height: c_int) !*c.SDL_Texture {
    const texture = c.SDL_CreateTexture(
        renderer,
        c.SDL_PIXELFORMAT_RGBA32,
        c.SDL_TEXTUREACCESS_STREAMING,
        width,
        height,
    ) orelse return error.SdlError;

    // TODO: figure out what this does
    try expect(c.SDL_SetTextureBlendMode(texture, c.SDL_BLENDMODE_NONE));

    return texture;
}

pub fn deinit(self: *Self) void {
    c.SDL_DestroyTexture(self.texture);
    c.SDL_DestroyRenderer(self.renderer);
    c.SDL_DestroyWindow(self.window);
    c.SDL_Quit();
    self.* = undefined;
}

pub fn run(self: *Self) !void {
    var microseconds: [10]i64 = undefined;
    var i: usize = 0;
    while (true) {
        var event: c.union_SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => return,
                c.SDL_EVENT_MOUSE_MOTION => {
                    if (event.motion.xrel != 0.0 or event.motion.yrel != 0)
                        try expect(c.SDL_ShowCursor());
                },
                c.SDL_EVENT_WINDOW_RESIZED => {
                    try expect(c.SDL_GetCurrentRenderOutputSize(
                        self.renderer,
                        &self.width,
                        &self.height,
                    ));
                    self.texture = try createTexture(
                        self.renderer,
                        self.width,
                        self.height,
                    );
                },
                c.SDL_EVENT_KEY_DOWN => {
                    if (event.key.key == c.SDLK_ESCAPE) return;
                },
                else => {},
            }
        }

        var pixels: ?*anyopaque = undefined;
        var pitch: c_int = undefined;
        try expect(c.SDL_LockTexture(self.texture, null, &pixels, &pitch));

        const canvas: Canvas = .{
            .pixels = @ptrCast(pixels.?),
            .stride = @intCast(self.width),
            .width = @intCast(self.width),
            .height = @intCast(self.height),
        };

        const start = std.Io.Clock.real.now(std.Options.debug_io);
        self.draw(self.userdata, canvas);
        const end = std.Io.Clock.real.now(std.Options.debug_io);
        microseconds[i] = end.toMicroseconds() - start.toMicroseconds();
        i += 1;

        if (i == microseconds.len) {
            i = 0;
            // var sum: i64 = 0;
            // for (microseconds) |m| sum += m;
            // std.debug.print("{}us\n", .{@divFloor(sum, microseconds.len)});
        }

        c.SDL_UnlockTexture(self.texture);
        try expect(c.SDL_RenderClear(self.renderer));
        try expect(c.SDL_RenderTexture(self.renderer, self.texture, null, null));
        try expect(c.SDL_RenderPresent(self.renderer));
    }
}

pub const Rgb = [3]u8;
pub const Rgba = [4]u8;

pub const Rect = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,

    pub fn intersect(a: Rect, b: Rect) Rect {
        const left = @max(a.x, b.x);
        const right = @min(a.x + a.width, b.x + b.width);
        const top = @max(a.y, b.y);
        const bottom = @min(a.y + a.height, b.y + b.height);
        const width = if (right >= left) right - left else 0;
        const height = if (bottom >= top) bottom - top else 0;
        return .{ .x = left, .y = top, .width = width, .height = height };
    }
};

pub const Canvas = struct {
    pixels: [*]u8,
    stride: usize,
    width: usize,
    height: usize,

    pub fn indexOf(self: Canvas, x: usize, y: usize) usize {
        return 4 * (x + y * self.stride);
    }

    pub fn set(self: Canvas, x: usize, y: usize, color: Rgb) void {
        std.debug.assert(x < self.width);
        std.debug.assert(y < self.height);

        const index = self.indexOf(x, y);
        const pixel = self.pixels[index..][0..4];
        const rgba = color ++ .{255};
        @memcpy(pixel, &rgba);
    }

    pub fn setMany(self: Canvas, x: usize, y: usize, n: usize, color: Rgb) void {
        std.debug.assert(x + n <= self.width);
        std.debug.assert(y < self.height);

        const index = self.indexOf(x, y);
        const start: [*]u32 = @ptrCast(@alignCast(self.pixels + index));
        const slice = start[0..n];
        const rgba = color ++ .{255};
        const int = std.mem.readInt(u32, &rgba, .native);
        @memset(slice, int);
    }

    pub fn fill(self: Canvas, color: Rgb) void {
        self.rect(self.extent(), color);
    }

    pub fn rect(self: Canvas, r: Rect, color: Rgb) void {
        for (0..r.height) |i| {
            self.setMany(r.x, r.y + i, r.width, color);
        }
    }

    pub fn bitmap(
        self: Canvas,
        r: Rect,
        alphas: []const []const u8,
        fg_color: Rgb,
        bg_color: Rgb,
    ) void {
        std.debug.assert(alphas.len > 0);
        std.debug.assert(r.width <= alphas[0].len);
        std.debug.assert(r.height <= alphas.len);
        std.debug.assert(r.x + r.width <= self.width);
        std.debug.assert(r.y + r.height <= self.height);

        for (0..r.height) |i| {
            for (0..r.width) |j| {
                const alpha = @as(f32, @floatFromInt(alphas[i][j])) / 255;
                const fg_f32: @Vector(3, f32) = @floatFromInt(
                    @as(@Vector(3, u8), fg_color),
                );
                const bg_f32: @Vector(3, f32) = @floatFromInt(
                    @as(@Vector(3, u8), bg_color),
                );
                const color_f32: @Vector(3, f32) =
                    @as(@Vector(3, f32), @splat(1 - alpha)) * bg_f32 +
                    @as(@Vector(3, f32), @splat(alpha)) * fg_f32;
                const color: @Vector(3, u8) = @round(color_f32);
                self.set(r.x + j, r.y + i, color);
            }
        }
    }

    pub fn crop(self: Canvas, r: Rect) Canvas {
        std.debug.assert(r.x + r.width <= self.width);
        std.debug.assert(r.y + r.height <= self.height);

        const index = self.indexOf(r.x, r.y);
        return .{
            .pixels = self.pixels + index,
            .stride = self.stride,
            .width = r.width,
            .height = r.height,
        };
    }

    pub fn extent(self: Canvas) Rect {
        return .{ .x = 0, .y = 0, .width = self.width, .height = self.height };
    }
};
