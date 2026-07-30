const std = @import("std");
const Allocator = std.mem.Allocator;
const WebSocket = @import("WebSocket.zig");
const types = @import("../market/types.zig");

gpa: Allocator,
ws: *WebSocket,
jwt: []u8,

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
    };
}

pub fn deinit(self: *Self) void {
    self.gpa.free(self.jwt);
    self.ws.deinit();
    self.* = undefined;
}

pub fn subscribe(self: *Self) !void {
    const template =
        \\ {{
        \\   "type": "subscribe",
        \\   "channel": "level2",
        \\   "product_ids": ["BTC-USD"],
        \\   "jwt": "{s}"
        \\ }}
    ;

    var buf: [512]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, template, .{self.jwt}) catch unreachable;
    try self.ws.send(.{ .text = @constCast(message) });

    // TODO: update subscribed hash map
}

pub fn run(self: *Self) !void {
    while (true) {
        const message = try self.ws.receive();
        defer message.deinit(self.gpa);

        switch (message) {
            .text => |msg| {
                const Update = struct {
                    side: []const u8,
                    event_time: []const u8,
                    price_level: []const u8,
                    new_quantity: []const u8,
                };
                const Message = struct {
                    channel: []const u8,
                    timestamp: []const u8,
                    events: []const struct {
                        type: []const u8 = "",
                        product_id: []const u8 = "",
                        updates: []const Update = &.{},
                    },
                };
                const parsed = try std.json.parseFromSlice(
                    Message,
                    self.gpa,
                    msg,
                    .{ .ignore_unknown_fields = true },
                );
                defer parsed.deinit();
                for (parsed.value.events) |event| {
                    for (event.updates) |update| {
                        const parsed_update: types.Update = .{
                            .ticker = event.product_id,
                            .ts = try .parseIso8601(update.event_time),
                            .price = try .parse(update.price_level),
                            .size = try .parse(update.new_quantity),
                            .kind = .set,
                            .side = types.Side.parse(update.side) orelse
                                return error.InvalidSide,
                        };

                        std.debug.print("{}\n", .{parsed_update});
                    }
                }
            },
            .ping => |payload| try self.ws.send(.{ .pong = payload }),
            else => return error.UnexpectedMessage,
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
