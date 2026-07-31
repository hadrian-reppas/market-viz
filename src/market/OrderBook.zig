const std = @import("std");
const types = @import("types.zig");
const util = @import("../util.zig");

gpa: std.mem.Allocator,
mutex: util.Mutex,

const Self = @This();

pub fn init(gpa: std.mem.Allocator) Self {
    return .{ .gpa = gpa, .mutex = .init };
}

pub fn deinit(self: *Self) void {
    self.* = undefined;
}

// Consider calling `mutex.lock()`
pub fn insert(_: *Self, _: types.Update) !void {}

// Consider calling `mutex.lock()`
pub fn copy(_: *const Self) []PriceLevel {}

pub fn listener(self: *Self) types.UpdateListener {
    return .{ .ptr = self, .notify = insertUpdate };
}

pub fn insertUpdate(ptr: *anyopaque, update: types.Update) void {
    const book: *Self = @ptrCast(@alignCast(ptr));

    book.mutex.lock();
    book.insert(update);
    book.mutex.unlock();
}

pub const PriceLevel = struct {
    price: types.Price,
    size: types.Size,
    side: types.Side,
};
