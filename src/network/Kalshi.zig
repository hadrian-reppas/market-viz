const std = @import("std");
const Allocator = std.mem.Allocator;
const WebSocket = @import("WebSocket.zig");
const types = @import("../market/types.zig");

gpa: Allocator,
ws: *WebSocket,
msg_id: u32,
// subscriptions: std.StringHashMap(std.ArrayList(types.TradeListener)),

const Self = @This();

pub const Options = struct {
    key_id: []const u8,
    private_key_pem: []const u8,
    host: []const u8 = "external-api-ws.kalshi.com",
    port: u16 = 443,
    path: []const u8 = "/trade-api/ws/v2",
    bundle: ?*std.crypto.Certificate.Bundle = null,
};

pub fn init(gpa: Allocator, io: std.Io, options: Options) !Self {
    const message_fmt = "{}GET/trade-api/ws/v2";

    const now = std.Io.Clock.real.now(io).toMilliseconds();

    const max_size = comptime std.fmt.count(message_fmt, .{std.math.maxInt(@TypeOf(now))});
    var message_buffer: [max_size]u8 = undefined;
    const message = std.fmt.bufPrint(&message_buffer, message_fmt, .{now}) catch unreachable;

    var timestamp_buffer: [max_size]u8 = undefined;
    const timestamp_len = std.fmt.printInt(&timestamp_buffer, now, 10, .lower, .{});
    const timestamp = timestamp_buffer[0..timestamp_len];

    const signature_raw = try signMessage(options.private_key_pem, message);
    var signature_buffer: [std.base64.standard.Encoder.calcSize(signature_raw.len)]u8 = undefined;
    const signature = std.base64.standard.Encoder.encode(&signature_buffer, &signature_raw);

    const headers: []const std.http.Header = &.{
        .{ .name = "KALSHI-ACCESS-KEY", .value = options.key_id },
        .{ .name = "KALSHI-ACCESS-SIGNATURE", .value = signature },
        .{ .name = "KALSHI-ACCESS-TIMESTAMP", .value = timestamp },
    };

    const ws = try gpa.create(WebSocket);
    errdefer gpa.destroy(ws);
    try ws.init(gpa, io, .{
        .host = options.host,
        .port = options.port,
        .path = options.path,
        .extra_headers = headers,
        .bundle = options.bundle,
    });

    return .{
        .gpa = gpa,
        .ws = ws,
        .msg_id = 1,
        // .subscriptions = .init(gpa),
    };
}

pub fn deinit(self: *Self) void {
    // TODO: send close message?
    self.ws.deinit();
    self.gpa.destroy(self.ws);

    // var it = self.subscriptions.iterator();
    // while (it.next()) |e| e.value_ptr.deinit(self.gpa);
    // self.subscriptions.deinit(self.gpa);

    self.* = undefined;
}

pub fn subscribe(self: *Self, ticker: []const u8) !void {
    const template =
        \\ {{
        \\   "id": {},
        \\   "cmd": "subscribe",
        \\   "params": {{
        \\     "channels": ["{s}"],
        \\     "market_tickers": ["{s}"]
        \\   }}
        \\ }}
    ;

    // TODO: use update_subscription with add_markets?
    // TODO: check for response?
    var buf: [512]u8 = undefined;
    const trade_message = std.fmt.bufPrint(
        &buf,
        template,
        .{ self.msg_id, "trade", ticker },
    ) catch unreachable;
    self.msg_id += 1;
    try self.ws.send(.{ .text = @constCast(trade_message) });

    const orderbook_message = std.fmt.bufPrint(
        &buf,
        template,
        .{ self.msg_id, "orderbook_delta", ticker },
    ) catch unreachable;
    self.msg_id += 1;
    try self.ws.send(.{ .text = @constCast(orderbook_message) });

    // var array: std.ArrayList(Listener) = .empty;
    // try array.append(self.gpa, listener);
    // try self.subscriptions.put(self.gpa, ticker, array);
}

