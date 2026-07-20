const std = @import("std");
const WebSocket = @import("WebSocket.zig");

gpa: std.mem.Allocator,
ws: *WebSocket,

const Self = @This();

pub const Options = struct {
    key_id: []const u8,
    private_key_pem: []const u8,
};

pub fn init(gpa: std.mem.Allocator, io: std.Io, options: Options) !Self {
    const now = std.Io.Clock.real.now(io).toMilliseconds();

    var message_buffer: [32]u8 = undefined;
    const message = std.fmt.bufPrint(
        &message_buffer,
        "{}GET/trade-api/ws/v2",
        .{now},
    ) catch unreachable;

    var timestamp_buffer: [16]u8 = undefined;
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
    };
}

pub fn deinit(self: *Self) void {
    self.ws.deinit();
    self.gpa.destroy(self.ws);
    self.* = undefined;
}

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
