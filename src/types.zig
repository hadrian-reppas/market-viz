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
    yes_price: FixedPoint,
    no_price: FixedPoint,
    size: FixedPoint,
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

    // TODO: rename to str()
    pub fn get(self: *const Ticker) []const u8 {
        return self.buffer[0..self.len];
    }
};

pub fn TickerHashMap(comptime V: type) type {
    return std.HashMapUnmanaged(
        Ticker,
        V,
        struct {
            pub fn hash(_: @This(), t: Ticker) u64 {
                return std.hash_map.hashString(t.get());
            }

            pub fn eql(_: @This(), a: Ticker, b: Ticker) bool {
                return std.hash_map.eqlString(a.get(), b.get());
            }
        },
        std.hash_map.default_max_load_percentage,
    );
}

pub const Side = enum { yes, no };

// TODO: replace with
//   fn FixedPoint(unit: []const u8, digits: u8) type;
//   const Price = FixedPoint("ten_thousandths", 4);
//   const Size = FixedPoint("hundredths", 2);
//   const Notional = FixedPoint("millionths", 6);

pub const Scale = enum(u8) {
    ones = 0,
    tenths = 1,
    hundredths = 2,
    thousandths = 3,
    ten_thousandths = 4,
    hundred_thousandths = 5,
    millionths = 6,

    pub fn coeff(self: Scale) u64 {
        return std.math.powi(u64, 10, @intFromEnum(self)) catch unreachable;
    }

    pub fn coeffTo(self: Scale, other: Scale) u64 {
        const si = @intFromEnum(self);
        const oi = @intFromEnum(other);
        std.debug.assert(oi >= si);
        return std.enums.fromInt(Scale, oi - si).?.coeff();
    }

    pub fn next(self: Scale) ?Scale {
        return std.enums.fromInt(Scale, @intFromEnum(self) + 1);
    }

    pub fn max(a: Scale, b: Scale) Scale {
        const ai = @intFromEnum(a);
        const bi = @intFromEnum(b);
        return std.enums.fromInt(Scale, @max(ai, bi)).?;
    }

    pub fn add(a: Scale, b: Scale) ?Scale {
        const ai = @intFromEnum(a);
        const bi = @intFromEnum(b);
        return std.enums.fromInt(Scale, ai + bi);
    }
};

pub const FixedPoint = struct {
    const Value = u64;
    pub const buf_len = std.fmt.count(".{:07}", .{std.math.maxInt(Value)});
    pub const zero: FixedPoint = .{ .value = 0, .scale = .ones };
    pub const one: FixedPoint = .{ .value = 1, .scale = .ones };

    value: Value,
    scale: Scale,

    pub fn parse(buf: []const u8) !FixedPoint {
        var value: Value = 0;
        var scale: Scale = .ones;
        var seen_dot = false;
        for (buf) |c| {
            if (c == '.') {
                if (seen_dot) return error.InvalidFixedPoint;
                seen_dot = true;
            } else if ('0' <= c and c <= '9') {
                if (seen_dot)
                    scale = scale.next() orelse return error.FixedPointTooPrecise;
                value = try std.math.add(Value, c - '0', try std.math.mul(Value, value, 10));
            } else {
                return error.InvalidCharacter;
            }
        }
        return .{ .value = value, .scale = scale };
    }

    pub fn toFloat(self: FixedPoint, Float: type) Float {
        const value: Float = @floatFromInt(self.value);
        const coeff: Float = @floatFromInt(self.scale.coeff());
        return value / coeff;
    }

    pub fn fmt(self: FixedPoint, buf: *[buf_len]u8) []const u8 {
        var value = std.fmt.bufPrint(buf, "{:07}", .{self.value}) catch unreachable;
        if (self.scale != .ones) {
            const n = @intFromEnum(self.scale);
            const dot = value.len - n;
            const digits = value[dot .. dot + n];
            const dest = buf[dot + 1 .. dot + n + 1];
            @memmove(dest, digits);
            buf[dot] = '.';
            value = buf[0 .. value.len + 1];
        }
        while (value.len > 1 and value[0] == '0' and '0' <= value[1] and value[1] <= '9') {
            value = value[1..];
        }
        return value;
    }

    pub fn print(self: FixedPoint, w: *std.Io.Writer) !void {
        var buf: [buf_len]u8 = undefined;
        const str = self.fmt(&buf);
        try w.writeAll(str);
    }

    pub fn eql(a: FixedPoint, b: FixedPoint) bool {
        std.debug.assert(a.value == 0 or b.value == 0); // TODO
        return a.value == b.value;
    }

    fn simpleBinary(comptime f: fn (Value, Value) Value) fn (FixedPoint, FixedPoint) FixedPoint {
        return struct {
            fn inner(a: FixedPoint, b: FixedPoint) FixedPoint {
                var a_mut = a;
                var b_mut = b;
                FixedPoint.unify(&a_mut, &b_mut);
                return .{ .value = f(a_mut.value, b_mut.value), .scale = a_mut.scale };
            }
        }.inner;
    }

    pub const min = simpleBinary(struct {
        fn inner(a: Value, b: Value) Value {
            return @min(a, b);
        }
    }.inner);

    pub const max = simpleBinary(struct {
        fn inner(a: Value, b: Value) Value {
            return @max(a, b);
        }
    }.inner);

    pub const add = simpleBinary(struct {
        fn inner(a: Value, b: Value) Value {
            return a + b;
        }
    }.inner);

    pub fn mul(a: FixedPoint, b: FixedPoint) FixedPoint {
        return .{ .value = a.value * b.value, .scale = a.scale.add(b.scale).? };
    }

    fn unify(a: *FixedPoint, b: *FixedPoint) void {
        const scale = a.scale.max(b.scale);
        a.value *= a.scale.coeffTo(scale);
        a.scale = scale;
        b.value *= b.scale.coeffTo(scale);
        b.scale = scale;
    }
};

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
