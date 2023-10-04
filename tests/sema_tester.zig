const std = @import("std");
const zls = @import("zls");
const builtin = @import("builtin");

const helper = @import("helper.zig");
const ErrorBuilder = @import("ErrorBuilder.zig");

const Module = zls.analyser.Module;
const Sema = zls.analyser.Sema;
const InternPool = zls.analyser.InternPool;
const Index = InternPool.Index;
const Key = InternPool.Key;
const Analyser = zls.Analyser;
const offsets = zls.offsets;

pub const std_options = struct {
    pub const log_level = .warn;
};

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = general_purpose_allocator.deinit();
    const gpa = general_purpose_allocator.allocator();

    const stderr = std.io.getStdErr().writer();

    var arg_it = try std.process.argsWithAllocator(gpa);
    defer arg_it.deinit();

    _ = arg_it.skip();

    const file_path = arg_it.next().?;
    var is_fuzz = false;

    while (arg_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--fuzz")) {
            is_fuzz = true;
        } else {
            try stderr.print("Unrecognized argument '{s}'.\n", .{arg});
            std.process.exit(1);
        }
    }

    // std.debug.print("file_path: {s}\n", .{file_path});

    const file = try std.fs.openFileAbsolute(file_path, .{});
    defer file.close();

    const source = try file.readToEndAlloc(gpa, std.math.maxInt(usize));
    defer gpa.free(source);

    const uri = try zls.URI.fromPath(gpa, file_path);
    defer gpa.free(uri);

    // a InternPool stores types and values
    var ip = try InternPool.init(gpa);
    defer ip.deinit(gpa);

    // create a Module that stores data which is used across multiple files like namespaces
    var mod = Module.init(gpa, &ip, undefined);
    defer mod.deinit();

    var document_store = zls.DocumentStore{
        .allocator = gpa,
        .config = &zls.Config{
            .analysis_backend = .astgen_analyser,
            .enable_ast_check_diagnostics = true,
            .prefer_ast_check_as_child_process = false,
        },
        .runtime_zig_version = &@as(?zls.ZigVersionWrapper, null),
        .mod = &mod,
    };

    defer document_store.deinit();
    std.debug.assert(document_store.wantZir());

    mod.document_store = &document_store;

    // add the given source file to the document store
    try document_store.openDocument(uri, source);
    const handle = document_store.handles.get(uri).?;
    std.debug.assert(handle.zir_status == .done);
    std.debug.assert(handle.tree.errors.len == 0);
    std.debug.assert(!handle.zir.hasCompileErrors());
    std.debug.assert(handle.root_decl != .none);

    // get the decl that represents the top-level/root scope
    const decl_index: InternPool.DeclIndex = handle.root_decl.unwrap().?;
    const decl: *InternPool.Decl = mod.declPtr(decl_index);

    // every zig file is also a struct
    const struct_index: InternPool.StructIndex = mod.ip.indexToKey(decl.index).struct_type;
    const struct_obj: *InternPool.Struct = mod.ip.getStructMut(struct_index);
    const namespace: *Module.Namespace = mod.namespacePtr(struct_obj.namespace);
    _ = namespace;

    // this will print all top-level declarations and their value
    // for (namespace.decls.keys()) |namespace_decl_index| {
    //     const namespace_decl = mod.declPtr(namespace_decl_index);
    //     std.debug.print("{s:<18} {}\n", .{ namespace_decl.name, namespace_decl.index.fmtDebug(mod.ip) });
    // }

    var arena = std.heap.ArenaAllocator.init(mod.gpa);
    defer arena.deinit();

    // `Sema` stores temporary information that is required during semantic analysis
    var sema = Sema{
        .mod = &mod,
        .gpa = gpa,
        .arena = arena.allocator(),
        .code = handle.zir,
    };
    defer sema.deinit();

    // this will resolve the types of all top-level container fields
    // try sema.resolveTypeFieldsStruct(struct_obj);

    var error_builder = ErrorBuilder.init(gpa);
    defer error_builder.deinit();
    errdefer error_builder.writeDebug();
    error_builder.file_name_visibility = .always;

    try error_builder.addFile(file_path, handle.tree.source);

    if (is_fuzz) {
        if (handle.analysis_errors.items.len == 0) return;
        for (handle.analysis_errors.items) |err_msg| {
            try error_builder.msgAtLoc("unexpected error '{s}'", file_path, err_msg.loc, .err, .{err_msg.message});
        }
        return error.UnexpectedErrorMessages; // semantic analysis produced errors on its own codebase which are likely false positives
    }

    const annotations = try helper.collectAnnotatedSourceLocations(gpa, handle.tree.source);
    defer gpa.free(annotations);

    for (annotations) |annotation| {
        const identifier_loc = annotation.loc;
        const identifier = offsets.locToSlice(handle.tree.source, identifier_loc);
        const test_item = parseAnnotatedSourceLoc(annotation) catch |err| {
            try error_builder.msgAtLoc("invalid annotated source location '{s}'", file_path, annotation.loc, .err, .{
                annotation.content,
            });
            return err;
        };

        if (test_item.expected_error) |expected_error| {
            const actual_error: zls.DocumentStore.ErrorMessage = for (handle.analysis_errors.items) |actual_error| {
                if (std.meta.eql(actual_error.loc, annotation.loc)) break actual_error;
            } else {
                try error_builder.msgAtLoc("expected error message '{s}'", file_path, annotation.loc, .err, .{
                    expected_error,
                });
                return error.ErrorNotFound; // definetly not a confusing error name
            };

            if (!std.mem.eql(u8, expected_error, actual_error.message)) {
                try error_builder.msgAtLoc("expected error message '{s}' but got '{s}'", file_path, annotation.loc, .err, .{
                    expected_error,
                    actual_error.message,
                });
                return error.WrongError;
            }

            continue;
        }

        const found_decl_index = lookupDeclIndex(&mod, handle.*, identifier_loc) orelse {
            try error_builder.msgAtLoc("couldn't find identifier `{s}` here", file_path, identifier_loc, .err, .{identifier});
            return error.IdentifierNotFound;
        };

        if (test_item.expected_type) |expected_type| {
            const val: InternPool.Index = found_decl_index;
            const ty: InternPool.Index = if (val == .none) .none else mod.ip.typeOf(val);
            const actual_type = try std.fmt.allocPrint(gpa, "{}", .{ty.fmtDebug(mod.ip)});
            defer gpa.free(actual_type);
            if (!std.mem.eql(u8, expected_type, actual_type)) {
                try error_builder.msgAtLoc("expected type `{s}` but got `{s}`", file_path, identifier_loc, .err, .{
                    expected_type,
                    actual_type,
                });
                return error.WrongType;
            }
        }

        if (test_item.expected_value) |expected_value| {
            const val: InternPool.Index = found_decl_index;
            const actual_value = try std.fmt.allocPrint(gpa, "{}", .{val.fmt(mod.ip)});
            defer gpa.free(actual_value);
            if (!std.mem.eql(u8, expected_value, actual_value)) {
                try error_builder.msgAtLoc("expected value `{s}` but got `{s}`", file_path, identifier_loc, .err, .{
                    expected_value,
                    actual_value,
                });
                return error.WrongValue;
            }
        }
    }
}

