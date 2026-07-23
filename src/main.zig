const std = @import("std");
const Kalshi = @import("Kalshi.zig");
const secrets = @import("secrets.zig");
const types = @import("types.zig");
const Collator = @import("Collator.zig");
const Window = @import("Window.zig");

pub fn main() !void {
    var window = try Window.init(.{
        .mode = .{ .windowed = .{ .width = 1280, .height = 720 } },
        .resizeable = true,
    });
    defer window.deinit();

    try window.run();

    //     const gpa = init.gpa;
    //     const io = init.io;

    //     var bundle: std.crypto.Certificate.Bundle = .{ .map = .empty, .bytes = .empty };
    //     defer bundle.deinit(gpa);
    //     const now = std.Io.Clock.real.now(io);
    //     try bundle.addCertsFromFilePath(gpa, io, now, std.Io.Dir.cwd(), "rootCA.pem");

    //     var kalshi = try Kalshi.init(gpa, io, .{
    //         .key_id = secrets.key_id,
    //         .private_key_pem = secrets.private_key_pem,
    //         .host = "localhost",
    //         .port = 8443,
    //         .path = "/",
    //         .bundle = &bundle,
    //     });
    //     defer kalshi.deinit();

    //     var collator = try Collator.init(init.gpa, 20, .@"1m");

    //     const ticker = try types.Ticker.init("KXMLBGAME-26JUL221335PITNYY-PIT");
    //     try kalshi.subscribe(ticker, collator.listener());

    //     try kalshi.run();
}

test {
    _ = types;
}
