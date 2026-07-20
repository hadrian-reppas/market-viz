const std = @import("std");
const TlsClient = std.crypto.tls.Client;
const Allocator = std.mem.Allocator;

pub const buffer_len = std.math.ceilPowerOfTwoAssert(usize, TlsClient.min_buffer_len);

gpa: Allocator,
io: std.Io,
stream: std.Io.net.Stream,
tcp_reader: std.Io.net.Stream.Reader,
tcp_writer: std.Io.net.Stream.Writer,
client: TlsClient,
owned_buffer: ?[]u8,
rng: std.Random.DefaultPrng,

const Self = @This();

pub const Options = struct {
    pub const Buffers = struct {
        tcp_read: []u8,
        tcp_write: []u8,
        tls_read: []u8,
        tls_write: []u8,
    };

    host: []const u8,
    port: u16 = 443,
    bundle: ?*std.crypto.Certificate.Bundle = null,
    buffers: ?Buffers = null,
};

pub fn init(
    self: *Self,
    gpa: Allocator,
    io: std.Io,
    options: Options,
) !void {
    self.gpa = gpa;
    self.io = io;

    const host = try std.Io.net.HostName.init(options.host);
    self.stream = try host.connect(io, options.port, .{
        .mode = .stream,
        .protocol = .tcp,
    });
    errdefer self.stream.close(io);

    const buffers = blk: {
        if (options.buffers) |b| {
            self.owned_buffer = null;
            break :blk b;
        }
        const buf = try gpa.alloc(u8, 4 * buffer_len);
        self.owned_buffer = buf;
        break :blk Options.Buffers{
            .tcp_read = buf[0..buffer_len],
            .tcp_write = buf[buffer_len .. 2 * buffer_len],
            .tls_read = buf[2 * buffer_len .. 3 * buffer_len],
            .tls_write = buf[3 * buffer_len ..],
        };
    };

    self.tcp_reader = self.stream.reader(io, buffers.tcp_read);
    self.tcp_writer = self.stream.writer(io, buffers.tcp_write);

    const now = std.Io.Clock.real.now(io);

    var default_bundle: std.crypto.Certificate.Bundle = .{ .map = .empty, .bytes = .empty };
    defer if (options.bundle == null) default_bundle.deinit(gpa);

    const bundle = blk: {
        if (options.bundle) |b| break :blk b;
        try default_bundle.rescan(gpa, io, now);
        break :blk &default_bundle;
    };

    var entropy: [8 + 16 + TlsClient.Options.entropy_len]u8 = undefined;
    io.random(&entropy);
    const seed = std.mem.readInt(u64, entropy[0..8], .little);
    self.rng = .init(seed);
    const key = entropy[8 .. 8 + 16];

    var lock = std.Io.RwLock.init;

    self.client = try TlsClient.init(
        &self.tcp_reader.interface,
        &self.tcp_writer.interface,
        .{
            .host = .{ .explicit = options.host },
            .ca = .{ .bundle = .{
                .gpa = gpa,
                .io = io,
                .lock = &lock,
                .bundle = bundle,
            } },
            .read_buffer = buffers.tls_read,
            .write_buffer = buffers.tls_write,
            .entropy = entropy[8 + 16 ..],
            .realtime_now = now,
            .allow_truncation_attacks = true,
        },
    );

    var key_base64: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&key_base64, key);

    var host_port_buffer: [6]u8 = undefined;
    const host_port = if (options.port != 443)
        std.fmt.bufPrint(&host_port_buffer, ":{}", .{options.port}) catch unreachable
    else
        "";

    try self.client.writer.print(
        "GET / HTTP/1.1\r\n" ++
            "Host: {s}{s}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "\r\n",
        .{ options.host, host_port, key_base64 },
    );
    try self.client.writer.flush();
    try self.tcp_writer.interface.flush();

    const head = try receiveHead(&self.client.reader);
    try validateHttpResponse(try .parse(head), &key_base64);
    _ = try self.client.reader.discard(.limited(head.len));
}

