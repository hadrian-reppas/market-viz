const std = @import("std");
const Kalshi = @import("Kalshi.zig");
const secrets = @import("secrets.zig");

const subscribe =
    \\ {
    \\   "id": 1,
    \\   "cmd": "subscribe",
    \\   "params": {
    \\     "channels": ["trade"],
    \\     "market_tickers": ["KXATPMATCH-26JUL20DIACIN-DIA"]
    \\   }
    \\ }
;

pub fn main(init: std.process.Init) !void {
    var kalshi = try Kalshi.init(init.gpa, init.io, .{
        .key_id = secrets.key_id,
        .private_key_pem = secrets.private_key_pem,
    });
    defer kalshi.deinit();

    try kalshi.ws.send(.{ .text = @constCast(subscribe) });
    while (true) {
        const message = try kalshi.ws.receive();
        std.debug.print("{s}", .{message.text});
        message.deinit(init.gpa);
    }
}
