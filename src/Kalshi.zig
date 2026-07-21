const std = @import("std");
const Allocator = std.mem.Allocator;
const WebSocket = @import("WebSocket.zig");
const types = @import("types.zig");

gpa: Allocator,
ws: *WebSocket,
subscriptions: types.TickerHashMap(std.ArrayList(Listener)),

const Self = @This();

pub const Options = struct {
    key_id: []const u8,
    private_key_pem: []const u8,
};

pub const Listener = struct {
    ptr: *anyopaque,
    notify: *const fn (*anyopaque, types.Trade) void,
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
        .host = "external-api-ws.kalshi.com",
        .path = "/trade-api/ws/v2",
        .extra_headers = headers,
    });

    return .{
        .gpa = gpa,
        .ws = ws,
        .subscriptions = .empty,
    };
}

pub fn deinit(self: *Self) void {
    self.ws.deinit();
    self.gpa.destroy(self.ws);
    var it = self.subscriptions.iterator();
    while (it.next()) |e| e.value_ptr.deinit(self.gpa);
    self.subscriptions.deinit(self.gpa);
    self.* = undefined;
}

pub fn subscribe(self: *Self, ticker: types.Ticker, listener: Listener) !void {
    const template =
        \\ {{
        \\   "id": 1,
        \\   "cmd": "subscribe",
        \\   "params": {{
        \\     "channels": ["trade"],
        \\     "market_tickers": ["{s}"]
        \\   }}
        \\ }}
    ;
    if (self.subscriptions.getPtr(ticker)) |a| {
        try a.append(self.gpa, listener);
    } else {
        // TODO: check response?
        var buf: [template.len + types.Ticker.max_len]u8 = undefined;
        const message = std.fmt.bufPrint(&buf, template, .{ticker.get()}) catch unreachable;
        try self.ws.send(.{ .text = @constCast(message) });
        var array: std.ArrayList(Listener) = .empty;
        try array.append(self.gpa, listener);
        try self.subscriptions.put(self.gpa, ticker, array);
    }
}

pub fn run(self: *Self) !void {
    while (true) {
        const message = try self.ws.receive();
        defer message.deinit(self.gpa);

        switch (message) {
            .text => |msg| try self.handleMessage(msg),
            .ping => |payload| try self.ws.send(.{ .pong = payload }),
            else => {}, // TODO
        }
    }
}

fn handleMessage(self: *Self, message: []const u8) !void {
    const msg_type = try getMessageType(self.gpa, message);
    if (msg_type != .trade) return; // TODO

    const trade = try types.Trade.parse(self.gpa, message);

    if (self.subscriptions.getPtr(trade.ticker)) |p| {
        for (p.items) |listener| {
            listener.notify(listener.ptr, trade);
        }
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

    return std.meta.stringToEnum(MessageType, parsed.value.type) orelse .unknown;
}

const MessageType = enum {
    subscribed,
    trade,
    @"error",
    unknown,
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
    ) orelse return error.OpenSslFailure;
    defer _ = c.BIO_free(bio);

    const key = c.PEM_read_bio_PrivateKey(bio, null, null, null) orelse
        return error.InvalidPrivateKey;
    defer c.EVP_PKEY_free(key);

    const md_ctx = c.EVP_MD_CTX_new() orelse
        return error.OpenSslFailure;
    defer c.EVP_MD_CTX_free(md_ctx);

    var rsa_ctx_opt: ?*c.EVP_PKEY_CTX = null;
    if (c.EVP_DigestSignInit(md_ctx, &rsa_ctx_opt, c.EVP_sha256(), null, key) <= 0)
        return error.OpenSslFailure;
    const rsa_ctx = rsa_ctx_opt orelse return error.OpenSslFailure;

    if (c.EVP_PKEY_CTX_set_rsa_padding(rsa_ctx, c.RSA_PKCS1_PSS_PADDING) <= 0)
        return error.OpenSslFailure;
    if (c.EVP_PKEY_CTX_set_rsa_pss_saltlen(rsa_ctx, c.RSA_PSS_SALTLEN_DIGEST) <= 0)
        return error.OpenSslFailure;
    if (c.EVP_PKEY_CTX_set_rsa_mgf1_md(rsa_ctx, c.EVP_sha256()) <= 0)
        return error.OpenSslFailure;

    var signature: [256]u8 = undefined;
    var signature_len: usize = signature.len;
    if (c.EVP_DigestSign(
        md_ctx,
        &signature,
        &signature_len,
        message.ptr,
        message.len,
    ) <= 0)
        return error.OpenSslFailure;
    if (signature_len != signature.len) return error.OpenSslFailure;

    return signature;
}
