// zig fmt: off
    const S = struct {
    alpha: void,
    alpha: void,
//  ^^^^^ error: duplicate struct field: 'alpha'
};
// zig fmt: on

comptime {
    _ = @as(S, undefined).alpha; // force field resolution of G
}
