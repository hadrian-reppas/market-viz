const std = @import("std");
const Allocator = std.mem.Allocator;
const WebSocket = @import("WebSocket.zig");
const types = @import("../market/types.zig");

gpa: Allocator,
ws: *WebSocket,
jwt: []u8,
trade_subscriptions: std.StringHashMap(std.ArrayList(types.TradeListener)),
update_subscriptions: std.StringHashMap(std.ArrayList(types.UpdateListener)),

const Self = @This();

pub const Options = struct {
    key_id: []const u8,
    private_key_base64: []const u8,
    host: []const u8 = "advanced-trade-ws.coinbase.com",
    port: u16 = 443,
    bundle: ?*std.crypto.Certificate.Bundle = null,
};

pub fn init(gpa: Allocator, io: std.Io, options: Options) !Self {
    var nonce: [16]u8 = undefined;
    std.Io.random(io, &nonce);

    var buf: [512]u8 = undefined;
    const jwt = try makeJwt(
        &buf,
        options.key_id,
        options.private_key_base64,
        @bitCast(nonce),
    );

    const ws = try gpa.create(WebSocket);
    errdefer gpa.destroy(ws);
    try ws.init(gpa, io, .{
        .host = options.host,
        .port = options.port,
        .bundle = options.bundle,
    });

    return .{
        .gpa = gpa,
        .ws = ws,
        .jwt = try gpa.dupe(u8, jwt),
        .trade_subscriptions = .init(gpa),
        .update_subscriptions = .init(gpa),
    };
}

pub fn deinit(self: *Self) void {
    self.gpa.free(self.jwt);

    self.ws.send(.{ .close = null }) catch {};
    self.ws.deinit();
    self.gpa.destroy(self.ws);

    deinitHashMap(self.gpa, &self.trade_subscriptions);
    deinitHashMap(self.gpa, &self.update_subscriptions);

    self.* = undefined;
}

fn deinitHashMap(gpa: std.mem.Allocator, map: anytype) void {
    var it = map.iterator();
    while (it.next()) |e| {
        gpa.free(e.key_ptr.*);
        e.value_ptr.deinit(gpa);
    }
    map.deinit();
}

const subscribe_template =
    \\ {{
    \\   "type": "subscribe",
    \\   "channel": "{s}",
    \\   "product_ids": ["{s}"],
    \\   "jwt": "{s}"
    \\ }}
;

fn subscribe(
    self: *Self,
    comptime Listener: type,
    comptime channel: []const u8,
    ticker: []const u8,
    subscriptions: *std.StringHashMap(std.ArrayList(Listener)),
    listener: Listener,
) !void {
    if (subscriptions.getPtr(ticker)) |listeners| {
        try listeners.append(self.gpa, listener);
    } else {
        var buf: [512]u8 = undefined;
        const trades_message = std.fmt.bufPrint(
            &buf,
            subscribe_template,
            .{ channel, ticker, self.jwt },
        ) catch unreachable;
        try self.ws.send(.{ .text = @constCast(trades_message) });
        var listeners: std.ArrayList(Listener) = .empty;
        try listeners.append(self.gpa, listener);
        const ticker_owned = try self.gpa.dupe(u8, ticker);
        try subscriptions.put(ticker_owned, listeners);
    }
}

pub fn subscribeToTrades(
    self: *Self,
    ticker: []const u8,
    listener: types.TradeListener,
) !void {
    try self.subscribe(
        types.TradeListener,
        "market_trades",
        ticker,
        &self.trade_subscriptions,
        listener,
    );
}

pub fn subscribeToUpdates(
    self: *Self,
    ticker: []const u8,
    listener: types.UpdateListener,
) !void {
    try self.subscribe(
        types.UpdateListener,
        "level2",
        ticker,
        &self.update_subscriptions,
        listener,
    );
}

pub fn run(self: *Self) !void {
    // for (0..500) |_| {
    while (true) {
        const message = try self.ws.receive();
        defer message.deinit(self.gpa);

        switch (message) {
            .text => |msg| try self.handleMessage(msg),
            .ping => |payload| try self.ws.send(.{ .pong = payload }),
            else => return error.UnexpectedMessage,
        }
    }
}

