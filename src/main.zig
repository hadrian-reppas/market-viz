const std = @import("std");
const secrets = @import("secrets.zig");
const Kalshi = @import("network/Kalshi.zig");
const Coinbase = @import("network/Coinbase.zig");
const Candles = @import("market/Candles.zig");
const Window = @import("gui/Window.zig");

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

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var coinbase = try Coinbase.init(gpa, io, .{
        .key_id = secrets.coinbase.key_id,
        .private_key_base64 = secrets.coinbase.private_key_base64,
    });
    defer coinbase.deinit();

    var btc_usd_candles = try Candles.init(gpa, 10, .@"1s");
    defer btc_usd_candles.deinit(gpa);

    var eth_usd_candles = try Candles.init(gpa, 10, .@"10s");
    defer eth_usd_candles.deinit(gpa);

    try coinbase.subscribeToTrades("BTC-USD", btc_usd_candles.listener());
    try coinbase.subscribeToTrades("ETH-USD", eth_usd_candles.listener());

    var kalshi: Kalshi = try .init(gpa, io, .{
        .key_id = secrets.kalshi.key_id,
        .private_key_pem = secrets.kalshi.private_key_pem,
    });
    defer kalshi.deinit();

    var btc_target_candles = try Candles.init(gpa, 10, .@"5s");
    defer btc_target_candles.deinit(gpa);

    try kalshi.subscribeToTrades("KXBTC15M-26JUL301845-45", btc_target_candles.listener());

    var listeners: std.Io.Group = .init;
    defer listeners.cancel(io);

    try listeners.concurrent(io, runCoinbase, .{&coinbase});
    try listeners.concurrent(io, runKalshi, .{&kalshi});

    try io.sleep(.fromSeconds(15), .real);
    listeners.cancel(io);

    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &buf);
    const stdout = &stdout_writer.interface;

    var buckets: [10]Candles.Bucket = undefined;

    btc_usd_candles.copy(&buckets);
    for (buckets) |bucket| {
        try bucket.print(stdout);
        try stdout.writeAll("\n");
    }
    try stdout.writeAll("\n");

    eth_usd_candles.copy(&buckets);
    for (buckets) |bucket| {
        try bucket.print(stdout);
        try stdout.writeAll("\n");
    }
    try stdout.writeAll("\n");

    btc_target_candles.copy(&buckets);
    for (buckets) |bucket| {
        try bucket.print(stdout);
        try stdout.writeAll("\n");
    }
    try stdout.writeAll("\n");

    try stdout.flush();
}

test {
    _ = @import("market/types.zig");
    _ = @import("market/iso8601.zig");
}