fn receiveHead(reader: *std.Io.Reader) ![]const u8 {
    var head_len: usize = 0;
    var hp = std.http.HeadParser{};
    while (true) {
        if (head_len >= buffer_len) return error.HttpHeadersOversize;
        const remaining = reader.buffered()[head_len..];
        if (remaining.len == 0) {
            try reader.fillMore();
            continue;
        }
        head_len += hp.feed(remaining);
        if (hp.state == .finished)
            return reader.buffered()[0..head_len];
    }
}

fn validateHttpResponse(head: std.http.Client.Response.Head, key: []const u8) !void {
    const eql = std.ascii.eqlIgnoreCase;
    const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

    if (head.status != .switching_protocols)
        return error.HandshakeFailed;

    var concat_buffer: [24 + guid.len]u8 = undefined;
    const concat = std.fmt.bufPrint(&concat_buffer, "{s}{s}", .{ key, guid }) catch unreachable;
    var hashed: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(concat, &hashed, .{});
    var base64_buffer: [28]u8 = undefined;
    const expected_accept_value = std.base64.standard.Encoder.encode(&base64_buffer, &hashed);

    var seen_upgrade = false;
    var seen_connection = false;
    var seen_accept = false;

    var iterator = head.iterateHeaders();
    while (iterator.next()) |header| {
        if (eql(header.name, "Upgrade") and eql(header.value, "websocket")) {
            seen_upgrade = true;
        } else if (eql(header.name, "Connection") and eql(header.value, "upgrade")) {
            seen_connection = true;
        } else if (eql(header.name, "Sec-WebSocket-Accept") and
            std.mem.eql(u8, header.value, expected_accept_value))
        {
            seen_accept = true;
        } else if (eql(header.name, "Sec-WebSocket-Extensions") or
            eql(header.name, "Sec-WebSocket-Protocol"))
        {
            return error.HandshakeFailed;
        }
    }

    if (!seen_upgrade or !seen_connection or !seen_accept)
        return error.HandshakeFailed;
}

pub fn deinit(self: *Self) void {
    self.client.end() catch {};
    self.tcp_writer.interface.flush() catch {};
    self.stream.close(self.io);
    if (self.owned_buffer) |buffer| self.gpa.free(buffer);
    self.* = undefined;
}

pub const Message = union(enum) {
    pub const Close = struct {
        code: u16,
        reason: []u8,
    };

    text: []u8,
    binary: []u8,
    ping: []u8,
    pong: []u8,
    close: ?Close,

    pub fn deinit(self: Message, gpa: std.mem.Allocator) void {
        switch (self) {
            .text, .binary, .ping, .pong => |payload| gpa.free(payload),
            .close => |close| if (close) |c| {
                gpa.free(c.reason);
            },
        }
    }

    pub fn opcode(self: Message) Opcode {
        return switch (self) {
            .text => .text,
            .binary => .binary,
            .ping => .ping,
            .pong => .pong,
            .close => .close,
        };
    }

    pub fn payloadLength(self: Message, length_buffer: *[8]u8) struct { header: u7, buffer: []u8 } {
        const length = switch (self) {
            .text, .binary, .ping, .pong => |payload| payload.len,
            .close => |close| if (close) |c| c.reason.len + 2 else 0,
        };
        std.debug.assert(self.opcode().validPayloadLength(length));
        switch (length) {
            0...125 => return .{ .header = @intCast(length), .buffer = length_buffer[0..0] },
            126...std.math.maxInt(u16) => {
                std.mem.writeInt(u16, length_buffer[0..2], @intCast(length), .big);
                return .{ .header = 126, .buffer = length_buffer[0..2] };
            },
            else => {
                std.mem.writeInt(u64, length_buffer, length, .big);
                return .{ .header = 122, .buffer = length_buffer };
            },
        }
    }
};

pub fn receive(self: *Self) !Message {
    const header = try self.receiveHeader(.start);
    const length = try header.getLength(&self.client.reader);

    if (!header.opcode.validPayloadLength(length))
        return error.InvalidPayloadLength;

    switch (header.opcode) {
        .close => {
            if (length == 0) return .{ .close = null };
            const code = try self.client.reader.takeInt(u16, .big);
            const reason = try self.client.reader.readAlloc(self.gpa, length - 2);
            return .{ .close = .{ .code = code, .reason = reason } };
        },
        .ping => return .{ .ping = try self.client.reader.readAlloc(self.gpa, length) },
        .pong => return .{ .pong = try self.client.reader.readAlloc(self.gpa, length) },
        .text => return .{ .text = try self.receiveDataPayload(header, length) },
        .binary => return .{ .binary = try self.receiveDataPayload(header, length) },
        .continuation => unreachable,
    }
}

