const std = @import("std");

pub const buf_len = 27;
pub const max_microseconds = 253_402_300_799_999_999;
pub const microseconds_per_minute = 60_000_000;
pub const microseconds_per_hour = 60 * microseconds_per_minute;
pub const microseconds_per_day = 24 * microseconds_per_hour;

pub fn parseToMicroseconds(s: []const u8) !u64 {
    if (s.len < 20 or
        s[4] != '-' or
        s[7] != '-' or
        s[10] != 'T' or
        s[13] != ':' or
        s[16] != ':' or
        s[s.len - 1] != 'Z') return error.InvalidTimestamp;

    const year = try std.fmt.parseInt(u64, s[0..4], 10);
    const month = try std.fmt.parseInt(u64, s[5..7], 10);
    const day = try std.fmt.parseInt(u64, s[8..10], 10);
    const hour = try std.fmt.parseInt(u64, s[11..13], 10);
    const minute = try std.fmt.parseInt(u64, s[14..16], 10);

    const Seconds = @import("types.zig").FixedPoint(6);
    const second_fp = try Seconds.parse(s[17 .. s.len - 1]);
    const microsecond = second_fp.value;

    if (month == 0 or
        month > 12 or
        day == 0 or
        day > daysInMonth(year, month) or
        hour > 23 or
        minute > 59 or
        microsecond > 59_999_999) return error.InvalidTimestamp;

    const epoch_day = toEpochDay(year, month, day);

    return microseconds_per_day * epoch_day +
        microseconds_per_hour * hour +
        microseconds_per_minute * minute +
        microsecond;
}

pub fn fmtMicroseconds(buf: *[buf_len]u8, microseconds: u64) void {
    std.debug.assert(microseconds <= max_microseconds);

    const year, const month, const day =
        fromEpochDay(@divFloor(microseconds, microseconds_per_day));

    var remainder = microseconds % microseconds_per_day;
    const hour = remainder / microseconds_per_hour;
    remainder %= microseconds_per_hour;
    const minute = remainder / microseconds_per_minute;
    remainder %= microseconds_per_minute;
    const second = remainder / 1_000_000;
    const microsecond = remainder % 1_000_000;

    _ = std.fmt.bufPrint(
        buf,
        "{:0>4}-{:0>2}-{:0>2}T{:0>2}:{:0>2}:{:0>2}.{:0>6}Z",
        .{ year, month, day, hour, minute, second, microsecond },
    ) catch unreachable;
}

fn toEpochDay(year: u64, month: u64, day: u64) u64 {
    // https://howardhinnant.github.io/date_algorithms.html#days_from_civil

    const shifted_year = if (month <= 2) year - 1 else year;
    const shifted_month = if (month <= 2) month + 9 else month - 3;

    const era = @divFloor(shifted_year, 400);
    const year_of_era = shifted_year - 400 * era;
    const day_of_year = @divFloor(153 * shifted_month + 2, 5) + day - 1;

    const day_of_era =
        365 * year_of_era +
        @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) +
        day_of_year;

    return 146_097 * era + day_of_era - 719_468;
}

fn fromEpochDay(epoch_day: u64) struct { u64, u64, u64 } {
    // https://howardhinnant.github.io/date_algorithms.html#civil_from_days

    const shifted_day = epoch_day + 719468;
    const era = @divFloor(
        if (shifted_day >= 0) shifted_day else shifted_day - 719468,
        146097,
    );
    const day_of_era = shifted_day - 146097 * era;
    const year_of_era = @divFloor(
        day_of_era -
            @divFloor(day_of_era, 1460) +
            @divFloor(day_of_era, 36524) -
            @divFloor(day_of_era, 146096),
        365,
    );

    const shifted_year = year_of_era + era * 400;
    const day_of_year = day_of_era -
        (365 * year_of_era +
            @divFloor(year_of_era, 4) -
            @divFloor(year_of_era, 100));
    const shifted_month = @divFloor(5 * day_of_year + 2, 153);

    const day = day_of_year - @divFloor(153 * shifted_month + 2, 5) + 1;
    const month = if (shifted_month < 10)
        shifted_month + 3
    else
        shifted_month - 9;
    const year = if (month <= 2) shifted_year + 1 else shifted_year;

    return .{ year, month, day };
}

