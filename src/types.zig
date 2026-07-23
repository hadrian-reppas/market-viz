const std = @import("std");

pub const Trade = struct {
    pub const Raw = struct {
        trade_id: []const u8,
        market_ticker: []const u8,
        yes_price_dollars: []const u8,
        no_price_dollars: []const u8,
        count_fp: []const u8,
        taker_outcome_side: []const u8,
        ts_ms: u64,
    };

    id: Uuid,
    ticker: Ticker,
    yes_price: Price,
    no_price: Price,
    size: Size,
    taker_side: Side,
    ts: Ts,

    pub fn parse(gpa: std.mem.Allocator, json: []const u8) !Trade {
        const parsed = try std.json.parseFromSlice(
            struct { msg: Trade.Raw },
            gpa,
            json,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();
        const raw = parsed.value.msg;
        return .{
            .id = try .parse(raw.trade_id),
            .ticker = try .init(raw.market_ticker),
            .yes_price = try .parse(raw.yes_price_dollars),
            .no_price = try .parse(raw.no_price_dollars),
            .size = try .parse(raw.count_fp),
            .taker_side = std.meta.stringToEnum(Side, raw.taker_outcome_side) orelse
                return error.InvalidSide,
            .ts = raw.ts_ms,
        };
    }

    pub fn notional(self: Trade, side: Side) Notional {
        comptime std.debug.assert(Price.scale * Size.scale == Notional.scale);
        const price = switch (side) {
            .yes => self.yes_price.value,
            .no => self.no_price.value,
        };
        return .{ .value = price * self.size.value };
    }
};

pub const Ts = u64;

pub const Ticker = struct {
    pub const max_len = 64;

    buffer: [max_len]u8,
    len: u8,

    pub fn init(ticker: []const u8) !Ticker {
        // TODO: more validation?
        if (ticker.len > max_len) return error.TickerOversize;
        var buffer: [max_len]u8 = undefined;
        @memcpy(buffer[0..ticker.len], ticker);
        return .{ .buffer = buffer, .len = @intCast(ticker.len) };
    }

    pub fn str(self: *const Ticker) []const u8 {
        return self.buffer[0..self.len];
    }
};

pub fn TickerHashMap(comptime V: type) type {
    return std.HashMapUnmanaged(
        Ticker,
        V,
        struct {
            pub fn hash(_: @This(), t: Ticker) u64 {
                return std.hash_map.hashString(t.str());
            }

            pub fn eql(_: @This(), a: Ticker, b: Ticker) bool {
                return std.hash_map.eqlString(a.str(), b.str());
            }
        },
        std.hash_map.default_max_load_percentage,
    );
}

pub const Side = enum { yes, no };

pub fn FixedPoint(n: u8) type {
    return struct {
        const Value = u64;
        pub const buf_len = std.fmt.count(".{}", .{std.math.maxInt(Value)});
        pub const digits = n;
        pub const scale = std.math.powi(Value, 10, digits) catch unreachable;
        pub const zero: Self = .{ .value = 0 };
        pub const one: Self = .{ .value = scale };

        value: Value,

        const Self = @This();

        pub fn parse(bytes: []const u8) !Self {
            var value: Value = 0;
            var frac_digits: usize = 0;
            var seen_dot = false;
            for (bytes) |c| {
                if (c == '.' and !seen_dot) {
                    seen_dot = true;
                    continue;
                }
                if (seen_dot) {
                    frac_digits += 1;
                    if (frac_digits > digits)
                        return error.FixedPointTooPrecise;
                }
                const d = try std.fmt.charToDigit(c, 10);
                value = try std.math.add(Value, d, try std.math.mul(Value, value, 10));
            }
            const unspecified_digits = digits - frac_digits;
            value = try std.math.mul(Value, value, try std.math.powi(Value, 10, unspecified_digits));
            return .{ .value = value };
        }

        pub fn toFloat(self: Self, Float: type) Float {
            const num: Float = @floatFromInt(self.value);
            const denom: Float = @floatFromInt(self.value);
            return num / denom;
        }

        pub fn fmt(self: Self, buf: *[buf_len]u8) []const u8 {
            const fmt_str = std.fmt.comptimePrint("{{:0{}}}", .{digits + 1});
            const s = std.fmt.bufPrint(buf, fmt_str, .{self.value}) catch unreachable;
            const dot = s.len - digits;
            const frac = buf[dot .. dot + digits];
            const dest = buf[dot + 1 .. dot + digits + 1];
            @memmove(dest, frac);
            buf[dot] = '.';
            return buf[0 .. s.len + 1];
        }

        pub fn print(self: Self, w: *std.Io.Writer) !void {
            var buf: [buf_len]u8 = undefined;
            const s = self.fmt(&buf);
            try w.writeAll(s);
        }

        pub fn eql(a: Self, b: Self) bool {
            return a.value == b.value;
        }

        pub fn add(a: Self, b: Self) Self {
            return .{ .value = a.value + b.value };
        }

        pub fn min(a: Self, b: Self) Self {
            return .{ .value = @min(a.value, b.value) };
        }

        pub fn max(a: Self, b: Self) Self {
            return .{ .value = @max(a.value, b.value) };
        }

        pub fn mul(a: Self, b: anytype) FixedPoint(@TypeOf(a).digits + @TypeOf(b).digits) {
            return .{ .value = a.value * b.value };
        }
    };
}

pub const Price = FixedPoint(4);
pub const Size = FixedPoint(2);
pub const Notional = FixedPoint(6);

test "FixedPoint" {
    var buf: [Size.buf_len]u8 = undefined;

    const size: Size = try .parse("12.34");
    try std.testing.expectEqualStrings("12.34", size.fmt(&buf));
    try std.testing.expectEqual(1234, size.value);

    const price: Price = try .parse("99.999");
    try std.testing.expectEqualStrings("99.9990", price.fmt(&buf));
    try std.testing.expectEqual(999_990, price.value);

    const size2: Size = try .parse("2");
    const price2: Price = try .parse("3.");
    try std.testing.expectEqual(200, size2.value);
    try std.testing.expectEqual(30_000, price2.value);

    try std.testing.expectError(error.FixedPointTooPrecise, Size.parse("0.123"));
}

pub const Uuid = struct {
    pub const fmt_len = 36;

    bytes: [16]u8,

    pub fn parse(uuid: []const u8) !Uuid {
        if (uuid.len != fmt_len) return error.InvalidUuid;
        var i: usize = 0;
        var bytes: [16]u8 = undefined;
        var out: std.ArrayList(u8) = .initBuffer(&bytes);
        while (i < uuid.len) : (i += 1) {
            if (i == 8 or i == 13 or i == 18 or i == 23) {
                if (uuid[i] != '-') return error.InvalidUuid;
                continue;
            }
            const msn = try std.fmt.charToDigit(uuid[i], 16);
            const lsn = try std.fmt.charToDigit(uuid[i + 1], 16);
            out.appendAssumeCapacity(16 * msn + lsn);
            i += 1;
        }
        return .{ .bytes = bytes };
    }

    pub fn fmt(self: Uuid, buf: *[fmt_len]u8) void {
        const lengths = [_]u8{ 4, 2, 2, 2, 6 };

        var i: usize = 0;
        var writer = std.Io.Writer.fixed(buf);
        for (lengths, 0..) |len, j| {
            if (j > 0) writer.writeAll("-") catch unreachable;
            for (0..len) |_| {
                writer.print("{x:02}", .{self.bytes[i]}) catch unreachable;
                i += 1;
            }
        }
    }
};
