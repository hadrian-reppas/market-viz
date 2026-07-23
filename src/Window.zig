const std = @import("std");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

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
    name: [:0]const u8 = "MarketViz",
    mode: Mode = .fullscreen,
    resizeable: bool = false,
};

fn expect(ok: bool) !void {
    if (!ok) return error.SdlError;
}

pub fn init(options: Options) !Self {
    try expect(c.SDL_Init(c.SDL_INIT_VIDEO));
    errdefer c.SDL_Quit();

    var flags = c.SDL_WINDOW_HIGH_PIXEL_DENSITY;
    if (options.resizeable)
        flags |= c.SDL_WINDOW_RESIZABLE;

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
                else => {},
            }
        }

        var pixels: ?*anyopaque = undefined;
        var pitch: c_int = undefined;
        try expect(c.SDL_LockTexture(self.texture, null, &pixels, &pitch));

        drawFrame(@ptrCast(pixels.?), @intCast(self.width), @intCast(self.height));

        c.SDL_UnlockTexture(self.texture);
        try expect(c.SDL_RenderClear(self.renderer));
        try expect(c.SDL_RenderTexture(self.renderer, self.texture, null, null));
        try expect(c.SDL_RenderPresent(self.renderer));
    }
}

fn drawFrame(pixels: [*]u8, width: usize, height: usize) void {
    const grid_size = 40;

    for (0..height) |i| {
        for (0..width) |j| {
            const index = 4 * (j + width * i);
            const pixel = pixels[index .. index + 4];

            const x = j / grid_size;
            const y = i / grid_size;

            const parity = (x + y) % 2;
            const color: u8 = @intCast(255 * parity);

            pixel[0] = color;
            pixel[1] = color;
            pixel[2] = color;
            pixel[3] = 255;
        }
    }
}