fn isLeapYear(year: u64) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

fn daysInMonth(year: u64, month: u64) u64 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => unreachable,
    };
}

test "parseToMicroseconds" {
    const cases = [_]struct { str: []const u8, mics: u64 }{
        .{ .str = "1970-01-01T00:00:00Z", .mics = 0 },
        .{ .str = "1970-01-01T00:00:00.Z", .mics = 0 },
        .{ .str = "1970-01-01T00:00:00.1Z", .mics = 100_000 },
        .{ .str = "1970-01-01T00:00:00.12Z", .mics = 120_000 },
        .{ .str = "1970-01-01T00:00:00.123Z", .mics = 123_000 },
        .{ .str = "1970-01-01T00:00:00.1234Z", .mics = 123_400 },
        .{ .str = "1970-01-01T00:00:00.12345Z", .mics = 123_450 },
        .{ .str = "1970-01-01T00:00:00.123456Z", .mics = 123_456 },
        .{ .str = "1970-01-01T00:00:01Z", .mics = 1_000_000 },
        .{ .str = "1970-01-01T00:01:00Z", .mics = 60_000_000 },
        .{ .str = "1970-01-01T01:00:00Z", .mics = 3_600_000_000 },
        .{ .str = "1970-01-02T00:00:00Z", .mics = 86_400_000_000 },
        .{ .str = "1970-01-01T23:59:59.999999Z", .mics = 86_399_999_999 },
        .{ .str = "1970-12-31T23:59:59.999999Z", .mics = 31_535_999_999_999 },
        .{ .str = "1971-01-01T00:00:00Z", .mics = 31_536_000_000_000 },
        .{ .str = "2023-01-31T23:59:59.999999Z", .mics = 1_675_209_599_999_999 },
        .{ .str = "2023-02-01T00:00:00Z", .mics = 1_675_209_600_000_000 },
        .{ .str = "2023-02-28T23:59:59.999999Z", .mics = 1_677_628_799_999_999 },
        .{ .str = "2023-03-01T00:00:00Z", .mics = 1_677_628_800_000_000 },
        .{ .str = "2023-03-31T23:59:59.999999Z", .mics = 1_680_307_199_999_999 },
        .{ .str = "2023-04-01T00:00:00Z", .mics = 1_680_307_200_000_000 },
        .{ .str = "2023-04-30T23:59:59.999999Z", .mics = 1_682_899_199_999_999 },
        .{ .str = "2023-05-01T00:00:00Z", .mics = 1_682_899_200_000_000 },
        .{ .str = "2023-05-31T23:59:59.999999Z", .mics = 1_685_577_599_999_999 },
        .{ .str = "2023-06-01T00:00:00Z", .mics = 1_685_577_600_000_000 },
        .{ .str = "2023-06-30T23:59:59.999999Z", .mics = 1_688_169_599_999_999 },
        .{ .str = "2023-07-01T00:00:00Z", .mics = 1_688_169_600_000_000 },
        .{ .str = "2023-07-31T23:59:59.999999Z", .mics = 1_690_847_999_999_999 },
        .{ .str = "2023-08-01T00:00:00Z", .mics = 1_690_848_000_000_000 },
        .{ .str = "2023-08-31T23:59:59.999999Z", .mics = 1_693_526_399_999_999 },
        .{ .str = "2023-09-01T00:00:00Z", .mics = 1_693_526_400_000_000 },
        .{ .str = "2023-09-30T23:59:59.999999Z", .mics = 1_696_118_399_999_999 },
        .{ .str = "2023-10-01T00:00:00Z", .mics = 1_696_118_400_000_000 },
        .{ .str = "2023-10-31T23:59:59.999999Z", .mics = 1_698_796_799_999_999 },
        .{ .str = "2023-11-01T00:00:00Z", .mics = 1_698_796_800_000_000 },
        .{ .str = "2023-11-30T23:59:59.999999Z", .mics = 1_701_388_799_999_999 },
        .{ .str = "2023-12-01T00:00:00Z", .mics = 1_701_388_800_000_000 },
        .{ .str = "2023-12-31T23:59:59.999999Z", .mics = 1_704_067_199_999_999 },
        .{ .str = "2024-01-01T00:00:00Z", .mics = 1_704_067_200_000_000 },
        .{ .str = "2000-02-28T23:59:59.999999Z", .mics = 951_782_399_999_999 },
        .{ .str = "2000-02-29T00:00:00Z", .mics = 951_782_400_000_000 },
        .{ .str = "2000-02-29T23:59:59.999999Z", .mics = 951_868_799_999_999 },
        .{ .str = "2000-03-01T00:00:00Z", .mics = 951_868_800_000_000 },
        .{ .str = "2024-02-28T23:59:59.999999Z", .mics = 1_709_164_799_999_999 },
        .{ .str = "2024-02-29T00:00:00Z", .mics = 1_709_164_800_000_000 },
        .{ .str = "2024-02-29T23:59:59.999999Z", .mics = 1_709_251_199_999_999 },
        .{ .str = "2024-03-01T00:00:00Z", .mics = 1_709_251_200_000_000 },
        .{ .str = "2100-02-28T23:59:59.999999Z", .mics = 4_107_542_399_999_999 },
        .{ .str = "2100-03-01T00:00:00Z", .mics = 4_107_542_400_000_000 },
        .{ .str = "2400-02-29T12:34:56.654321Z", .mics = 13_574_608_496_654_321 },
        .{ .str = "1970-01-01T00:00:00Z", .mics = 0 },
        .{ .str = "1980-01-01T00:00:00Z", .mics = 315_532_800_000_000 },
        .{ .str = "1999-12-31T23:59:59.999999Z", .mics = 946_684_799_999_999 },
        .{ .str = "2000-01-01T00:00:00Z", .mics = 946_684_800_000_000 },
        .{ .str = "2038-01-19T03:14:07Z", .mics = 2_147_483_647_000_000 },
        .{ .str = "2100-01-01T00:00:00Z", .mics = 4_102_444_800_000_000 },
        .{ .str = "2400-01-01T00:00:00Z", .mics = 13_569_465_600_000_000 },
        .{ .str = "9999-12-31T23:59:59.999999Z", .mics = 253_402_300_799_999_999 },
    };

    for (cases) |c| {
        var padded = [_]u8{'0'} ** 26 ++ [_]u8{'Z'};
        @memcpy(padded[0..c.str.len], c.str);
        padded[19] = '.';
        for (@max(20, c.str.len - 1)..26) |i| padded[i] = '0';

        try std.testing.expectEqual(c.mics, try parseToMicroseconds(c.str));

        var buf: [buf_len]u8 = undefined;
        fmtMicroseconds(&buf, c.mics);
        try std.testing.expectEqualStrings(&padded, &buf);
    }

    const invalid = [_][]const u8{
        "2023-02-29T00:00:00Z",
        "2100-02-29T00:00:00Z",
        "2024-02-30T00:00:00Z",
        "2024-04-31T00:00:00Z",
        "2024-06-31T00:00:00Z",
        "2024-09-31T00:00:00Z",
        "2024-11-31T00:00:00Z",
        "2024-00-01T00:00:00Z",
        "2024-13-01T00:00:00Z",
        "2024-01-00T00:00:00Z",
        "2024-01-32T00:00:00Z",
        "2024?01-31T00:00:00Z",
        "2024-01?31T00:00:00Z",
        "2024-01-31?00:00:00Z",
        "2024-01-31T00?00:00Z",
        "2024-01-31T00:00?00Z",
        "2024-01-31T00:00:00?",
    };

    for (invalid) |in| {
        try std.testing.expectError(
            error.InvalidTimestamp,
            parseToMicroseconds(in),
        );
    }

    try std.testing.expectError(
        error.InvalidCharacter,
        parseToMicroseconds("2024-01-31T00:00:00?Z"),
    );
    try std.testing.expectError(
        error.InvalidCharacter,
        parseToMicroseconds("2024-01-31T00:00:00?0Z"),
    );
}
