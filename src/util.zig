const std = @import("std");

pub fn Subscriptions(Listener: type) type {
    return struct {
        gpa: std.mem.Allocator,
        map: std.StringHashMap(std.ArrayList(Listener)),

        const Self = @This();

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .gpa = gpa, .map = .init(gpa) };
        }

        pub fn deinit(self: *Self) void {
            var it = self.map.iterator();
            while (it.next()) |e| {
                self.gpa.free(e.key_ptr.*);
                e.value_ptr.deinit(self.gpa);
            }
            self.map.deinit();
            self.* = undefined;
        }

        pub fn insert(self: *Self, ticker: []const u8, listener: Listener) !bool {
            if (self.map.getPtr(ticker)) |listeners| {
                try listeners.append(self.gpa, listener);
                return false;
            } else {
                var listeners: std.ArrayList(Listener) = .empty;
                try listeners.append(self.gpa, listener);
                const ticker_owned = try self.gpa.dupe(u8, ticker);
                try self.map.put(ticker_owned, listeners);
                return true;
            }
        }

        pub fn get(self: *const Self, ticker: []const u8) ?*std.ArrayList(Listener) {
            return self.map.getPtr(ticker);
        }
    };
}