pub fn run(self: *Self) !void {
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
    switch (try getMessageType(self.gpa, message)) {
        .trade => {
            const Trade = struct {
                market_ticker: []const u8,
                yes_price_dollars: []const u8,
                count_fp: []const u8,
                taker_outcome_side: []const u8,
                ts_ms: u64,
            };
            const parsed = try std.json.parseFromSlice(
                struct { msg: Trade },
                self.gpa,
                message,
                .{ .ignore_unknown_fields = true },
            );
            defer parsed.deinit();
            const msg = parsed.value.msg;
            const parsed_trade: types.Trade = .{
                .ticker = msg.market_ticker,
                .ts = .fromMilliseconds(msg.ts_ms),
                .price = try .parse(msg.yes_price_dollars),
                .size = try .parse(msg.count_fp),
                .taker_side = types.Side.parse(msg.taker_outcome_side) orelse
                    return error.InvalidSide,
            };

            std.debug.print("trade = {}\n", .{parsed_trade});
        },
        .orderbook_snapshot => {
            const Snapshot = struct {
                market_ticker: []const u8,
                no_dollars_fp: []const struct { []const u8, []const u8 },
                yes_dollars_fp: []const struct { []const u8, []const u8 },
            };
            const parsed = try std.json.parseFromSlice(
                struct { msg: Snapshot },
                self.gpa,
                message,
                .{ .ignore_unknown_fields = true },
            );
            defer parsed.deinit();
            const msg = parsed.value.msg;
            for (msg.no_dollars_fp) |entry| {
                const parsed_update: types.Update = .{
                    .ticker = msg.market_ticker,
                    .ts = .zero,
                    .price = try .parse(entry.@"0"),
                    .size = try .parse(entry.@"1"),
                    .kind = .set,
                    .side = .sell,
                };
                std.debug.print("update = {}\n", .{parsed_update});
            }
            for (msg.yes_dollars_fp) |entry| {
                const parsed_update: types.Update = .{
                    .ticker = msg.market_ticker,
                    .ts = .zero,
                    .price = try .parse(entry.@"0"),
                    .size = try .parse(entry.@"1"),
                    .kind = .set,
                    .side = .buy,
                };
                std.debug.print("update = {}\n", .{parsed_update});
            }
        },
        .orderbook_delta => {
            const Update = struct {
                delta_fp: []const u8,
                market_ticker: []const u8,
                price_dollars: []const u8,
                side: []const u8,
                ts_ms: u64,
            };
            const parsed = try std.json.parseFromSlice(
                struct { msg: Update },
                self.gpa,
                message,
                .{ .ignore_unknown_fields = true },
            );
            defer parsed.deinit();
            const msg = parsed.value.msg;

            var size = msg.delta_fp;
            var kind = types.Update.Kind.add;
            if (size[0] == '-') {
                size = size[1..];
                kind = .sub;
            }

            const parsed_update: types.Update = .{
                .ticker = msg.market_ticker,
                .ts = .fromMilliseconds(msg.ts_ms),
                .price = try .parse(msg.price_dollars),
                .size = try .parse(size),
                .kind = kind,
                .side = types.Side.parse(msg.side) orelse
                    return error.InvalidSide,
            };
            std.debug.print("update = {}\n", .{parsed_update});
        },
        .subscribed => {},
    }
}

fn getMessageType(gpa: Allocator, json: []const u8) !MessageType {
    const parsed = try std.json.parseFromSlice(
        struct { type: []const u8 },
        gpa,
        json,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    return std.meta.stringToEnum(MessageType, parsed.value.type) orelse
        error.UnexpectedKalshiMessageType;
}

const MessageType = enum {
    subscribed,
    trade,
    orderbook_snapshot,
    orderbook_delta,
};

fn signMessage(private_key_pem: []const u8, message: []const u8) ![256]u8 {
    const c = @cImport({
        @cInclude("openssl/bio.h");
        @cInclude("openssl/evp.h");
        @cInclude("openssl/pem.h");
        @cInclude("openssl/rsa.h");
    });

    std.debug.assert(private_key_pem.len <= std.math.maxInt(c_int));
    const bio = c.BIO_new_mem_buf(
        private_key_pem.ptr,
        @intCast(private_key_pem.len),
    ) orelse return error.OpenSslError;
    defer _ = c.BIO_free(bio);

    const key = c.PEM_read_bio_PrivateKey(bio, null, null, null) orelse
        return error.InvalidPrivateKey;
    defer c.EVP_PKEY_free(key);

    const md_ctx = c.EVP_MD_CTX_new() orelse
        return error.OpenSslError;
    defer c.EVP_MD_CTX_free(md_ctx);

    var rsa_ctx_opt: ?*c.EVP_PKEY_CTX = null;
    if (c.EVP_DigestSignInit(md_ctx, &rsa_ctx_opt, c.EVP_sha256(), null, key) <= 0)
        return error.OpenSslError;
    const rsa_ctx = rsa_ctx_opt orelse return error.OpenSslError;

    if (c.EVP_PKEY_CTX_set_rsa_padding(rsa_ctx, c.RSA_PKCS1_PSS_PADDING) <= 0)
        return error.OpenSslError;
    if (c.EVP_PKEY_CTX_set_rsa_pss_saltlen(rsa_ctx, c.RSA_PSS_SALTLEN_DIGEST) <= 0)
        return error.OpenSslError;
    if (c.EVP_PKEY_CTX_set_rsa_mgf1_md(rsa_ctx, c.EVP_sha256()) <= 0)
        return error.OpenSslError;

    var signature: [256]u8 = undefined;
    var signature_len: usize = signature.len;
    if (c.EVP_DigestSign(
        md_ctx,
        &signature,
        &signature_len,
        message.ptr,
        message.len,
    ) <= 0)
        return error.OpenSslError;
    if (signature_len != signature.len) return error.OpenSslError;

    return signature;
}
