const std = @import("std");
const secrets = @import("secrets.zig");
const Kalshi = @import("network/Kalshi.zig");
const Coinbase = @import("network/Coinbase.zig");
const Candles = @import("market/Candles.zig");
const Window = @import("gui/Window.zig");
const candles = @import("gui/candles.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var btc_buckets: [candles.bucket_count]Candles.Bucket = undefined;
    var btc_candles = Candles.init(&btc_buckets, .@"10s");
    defer btc_candles.deinit();

    var kalshi_buckets: [candles.bucket_count]Candles.Bucket = undefined;
    var kalshi_candles = Candles.init(&kalshi_buckets, .@"10s");
    defer kalshi_candles.deinit();

    var network = try io.concurrent(networkMain, .{ gpa, io, &btc_candles, &kalshi_candles });
    errdefer network.cancel(io) catch {};

    var window = try Window.init(.{
        .userdata = &btc_candles,
        .draw = candles.draw,
        .mode = .{ .windowed = .{ .width = 1280, .height = 720 } },
        .high_pixel_density = true,
        .borderless = true,
    });
    defer window.deinit();

    try window.run();

    network.cancel(io) catch |err| switch (err) {
        error.Canceled => {},
        else => std.debug.print("network thread error: {}\n", .{err}),
    };
}

fn runCoinbase(coinbase: *Coinbase) std.Io.Cancelable!void {
    coinbase.run() catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => std.debug.print("Coinbase error: {}\n", .{err}),
    };
}

fn runKalshi(kalshi: *Kalshi) std.Io.Cancelable!void {
    kalshi.run() catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => std.debug.print("Kalshi error: {}\n", .{err}),
    };
}

fn networkMain(
    gpa: std.mem.Allocator,
    io: std.Io,
    btc_candles: *Candles,
    kalshi_candles: *Candles,
) !void {
    var coinbase = try Coinbase.init(gpa, io, .{
        .key_id = secrets.coinbase.key_id,
        .private_key_base64 = secrets.coinbase.private_key_base64,
    });
    defer coinbase.deinit();

    try coinbase.subscribeToTrades("BTC-USD", btc_candles.listener());

    var kalshi: Kalshi = try .init(gpa, io, .{
        .key_id = secrets.kalshi.key_id,
        .private_key_pem = secrets.kalshi.private_key_pem,
    });
    defer kalshi.deinit();

    try kalshi.subscribeToTrades("KXBTC15M-26JUL301945-45", kalshi_candles.listener());

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    try group.concurrent(io, runCoinbase, .{&coinbase});
    try group.concurrent(io, runKalshi, .{&kalshi});

    try group.await(io);
}

test {
    _ = @import("market/types.zig");
    _ = @import("market/iso8601.zig");
}
