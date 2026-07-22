const std = @import("std");
const Kalshi = @import("Kalshi.zig");
const secrets = @import("secrets.zig");
const types = @import("types.zig");
const Collator = @import("Collator.zig");

pub fn main(init: std.process.Init) !void {
    var kalshi = try Kalshi.init(init.gpa, init.io, .{
        .key_id = secrets.key_id,
        .private_key_pem = secrets.private_key_pem,
    });
    defer kalshi.deinit();

    var collator = try Collator.init(init.gpa, 10, .@"30s");

    // const ticker = try types.Ticker.init("KXNEXTTEAMNBA-26LJAM-MIA");
    const ticker = try types.Ticker.init("KXWTAMATCH-26JUL20WALSHE-WAL");
    try kalshi.subscribe(ticker, collator.listener());

    try kalshi.run();
}

// fn printTrade(_: *anyopaque, trade: types.Trade) void {
//     var uuid_buf: [types.Uuid.fmt_len]u8 = undefined;
//     trade.id.fmt(&uuid_buf);

//     var yes_buf: [types.FixedPoint.fmt_len]u8 = undefined;
//     var no_buf: [types.FixedPoint.fmt_len]u8 = undefined;
//     var size_buf: [types.FixedPoint.fmt_len]u8 = undefined;
//     const yes = trade.yes_price.fmt(&yes_buf);
//     const no = trade.no_price.fmt(&no_buf);
//     const size = trade.size.fmt(&size_buf);

//     std.debug.print(
//         \\Trade {{
//         \\  id: {s},
//         \\  ticker: {s},
//         \\  yes_price: {s},
//         \\  no_price: {s},
//         \\  size: {s},
//         \\  taker_side: {},
//         \\  ts: {},
//         \\}}
//         \\
//     , .{
//         uuid_buf,
//         trade.ticker.get(),
//         yes,
//         no,
//         size,
//         trade.taker_side,
//         trade.ts,
//     });
// }
