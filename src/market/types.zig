const std = @import("std");

pub const Trade = struct {
    ticker: []const u8,
    ts: Ts,
    price: Price,
    size: Size,
    taker_side: Side,
};

pub const Update = struct {
    pub const Kind = enum { set, add, sub };

    ticker: []const u8,
    ts: Ts,
    price: Price,
    size: Size,
    kind: Kind,
    side: Side,
};

pub const Side = enum {
    buy,
    sell,

    pub fn spellings(self: Side) [4][]const u8 {
        return switch (self) {
            .buy => .{ "buy", "yes", "bid", "BUY" },
            .sell => .{ "sell", "no", "offer", "SELL" },
        };
    }

    pub fn opposite(self: Side) Side {
        return switch (self) {
            .buy => .sell,
            .sell => .buy,
        };
    }

    pub fn parse(s: []const u8) ?Side {
        inline for (.{ Side.buy, Side.sell }) |side| {
            inline for (side.spellings()) |spelling| {
                if (std.mem.eql(u8, s, spelling)) return side;
            }
        }
        return null;
    }
};

pub const Ts = struct {
    const iso8601 = @import("iso8601.zig");
    pub const buf_len = iso8601.buf_len;
    pub const zero: Ts = .{ .microseconds = 0 };

    microseconds: u64,

    pub fn parseIso8601(s: []const u8) !Ts {
        return .{
            .microseconds = try iso8601.parseToMicroseconds(s),
        };
    }

    pub fn fromMilliseconds(millis: u64) Ts {
        return .{ .microseconds = 1_000 * millis };
    }

    pub fn fmtIso8601(self: Ts, buf: *[buf_len]u8) void {
        iso8601.fmtMicroseconds(buf, self.microseconds);
    }
};

pub fn FixedPoint(n: u8) type {
    return struct {
        const Value = if (n > 9) u128 else u64;
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
            value = try std.math.mul(
                Value,
                value,
                try std.math.powi(Value, 10, unspecified_digits),
            );
            return .{ .value = value };
        }

        pub fn toFloat(self: Self, Float: type) Float {
            const num: Float = @floatFromInt(self.value);
            const denom: Float = @floatFromInt(scale);
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

        pub fn Mul(A: type, B: type) type {
            return FixedPoint(A.digits + B.digits);
        }

        pub fn mul(a: anytype, b: anytype) Mul(@TypeOf(a), @TypeOf(b)) {
            const MulValue = Mul(@TypeOf(a), @TypeOf(b)).Value;
            const a_value: MulValue = a.value;
            const b_value: MulValue = b.value;
            return .{ .value = a_value * b_value };
        }
    };
}

pub const Price = FixedPoint(4);
pub const Size = FixedPoint(8);
pub const Notional = FixedPoint(12);

test "FixedPoint" {
    var buf: [Price.buf_len]u8 = undefined;

    const price: Price = try .parse("12.3456");
    try std.testing.expectEqualStrings("12.3456", price.fmt(&buf));
    try std.testing.expectEqual(123456, price.value);

    const size: Size = try .parse("99.999999");
    try std.testing.expectEqualStrings("99.99999900", size.fmt(&buf));
    try std.testing.expectEqual(9_999_999_900, size.value);

    const price2: Price = try .parse("3.");
    const size2: Size = try .parse("2");
    try std.testing.expectEqual(30_000, price2.value);
    try std.testing.expectEqual(200_000_000, size2.value);

    try std.testing.expectError(error.FixedPointTooPrecise, Price.parse("0.12345"));
    try std.testing.expectError(error.FixedPointTooPrecise, Price.parse("0.12340"));
}

pub const TradeListener = struct {
    ptr: *anyopaque,
    notify: *const fn (*anyopaque, Trade) void,
};

pub const UpdateListener = struct {
    ptr: *anyopaque,
    notify: *const fn (*anyopaque, Update) void,
};
