const std = @import("std");
const Allocator = std.mem.Allocator;
const WebSocket = @import("WebSocket.zig");
const types = @import("../market/types.zig");
const util = @import("../util.zig");

gpa: Allocator,
ws: *WebSocket,
jwt: []u8,
trade_subscriptions: util.Subscriptions(types.TradeListener),
update_subscriptions: util.Subscriptions(types.UpdateListener),

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

    self.trade_subscriptions.deinit();
    self.update_subscriptions.deinit();

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

pub fn subscribeToTrades(
    self: *Self,
    ticker: []const u8,
    listener: types.TradeListener,
) !void {
    const new = try self.trade_subscriptions.insert(ticker, listener);
    if (new) {
        var buf: [512]u8 = undefined;
        const message = std.fmt.bufPrint(
            &buf,
            subscribe_template,
            .{ "market_trades", ticker, self.jwt },
        ) catch unreachable;
        // TODO: check for response?
        try self.ws.send(.{ .text = @constCast(message) });
    }
}

pub fn subscribeToUpdates(
    self: *Self,
    ticker: []const u8,
    listener: types.UpdateListener,
) !void {
    const new = try self.update_subscriptions.insert(ticker, listener);
    if (new) {
        var buf: [512]u8 = undefined;
        const message = std.fmt.bufPrint(
            &buf,
            subscribe_template,
            .{ "level2", ticker, self.jwt },
        ) catch unreachable;
        // TODO: check for response?
        try self.ws.send(.{ .text = @constCast(message) });
    }
}

pub fn run(self: *Self) !void {
    while (true) {
        const message = self.ws.receive() catch |err| {
            if (self.ws.wasCanceled()) return error.Canceled;
            return err;
        };
        defer message.deinit(self.gpa);

        switch (message) {
            .text => |msg| try self.handleMessage(msg),
            .ping => |payload| try self.ws.send(.{ .pong = payload }),
            else => return error.UnexpectedMessage,
        }
    }
}

const CoinbaseMessage = struct {
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
        type: []const u8 = "",
        product_id: []const u8 = "",
        updates: []const Update = &.{},
        trades: []const Trade = &.{},
    };

    channel: []const u8,
    events: []const Event,
};

fn handleMessage(self: *Self, message: []const u8) !void {
    const parsed = try std.json.parseFromSlice(
        CoinbaseMessage,
        self.gpa,
        message,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    for (parsed.value.events) |event| {
        try self.handleTrades(event.trades);
        try self.handleUpdates(event.product_id, event.updates);
    }
}

fn handleTrades(self: *Self, trades: []const CoinbaseMessage.Trade) !void {
    for (trades) |trade| {
        const ticker = trade.product_id;
        if (self.trade_subscriptions.get(ticker)) |listeners| {
            const maker_side: types.Side = try .parse(trade.side);
            const parsed_trade: types.Trade = .{
                .ticker = ticker,
                .ts = try .parseIso8601(trade.time),
                .price = try .parse(trade.price),
                .size = try .parse(trade.size),
                .taker_side = maker_side.opposite(),
            };

            for (listeners.items) |listener| {
                listener.notify(parsed_trade);
            }
        }
    }
}

fn handleUpdates(
    self: *const Self,
    ticker: []const u8,
    updates: []const CoinbaseMessage.Update,
) !void {
    for (updates) |update| {
        if (self.update_subscriptions.get(ticker)) |listeners| {
            const parsed_update: types.Update = .{
                .ticker = ticker,
                .ts = try .parseIso8601(update.event_time),
                .price = try .parse(update.price_level),
                .size = try .parse(update.new_quantity),
                .kind = .set,
                .side = try .parse(update.side),
            };

            for (listeners.items) |listener| {
                listener.notify(parsed_update);
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
