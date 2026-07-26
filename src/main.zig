const std = @import("std");
const Kalshi = @import("Kalshi.zig");
const secrets = @import("secrets.zig");
const types = @import("types.zig");
const Collator = @import("Collator.zig");
const Window = @import("Window.zig");

pub fn main(init: std.process.Init) !void {
    var collator = try Collator.init(init.gpa, 100, .@"10s");

    const thread = try std.Thread.spawn(.{}, netMain, .{ init.gpa, init.io, &collator });

    var window = try Window.init(.{
        .userdata = @ptrCast(&collator),
        .draw = draw,
        .mode = .{ .windowed = .{ .width = 1280, .height = 720 } },
        .resizeable = true,
    });
    defer window.deinit();

    try window.run();

    // thread.join();
    thread.detach();
    std.process.exit(0);
}

fn netMain(gpa: std.mem.Allocator, io: std.Io, collator: *Collator) !void {
    // var bundle: std.crypto.Certificate.Bundle = .{ .map = .empty, .bytes = .empty };
    // defer bundle.deinit(gpa);
    // const now = std.Io.Clock.real.now(io);
    // try bundle.addCertsFromFilePath(gpa, io, now, std.Io.Dir.cwd(), "rootCA.pem");

    var kalshi = try Kalshi.init(gpa, io, .{
        .key_id = secrets.key_id,
        .private_key_pem = secrets.private_key_pem,
        // .host = "localhost",
        // .port = 8443,
        // .path = "/",
        // .bundle = &bundle,
    });
    defer kalshi.deinit();

    const ticker = try types.Ticker.init("KXF1RACE-HUNGP26-NOR");
    try kalshi.subscribe(ticker, collator.listener());

    try kalshi.run();
}

fn draw(userdata: *anyopaque, canvas: Window.Canvas) void {
    const collator: *Collator = @ptrCast(@alignCast(userdata));

    var buckets: [100]Collator.Bucket = undefined;

    collator.lock();
    collator.copy(&buckets);
    collator.unlock();

    _ = canvas.frame(.{
        .x = 0,
        .y = 0,
        .width = 1280,
        .height = 720,
    });
    const frame = canvas.frameFull();

    @import("draw.zig").drawCandles(
        frame,
        &buckets,
        .{
            .up_color = .{ 223, 72, 76, 255 },
            .down_color = .{ 69, 151, 130, 255 },
            .flat_color = .{ 69, 151, 130, 255 },
            .min_price = types.Price.parse("0.0000") catch unreachable,
            .max_price = types.Price.parse("1.0000") catch unreachable,
        },
    );
}

test {
    _ = types;
}