fn receiveHeader(self: *Self, kind: enum { start, continuation }) !Header {
    const raw = try self.client.reader.takeInt(u16, .little);
    if (std.enums.fromInt(Opcode, @as(u4, @truncate(raw))) == null)
        return error.InvalidOpcode;
    const header: Header = @bitCast(raw);

    switch (kind) {
        .start => if (header.opcode == .continuation)
            return error.UnexpectedContinuation,
        .continuation => if (header.opcode != .continuation)
            return error.ExpectedContinuation,
    }
    if (!header.fin and header.opcode != .continuation and !header.opcode.fragmentable())
        return error.FragmentedControlFrame;

    return header;
}

fn receiveDataPayload(self: *Self, first: Header, first_length: u64) ![]u8 {
    var payload: []u8 = &.{};
    errdefer self.gpa.free(payload);

    var fin = first.fin;
    var length = first_length;
    while (true) {
        const len: usize = @intCast(length);
        const old_len = payload.len;
        payload = try self.gpa.realloc(payload, old_len + len);
        try self.client.reader.readSliceAll(payload[old_len..][0..len]);
        if (fin) return payload;

        const header = try self.receiveHeader(.continuation);
        length = try header.getLength(&self.client.reader);
        if (!header.opcode.validPayloadLength(length))
            return error.InvalidPayloadLength;
        fin = header.fin;
    }
}

pub fn send(self: *Self, message: Message) !void {
    var mask: [4]u8 = undefined;
    self.rng.fill(&mask);

    var length_buffer: [8]u8 = undefined;
    const length = message.payloadLength(&length_buffer);
    const header: Header = .{
        .opcode = message.opcode(),
        .fin = true,
        .length = length.header,
        .mask = true,
    };
    const header_u16: u16 = @bitCast(header);
    try self.client.writer.writeInt(u16, header_u16, .little);
    try self.client.writer.writeAll(length.buffer);
    try self.client.writer.writeAll(&mask);

    switch (message) {
        .text, .binary, .ping, .pong => |payload| try writeMasked(&self.client.writer, payload, mask, 0),
        .close => |close| if (close) |c| {
            var code: [2]u8 = undefined;
            std.mem.writeInt(u16, &code, c.code, .big);
            try writeMasked(&self.client.writer, &code, mask, 0);
            try writeMasked(&self.client.writer, c.reason, mask, 2);
        },
    }

    try self.client.writer.flush();
    try self.tcp_writer.interface.flush();
}

fn writeMasked(writer: *std.Io.Writer, payload: []const u8, mask: [4]u8, offset: usize) !void {
    var scratch: [1024]u8 = undefined;
    var payload_offset: usize = 0;

    while (payload_offset < payload.len) {
        const n = @min(scratch.len, payload.len - payload_offset);
        for (0..n) |i| {
            const mask_byte = mask[(payload_offset + offset + i) % 4];
            scratch[i] = payload[payload_offset + i] ^ mask_byte;
        }
        try writer.writeAll(scratch[0..n]);
        payload_offset += n;
    }
}

const Header = packed struct(u16) {
    opcode: Opcode,
    rsv: u3 = 0,
    fin: bool,
    length: u7,
    mask: bool,

    fn getLength(self: Header, reader: *std.Io.Reader) !u64 {
        return switch (self.length) {
            0...125 => self.length,
            126 => try reader.takeInt(u16, .big),
            127 => try reader.takeInt(u64, .big),
        };
    }
};

const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,

    fn fragmentable(self: Opcode) bool {
        return switch (self) {
            .continuation => unreachable,
            .text, .binary => true,
            .close, .ping, .pong => false,
        };
    }

    fn validPayloadLength(self: Opcode, length: u64) bool {
        if (self == .close and length == 1)
            return false;
        return length <= self.maxPayloadLength();
    }

    fn maxPayloadLength(self: Opcode) u64 {
        return switch (self) {
            .continuation, .text, .binary => (1 << 63) - 1,
            .close, .ping, .pong => 125,
        };
    }
};
