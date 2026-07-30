const std = @import("std");
const Kalshi = @import("network/Kalshi.zig");
const Coinbase = @import("network/Coinbase.zig");
const secrets = @import("secrets.zig");
const Collator = @import("market/Collator.zig");
const Window = @import("gui/Window.zig");

const dummy = 1;
const types = @import("market/types.zig");

const trade_printer: types.TradeListener = .{ .ptr = @constCast(&dummy), .notify = printTrade };
const update_printer: types.UpdateListener = .{ .ptr = @constCast(&dummy), .notify = printUpdate };

fn printTrade(_: *anyopaque, trade: types.Trade) void {
    std.debug.print("trade ({s}) = {}\n", .{ trade.ticker, trade });
}

fn printUpdate(_: *anyopaque, update: types.Update) void {
    std.debug.print("update ({s}) = {}\n", .{ update.ticker, update });
}

pub fn main(init: std.process.Init) !void {
    var coinbase = try Coinbase.init(init.gpa, init.io, .{
        .key_id = secrets.coinbase.key_id,
        .private_key_base64 = secrets.coinbase.private_key_base64,
    });
    defer coinbase.deinit();

    try coinbase.subscribeToTrades("BTC-USD", trade_printer);
    try coinbase.subscribeToTrades("ETH-USD", trade_printer);
    try coinbase.subscribeToUpdates("ETH-USD", update_printer);
    try coinbase.subscribeToUpdates("BTC-USD", update_printer);

    try coinbase.run();

    // var collator = try Collator.init(init.gpa, 64, .@"5s");
    // defer collator.deinit(init.gpa);

    // var kalshi = try Kalshi.init(init.gpa, init.io, .{
    //     .key_id = secrets.kalshi.key_id,
    //     .private_key_pem = secrets.kalshi.private_key_pem,
    // });
    // defer kalshi.deinit();
    // try kalshi.subscribe("KXATPMATCH-26JUL30NAKMEN-NAK");
    // try kalshi.run();

    // if (collator.buckets.len == 64) return;

    // const thread = try std.Thread.spawn(.{}, netMain, .{ init.gpa, init.io, &collator });

    // var window = try Window.init(.{
    //     .userdata = @ptrCast(&collator),
    //     .draw = draw,
    //     .mode = .{ .windowed = .{ .width = 1280, .height = 720 } },
    //     .high_pixel_density = true,
    //     .borderless = true,
    // });
    // defer window.deinit();

    // try window.run();

    // // thread.join();
    // thread.detach();
    // std.process.exit(0);
}

fn netMain(gpa: std.mem.Allocator, io: std.Io, collator: *Collator) !void {
    // var bundle: std.crypto.Certificate.Bundle = .{ .map = .empty, .bytes = .empty };
    // defer bundle.deinit(gpa);
    // const now = std.Io.Clock.real.now(io);
    // try bundle.addCertsFromFilePath(gpa, io, now, std.Io.Dir.cwd(), "rootCA.pem");

    var kalshi = try Kalshi.init(gpa, io, .{
        .key_id = secrets.kalshi.key_id,
        .private_key_pem = secrets.kalshi.private_key_pem,
        // .host = "localhost",
        // .port = 8443,
        // .path = "/",
        // .bundle = &bundle,
    });
    defer kalshi.deinit();

    _ = collator;

    // const ticker = try types.Ticker.init("KXBTCD-26JUL2910-T64399.99");
    // try kalshi.subscribe(ticker, collator.listener());

    // try kalshi.run();
}

const Margin = struct {
    left: usize,
    right: usize,
    top: usize,
    bottom: usize,
};