fn lookupDeclIndex(mod: *Module, handle: zls.DocumentStore.Handle, identifier_loc: offsets.Loc) ?InternPool.Index {
    const identifier = offsets.locToSlice(handle.tree.source, identifier_loc);
    const symbol = Analyser.Declaration.Key{ .kind = .variable, .name = identifier };
    if (Analyser.lookupDeclaration(handle.document_scope, symbol, identifier_loc.start)) |decl_index| {
        const decl = handle.document_scope.decls.items[@intFromEnum(decl_index)];
        switch (decl) {
            .intern_pool_index => |payload| {
                std.debug.assert(std.mem.eql(u8, identifier, offsets.tokenToSlice(handle.tree, payload.name)));
                return payload.index;
            },
            else => {},
        }
    }

    const identifier_index = mod.ip.string_pool.getString(identifier) orelse return null;

    // this is not how you are supposed to lookup identifiers but its good enough for now
    var decl_it = mod.ip.decls.constIterator(0);
    while (decl_it.next()) |decl| {
        if (decl.name != identifier_index) continue;
        return decl.index;
    }
    return null;
}

const TestItem = struct {
    loc: offsets.Loc,
    expected_type: ?[]const u8 = null,
    expected_value: ?[]const u8 = null,
    expected_error: ?[]const u8 = null,
};

fn parseAnnotatedSourceLoc(annotation: helper.AnnotatedSourceLoc) error{InvalidTestItem}!TestItem {
    const str = annotation.content;

    if (std.mem.startsWith(u8, str, "error:")) {
        return .{
            .loc = annotation.loc,
            .expected_error = std.mem.trim(u8, str["error:".len..], &std.ascii.whitespace),
        };
    }

    if (!std.mem.startsWith(u8, str, "(")) return error.InvalidTestItem;
    const expected_type_start = 1;
    const expected_type_end = expected_type_start + (findClosingBrace(str[expected_type_start..]) orelse return error.InvalidTestItem);

    if (!std.mem.startsWith(u8, str[expected_type_end + 1 ..], "(")) return error.InvalidTestItem;
    const expected_value_start = expected_type_end + 2;
    const expected_value_end = expected_value_start + (findClosingBrace(str[expected_value_start..]) orelse return error.InvalidTestItem);

    const expected_type = std.mem.trim(
        u8,
        offsets.locToSlice(str, .{ .start = expected_type_start, .end = expected_type_end }),
        &std.ascii.whitespace,
    );
    const expected_value = std.mem.trim(
        u8,
        offsets.locToSlice(str, .{ .start = expected_value_start, .end = expected_value_end }),
        &std.ascii.whitespace,
    );

    return .{
        .loc = annotation.loc,
        .expected_type = if (expected_type.len != 0) expected_type else null,
        .expected_value = if (expected_value.len != 0) expected_value else null,
    };
}

fn findClosingBrace(source: []const u8) ?usize {
    var depth: usize = 0;
    for (source, 0..) |c, i| {
        switch (c) {
            '(' => depth += 1,
            ')' => {
                if (depth == 0) return i;
                depth -= 1;
            },
            else => continue,
        }
    }
    return null;
}
