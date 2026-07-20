const std = @import("std");
const WebSocket = @import("WebSocket.zig");
const Kalshi = @import("Kalshi.zig");
const secrets = @import("secrets.zig");

pub fn main(init: std.process.Init) !void {
    var ws: WebSocket = undefined;
    try ws.init(init.gpa, init.io, .{ .host = "echo.websocket.org" });
    defer ws.deinit();

    const message1 = try ws.receive();
    defer message1.deinit(init.gpa);
    std.debug.dumpHex(message1.text);

    try ws.send(.{ .ping = @constCast("hello") });
    const message2 = try ws.receive();
    defer message2.deinit(init.gpa);
    std.debug.dumpHex(message2.pong);
}