fn drawBorder(frame: Window.Frame, margin: Margin) void {
    const background_color = .{ 10, 11, 12, 255 };
    const border_color = .{ 36, 38, 41, 255 };
    const border_width = 2;
    const corner: [10][10]u8 = .{
        .{ 0, 0, 0, 0, 0, 0, 0, 37, 122, 188 },
        .{ 0, 0, 0, 0, 0, 37, 160, 255, 255, 255 },
        .{ 0, 0, 0, 0, 103, 255, 255, 255, 160, 66 },
        .{ 0, 0, 0, 122, 255, 255, 160, 28, 0, 0 },
        .{ 0, 0, 103, 255, 255, 103, 0, 0, 0, 0 },
        .{ 0, 37, 255, 255, 103, 0, 0, 0, 0, 0 },
        .{ 0, 160, 255, 160, 0, 0, 0, 0, 0, 0 },
        .{ 37, 255, 255, 28, 0, 0, 0, 0, 0, 0 },
        .{ 122, 255, 160, 0, 0, 0, 0, 0, 0, 0 },
        .{ 188, 255, 66, 0, 0, 0, 0, 0, 0, 0 },
    };
    const border_radius = corner.len;

    frame.fill(background_color);

    const width = frame.frame.width;
    const height = frame.frame.height;

    frame.rectangle(.{
        .x = margin.left,
        .y = margin.top + border_radius,
        .width = border_width,
        .height = height - margin.top - margin.bottom - 2 * border_radius,
    }, border_color);
    frame.rectangle(.{
        .x = margin.left + border_radius,
        .y = margin.top,
        .width = width - margin.left - margin.right - 2 * border_radius,
        .height = border_width,
    }, border_color);
    frame.rectangle(.{
        .x = width - margin.right - border_width,
        .y = margin.top + border_radius,
        .width = border_width,
        .height = height - margin.top - margin.bottom - 2 * border_radius,
    }, border_color);
    frame.rectangle(.{
        .x = margin.left + border_radius,
        .y = height - margin.bottom - border_width,
        .width = width - margin.left - margin.right - 2 * border_radius,
        .height = border_width,
    }, border_color);

    for (corner, 0..) |row, i| {
        for (row, 0..) |alpha, j| {
            const bg: @Vector(3, f32) = .{ 10, 11, 12 };
            const border: @Vector(3, f32) = .{ 36, 38, 41 };
            const a = @as(f32, @floatFromInt(alpha)) / 255;
            const rgb_f32 = @as(@Vector(3, f32), @splat(1 - a)) * bg + @as(@Vector(3, f32), @splat(a)) * border;
            const rgb: @Vector(3, u8) = @round(rgb_f32);
            const color = .{ rgb[0], rgb[1], rgb[2], 255 };
            frame.set(margin.left + i, margin.top + j, color);
            frame.set(width - margin.right - i - 1, margin.top + j, color);
            frame.set(margin.left + i, height - margin.bottom - j - 1, color);
            frame.set(width - margin.right - i - 1, height - margin.bottom - j - 1, color);
        }
    }

    if (width > 720) {
        for (0..64) |i| {
            frame.rectangle(.{
                .x = margin.left + border_radius + 16 * i,
                .y = margin.top + border_radius,
                .width = 14,
                .height = height - margin.top - margin.bottom - 2 * border_radius,
            }, .{ 255, 0, 0, 255 });
        }
    }
}

fn draw(userdata: *anyopaque, canvas: Window.Canvas) void {
    _ = userdata;

    const widget_width = canvas.width / 2;
    const widget_height = canvas.height / 2;
    const half_widget_width = canvas.width / 4;
    const half_widget_height = canvas.height / 4;

    drawBorder(
        canvas.frame(.{
            .x = 0,
            .y = 0,
            .width = widget_width,
            .height = widget_height,
        }),
        .{ .left = 8, .top = 8, .right = 4, .bottom = 4 },
    );
    drawBorder(
        canvas.frame(.{
            .x = widget_width,
            .y = 0,
            .width = half_widget_width,
            .height = widget_height,
        }),
        .{ .left = 4, .top = 8, .right = 4, .bottom = 4 },
    );
    drawBorder(
        canvas.frame(.{
            .x = widget_width + half_widget_width,
            .y = 0,
            .width = half_widget_width,
            .height = half_widget_height,
        }),
        .{ .left = 4, .top = 8, .right = 8, .bottom = 4 },
    );
    drawBorder(
        canvas.frame(.{
            .x = widget_width + half_widget_width,
            .y = half_widget_height,
            .width = half_widget_width,
            .height = half_widget_height,
        }),
        .{ .left = 4, .top = 4, .right = 8, .bottom = 4 },
    );

    drawBorder(
        canvas.frame(.{
            .x = 0,
            .y = widget_height,
            .width = widget_width,
            .height = widget_height,
        }),
        .{ .left = 8, .top = 4, .right = 4, .bottom = 8 },
    );
    drawBorder(
        canvas.frame(.{
            .x = widget_width,
            .y = widget_height,
            .width = half_widget_width,
            .height = widget_height,
        }),
        .{ .left = 4, .top = 4, .right = 4, .bottom = 8 },
    );
    drawBorder(
        canvas.frame(.{
            .x = widget_width + half_widget_width,
            .y = widget_height,
            .width = half_widget_width,
            .height = widget_height,
        }),
        .{ .left = 4, .top = 4, .right = 8, .bottom = 8 },
    );
}

test {
    _ = @import("market/types.zig");
    _ = @import("market/iso8601.zig");
}
