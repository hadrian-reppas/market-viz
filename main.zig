const std = @import("std");
const TlsClient = std.crypto.tls.Client;

const buffer_len = TlsClient.min_buffer_len;

const WsClient = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    tcp_reader: std.Io.net.Stream.Reader,
    tcp_writer: std.Io.net.Stream.Writer,
    client: TlsClient,

    pub fn init(
        self: *WsClient,
        gpa: std.mem.Allocator,
        io: std.Io,
        host_name: []const u8,
        tcp_read_buffer: []u8,
        tcp_write_buffer: []u8,
        tls_read_buffer: []u8,
        tls_write_buffer: []u8,
    ) !void {
        self.gpa = gpa;
        self.io = io;

        const host = try std.Io.net.HostName.init(host_name);
        self.stream = try host.connect(io, 443, .{
            .mode = .stream,
            .protocol = .tcp,
        });
        errdefer self.stream.close(io);

        self.tcp_reader = self.stream.reader(io, tcp_read_buffer);
        self.tcp_writer = self.stream.writer(io, tcp_write_buffer);

        const now = std.Io.Clock.real.now(io);
        var bundle = std.crypto.Certificate.Bundle{ .map = .empty, .bytes = .empty };
        defer bundle.deinit(gpa);
        try bundle.rescan(gpa, io, now);
        var lock = std.Io.RwLock.init;
        var entropy: [TlsClient.Options.entropy_len]u8 = undefined;
        io.random(&entropy);

        self.client = try TlsClient.init(
            &self.tcp_reader.interface,
            &self.tcp_writer.interface,
            .{
                .host = .{ .explicit = host_name },
                .ca = .{ .bundle = .{
                    .gpa = gpa,
                    .io = io,
                    .lock = &lock,
                    .bundle = &bundle,
                } },
                .read_buffer = tls_read_buffer,
                .write_buffer = tls_write_buffer,
                .entropy = &entropy,
                .realtime_now = now,
                .allow_truncation_attacks = true,
            },
        );

        try self.client.writer.print(
            "GET / HTTP/1.1\r\n" ++
                "Host: {s}\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Version: 13\r\n" ++
                "Sec-WebSocket-Key: zig+test+zig+test+zig+==\r\n" ++
                "\r\n",
            .{host_name},
        );
        try self.client.writer.flush();
        try self.tcp_writer.interface.flush();

        const head = try receiveHead(&self.client.reader);
        try validateResponse(try .parse(head));
        _ = try self.client.reader.discard(.limited(head.len));
    }

    pub fn receive(self: *WsClient) !?Message {
        const header = try Header.fromInt(try self.client.reader.takeInt(u16, .little));
        const length = try header.getLength(&self.client.reader);

        if (!header.fin) {
            // TODO: combine multiple frames
            @panic("todo");
        }

        if (!header.opcode.validPayloadLength(length))
            return error.InvalidPayloadLength;

        if (header.opcode == .close) {
            @panic("todo");
            // return;
        }

        const payload = try self.client.reader.readAlloc(self.gpa, length);
        return switch (header.opcode) {
            .text => .{ .text = payload },
            .binary => .{ .binary = payload },
            .ping => .{ .ping = payload },
            .pong => .{ .pong = payload },
            else => unreachable,
        };
    }

    pub fn send(self: *WsClient, message: Message) !void {
        const mask = [_]u8{ 1, 2, 3, 4 };

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

    pub fn deinit(self: *WsClient) void {
        self.client.end() catch {};
        self.tcp_writer.interface.flush() catch {};
        self.stream.close(self.io);
        self.* = undefined;
    }
};

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

pub fn main(init: std.process.Init) !void {
    var tcp_read_buffer: [buffer_len]u8 = undefined;
    var tcp_write_buffer: [buffer_len]u8 = undefined;
    var tls_read_buffer: [buffer_len]u8 = undefined;
    var tls_write_buffer: [buffer_len]u8 = undefined;

    var ws: WsClient = undefined;
    try ws.init(
        init.gpa,
        init.io,
        "echo.websocket.org",
        &tcp_read_buffer,
        &tcp_write_buffer,
        &tls_read_buffer,
        &tls_write_buffer,
    );
    defer ws.deinit();

    if (try ws.receive()) |message| {
        defer message.deinit(init.gpa);
        std.debug.dumpHex(message.text);
    }

    try ws.send(.{ .ping = @constCast("hello") });

    if (try ws.receive()) |message| {
        defer message.deinit(init.gpa);
        std.debug.dumpHex(message.pong);
    }
}

const Header = packed struct(u16) {
    opcode: Opcode,
    rsv: u3 = 0,
    fin: bool,
    length: u7,
    mask: bool,

    pub fn fromInt(raw: u16) !Header {
        if (std.enums.fromInt(Opcode, @as(u4, @truncate(raw))) == null)
            return error.InvalidOpcode;
        const header: Header = @bitCast(raw);

        if (header.opcode == .continuation)
            return error.UnexpectedContinuation;
        if (!header.fin and !header.opcode.fragmentable())
            return error.FragmentedControlFrame;
        return header;
    }

    pub fn getLength(self: Header, reader: *std.Io.Reader) !u64 {
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

    pub fn fragmentable(self: Opcode) bool {
        return switch (self) {
            .continuation => unreachable,
            .text, .binary => true,
            .close, .ping, .pong => false,
        };
    }

    pub fn validPayloadLength(self: Opcode, length: u64) bool {
        if (self == .close and length == 1)
            return false;
        return length <= self.maxPayloadLength();
    }

    pub fn maxPayloadLength(self: Opcode) u64 {
        return switch (self) {
            .continuation, .text, .binary => (1 << 63) - 1,
            .close, .ping, .pong => 125,
        };
    }
};

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

fn validateResponse(head: std.http.Client.Response.Head) !void {
    // TODO: check Sec-Websocket-Accept
    // TODO: check for (and reject) extensions
    // TODO: check for (and reject) subprotocol
    const eql = std.ascii.eqlIgnoreCase;

    if (head.status != .switching_protocols)
        return error.HandshakeFailed;

    var seen_upgrade = false;
    var seen_connection = false;

    var iterator = head.iterateHeaders();
    while (iterator.next()) |header| {
        if (eql(header.name, "Upgrade")) {
            if (eql(header.value, "websocket")) {
                seen_upgrade = true;
            } else {
                return error.HandshakeFailed;
            }
        } else if (std.ascii.eqlIgnoreCase(header.name, "Connection")) {
            if (eql(header.value, "upgrade")) {
                seen_connection = true;
            } else {
                return error.HandshakeFailed;
            }
        }
    }

    if (!seen_upgrade or !seen_connection)
        return error.HandshakeFailed;
}
