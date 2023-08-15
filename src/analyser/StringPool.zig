const std = @import("std");

const StringPool = @This();

bytes: std.ArrayListUnmanaged(u8) = .{},
map: std.HashMapUnmanaged(u32, void, std.hash_map.StringIndexContext, std.hash_map.default_max_load_percentage) = .{},

pub const String = enum(u32) {
    empty = 0,
    _,

    pub fn toString(self: String) String {
        return @enumFromInt(@intFromEnum(self));
    }

    pub fn toOptional(self: String) OptionalString {
        return @enumFromInt(@intFromEnum(self));
    }
};

pub const OptionalString = enum(u32) {
    empty = 0,
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(self: OptionalString) ?String {
        if (self == .none) return null;
        return @enumFromInt(@intFromEnum(self));
    }
};

pub fn deinit(pool: *StringPool, allocator: std.mem.Allocator) void {
    pool.bytes.deinit(allocator);
    pool.map.deinit(allocator);
    pool.* = undefined;
}

/// asserts that `str` contains no null bytes
pub fn getString(pool: *StringPool, str: []const u8) ?String {
    std.debug.assert(std.mem.indexOfScalar(u8, str, 0) == null);
    const index = pool.map.getKeyAdapted(str, std.hash_map.StringIndexAdapter{ .bytes = &pool.bytes }) orelse return null;
    return @enumFromInt(index);
}

/// asserts that `str` contains no null bytes
/// returns `error.OutOfMemory` if adding this new string would increase the amount of allocated bytes above 2^32
/// Invalidates pointers even if no new string is inserted
pub fn getOrPutString(pool: *StringPool, allocator: std.mem.Allocator, str: []const u8) error{OutOfMemory}!String {
    const start_index: u32 = @intCast(pool.bytes.items.len);
    if (str.len >= std.math.maxInt(u32)) return error.OutOfMemory;
    if (@addWithOverflow(start_index +| 1, @as(u32, @intCast(str.len))).@"1" != 0) {
        // no more capacity to store `str`
        return pool.getString(str) orelse error.OutOfMemory;
    }
    try pool.bytes.ensureUnusedCapacity(allocator, str.len + 1);

    std.debug.assert(std.mem.indexOfScalar(u8, str, 0) == null);

    const gop = try pool.map.getOrPutContextAdapted(allocator, str, std.hash_map.StringIndexAdapter{
        .bytes = &pool.bytes,
    }, std.hash_map.StringIndexContext{
        .bytes = &pool.bytes,
    });
    if (gop.found_existing) {
        return @enumFromInt(gop.key_ptr.*);
    } else {
        pool.bytes.appendSliceAssumeCapacity(str);
        pool.bytes.appendAssumeCapacity(0);
        gop.key_ptr.* = start_index;
        return @enumFromInt(start_index);
    }
}

/// returns the underlying slice from an interned string
/// equal strings are guaranteed to share the same storage
pub fn stringToSlice(pool: StringPool, index: String) [:0]const u8 {
    const string_bytes: [*:0]u8 = @ptrCast(pool.bytes.items.ptr);
    const start = @intFromEnum(index);
    return std.mem.sliceTo(string_bytes + start, 0);
}

test StringPool {
    const gpa = std.testing.allocator;
    var pool = StringPool{};
    defer pool.deinit(gpa);

    const str = "All Your Codebase Are Belong To Us";
    const index = try pool.getOrPutString(gpa, str);
    try std.testing.expectEqualStrings(str, pool.stringToSlice(index));
}

test "StringPool - check interning" {
    const gpa = std.testing.allocator;
    var pool = StringPool{};
    defer pool.deinit(gpa);

    const str = "All Your Codebase Are Belong To Us";
    const index1 = try pool.getOrPutString(gpa, str);
    const index2 = try pool.getOrPutString(gpa, str);
    const index3 = pool.getString(str).?;
    const storage1 = pool.stringToSlice(index1);
    const storage2 = pool.stringToSlice(index2);

    try std.testing.expectEqual(index1, index2);
    try std.testing.expectEqual(index2, index3);
    try std.testing.expectEqualStrings(str, storage1);
    try std.testing.expectEqualStrings(str, storage2);
    try std.testing.expectEqual(storage1.ptr, storage2.ptr);
    try std.testing.expectEqual(storage1.len, storage2.len);
}

test "StringPool - empty string" {
    if (true) return error.SkipZigTest; // TODO
    const gpa = std.testing.allocator;
    var pool = StringPool{};
    defer pool.deinit(gpa);

    try std.testing.expectEqualStrings("", pool.stringToSlice(.empty));
}
