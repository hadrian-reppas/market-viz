const std = @import("std");
const Kalshi = @import("Kalshi.zig");
const secrets = @import("secrets.zig");
const types = @import("types.zig");

pub fn main(init: std.process.Init) !void {
    var kalshi = try Kalshi.init(init.gpa, init.io, .{
        .key_id = secrets.key_id,
        .private_key_pem = secrets.private_key_pem,
    });
    defer kalshi.deinit();

    const ticker = try types.Ticker.init("KXWTAMATCH-26JUL20BLIBEJ-BLI");
    const listener: Kalshi.Listener = .{ .ptr = @constCast(&0), .notify = printTrade };
    try kalshi.subscribe(ticker, listener);

    try kalshi.run();
}

pub fn printTrade(_: *anyopaque, trade: types.Trade) void {
    var uuid_buf: [types.Uuid.fmt_len]u8 = undefined;
    trade.id.fmt(&uuid_buf);

    var yes_buf: [types.FixedPoint.fmt_len]u8 = undefined;
    var no_buf: [types.FixedPoint.fmt_len]u8 = undefined;
    var size_buf: [types.FixedPoint.fmt_len]u8 = undefined;
    const yes = trade.yes_price.fmt(&yes_buf);
    const no = trade.no_price.fmt(&no_buf);
    const size = trade.size.fmt(&size_buf);

    std.debug.print(
        \\Trade {{
        \\  id: {s},
        \\  ticker: {s},
        \\  yes_price: {s},
        \\  no_price: {s},
        \\  size: {s},
        \\  taker_side: {},
        \\  ts: {},
        \\}}
        \\
    , .{
        uuid_buf,
        trade.ticker.get(),
        yes,
        no,
        size,
        trade.taker_side,
        trade.ts,
    });
}