fn handleMessage(self: *Self, message: []const u8) !void {
    const Update = struct {
        side: []const u8,
        event_time: []const u8,
        price_level: []const u8,
        new_quantity: []const u8,
    };
    const Trade = struct {
        product_id: []const u8,
        price: []const u8,
        size: []const u8,
        time: []const u8,
        side: []const u8,
    };
    const Event = struct {
        type: []const u8 = "", // only here for updates?
        product_id: []const u8 = "",
        updates: []const Update = &.{},
        trades: []const Trade = &.{},
    };
    const Message = struct {
        channel: []const u8,
        events: []const Event,
    };
    const parsed = try std.json.parseFromSlice(
        Message,
        self.gpa,
        message,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    for (parsed.value.events) |event| {
        for (event.trades) |trade| {
            const ticker = trade.product_id;
            if (self.trade_subscriptions.getPtr(ticker)) |listeners| {
                const maker_side = types.Side.parse(trade.side) orelse
                    return error.InvalidSide;
                const parsed_trade: types.Trade = .{
                    .ticker = ticker,
                    .ts = try .parseIso8601(trade.time),
                    .price = try .parse(trade.price),
                    .size = try .parse(trade.size),
                    .taker_side = maker_side.opposite(),
                };

                for (listeners.items) |listener| {
                    listener.notify(listener.ptr, parsed_trade);
                }
            }
        }

        for (event.updates) |update| {
            const ticker = event.product_id;
            if (self.update_subscriptions.getPtr(ticker)) |listeners| {
                const parsed_update: types.Update = .{
                    .ticker = ticker,
                    .ts = try .parseIso8601(update.event_time),
                    .price = try .parse(update.price_level),
                    .size = try .parse(update.new_quantity),
                    .kind = .set,
                    .side = types.Side.parse(update.side) orelse
                        return error.InvalidSide,
                };

                for (listeners.items) |listener| {
                    listener.notify(listener.ptr, parsed_update);
                }
            }
        }
    }
}

fn makeJwt(
    buf: []u8,
    key_id: []const u8,
    private_key_base64: []const u8,
    nonce: u128,
) ![]const u8 {
    var scratch: [512]u8 = undefined;

    const header = std.fmt.bufPrint(
        &scratch,
        \\{{"typ":"JWT","alg":"EdDSA","kid":"{s}","nonce":"{x:0>32}"}}
    ,
        .{ key_id, nonce },
    ) catch unreachable;
    var position =
        std.base64.url_safe_no_pad.Encoder.encode(buf, header).len;
    buf[position] = '.';
    position += 1;

    const payload = std.fmt.bufPrint(
        &scratch,
        \\{{"sub":"{s}","iss":"cdp"}}
    ,
        .{key_id},
    ) catch unreachable;
    position += std.base64.url_safe_no_pad.Encoder.encode(
        buf[position..],
        payload,
    ).len;

    var key: [64]u8 = undefined;
    std.base64.standard.Decoder.decode(&key, private_key_base64) catch
        return error.InvalidPirvateKey;

    const signature = try makeSignature(buf[0..position], &key);

    buf[position] = '.';
    position += 1;

    position += std.base64.url_safe_no_pad.Encoder.encode(
        buf[position..],
        &signature,
    ).len;

    return buf[0..position];
}

fn makeSignature(message: []const u8, key: []const u8) ![64]u8 {
    const c = @cImport({
        @cInclude("openssl/evp.h");
    });

    const pkey = c.EVP_PKEY_new_raw_private_key(
        c.EVP_PKEY_ED25519,
        null,
        key.ptr,
        32,
    ) orelse return error.OpenSslError;
    defer c.EVP_PKEY_free(pkey);

    const ctx = c.EVP_MD_CTX_new() orelse return error.OpenSslError;
    defer c.EVP_MD_CTX_free(ctx);

    if (c.EVP_DigestSignInit(ctx, null, null, null, pkey) != 1)
        return error.OpenSslError;

    var signature: [64]u8 = undefined;
    var signature_len = signature.len;
    if (c.EVP_DigestSign(ctx, &signature, &signature_len, message.ptr, message.len) != 1)
        return error.OpenSslError;

    return signature;
}
