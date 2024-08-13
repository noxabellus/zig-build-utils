const std = @import("std");
const builtin = std.builtin;
const ZigType = builtin.Type;
const zig = std.zig;

pub const std_options = std.Options {
    .log_level = .warn,
};

const log = std.log.scoped(.headergen);

const Generator = HeaderGenerator(@import("#HEADER_GENERATION_SOURCE_MODULE#"));

const DATA_SOURCE_NAME = "HEADER-GENERATION-DATA";

var RENDER_LINE_COMMENT = false;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len < 2) {
        return error.NotEnoughArguments;
    } else if (args.len > 2) {
        return error.TooManyArguments;
    }



    const cwd = std.fs.cwd();


    const generator = try Generator.init(allocator);

    var source = try cwd.openFile(generator.path, .{ .mode = .read_only });
    defer source.close();

    const sourceText = try source.readToEndAllocOptions(allocator, std.math.maxInt(usize), null, 128, 0);

    const ast = try zig.Ast.parse(allocator, sourceText, .zig);

    const members = try parseMembers(&generator, ast, ast.rootDecls());

    const headerText = try render(&generator, members);


    if (!std.mem.eql(u8, args[1], "-no-static")) {
        const outputFileName = args[1];
        log.debug("output file: {s}", .{outputFileName});

        if (std.fs.path.dirname(outputFileName)) |dirname| {
            cwd.makePath(dirname) catch |err| {
                log.err("cannot make output path: {}", .{err});
                return error.InvalidOutputPath;
            };
        }
        const tempOutputFileName = try std.fmt.allocPrint(allocator, "{s}.tmp", .{outputFileName});
        const outputFile = cwd.createFile(tempOutputFileName, .{ .exclusive = true }) catch |err| {
            log.err("Unable to create output file `{s}`: {}", .{ tempOutputFileName, err });
            return error.CannotCreateFile;
        };
        errdefer cwd.deleteFile(tempOutputFileName) catch {};
        defer outputFile.close();

        const output = outputFile.writer();
        try output.writeAll(headerText);

        cwd.deleteFile(outputFileName) catch |err| {
            if (err != error.FileNotFound) {
                log.err("Unable to delete `{s}`: {}", .{ outputFileName, err });
                return err;
            }
        };

        cwd.rename(tempOutputFileName, outputFileName) catch |err| {
            log.err("Unable to rename `{s}` to `{s}`: {}", .{ tempOutputFileName, outputFileName, err });
            return error.CannotRenameFile;
        };

        const meta = outputFile.metadata() catch |err| {
            log.err("Unable to stat `{s}`: {}", .{ outputFileName, err });
            return error.CannotStatFile;
        };

        var perms = meta.permissions();

        perms.setReadOnly(true);

        outputFile.setPermissions(perms) catch |err| {
            log.err("Unable to set permissions on `{s}`: {}", .{ outputFileName, err });
            return error.CannotSetPermissions;
        };
    } else {
        log.debug("output stdout", .{});
        try std.io.getStdOut().writer().writeAll(headerText);
    }
}

fn render(generator: *const Generator, members: []const Member) ![]const u8 {
    var output = std.ArrayList(u8).init(generator.allocator);
    const writer = output.writer();


    try writer.print("/* File generated from {s} */\n\n", .{generator.path});

    try writer.print("{s}\n\n", .{generator.head});

    for (members) |member| {
        try member.render(generator, writer);
        try writer.writeAll("\n\n");
    }

    try writer.print("{s}\n", .{generator.foot});

    return output.items;
}

fn parseMembers(gen: *const Generator, ast: zig.Ast, members: []const zig.Ast.Node.Index) ![]const Member {
    var memberBuf = std.ArrayList(Member).init(gen.allocator);
    for (members) |member| {
        if (try parseMember(gen, ast, member)) |memb| {
            try memberBuf.append(memb);
        }
    }
    return memberBuf.items;
}

const Member = union(enum) {
    TypeDef: TypeDef,
    Const: Const,
    Var: Var,
    Function: Function,

    const TypeDef = struct {
        name: []const u8,
        location: LocationFmt,
        kind: Kind,

        const Kind = enum {
            Custom,
            Opaque,
            Extern,
        };
    };

    const Const = struct {
        name: []const u8,
        location: LocationFmt,
        typeExpr: []const u8,
        valueExpr: []const u8,
    };

    const Var = struct {
        name: []const u8,
        location: LocationFmt,
        typeExpr: []const u8,
    };

    const Function = struct {
        name: []const u8,
        location: LocationFmt,
        returnType: []const u8,
        params: []const Param,

        const Param = struct {
            name: []const u8,
            location: LocationFmt,
            typeExpr: []const u8,
        };
    };

    pub fn render(self: Member, generator: *const Generator, writer: anytype) !void {
        switch (self) {
            .TypeDef => |x| {
                switch (x.kind) {
                    .Custom => {
                        try writer.print("{comment}", .{x.location});
                        const t = generator.customTypes.get(x.name) orelse {
                            log.err("error {}: type {s} not found in custom type table", .{ x.location, x.name });
                            return error.CustomTypeNotFound;
                        };
                        try t.render(x.name, generator, writer);
                    },
                    .Opaque => try writer.print("{comment}typedef struct {s} {{}} {s};", .{ x.location, x.name, x.name }),
                    .Extern => {
                        try writer.print("{comment}", .{x.location});
                        const t = generator.lookupType(x.name) orelse {
                            log.err("error {}: type {s} not found in generator table", .{ x.location, x.name });
                            return error.ExternTypeNotFound;
                        };
                        try t.renderDecl(generator, writer);
                    },
                }
            },
            .Const => |x| {
                try writer.print("{comment}static const {s} {s} = {s};", .{ x.location, x.typeExpr, x.name, x.valueExpr });
            },
            .Var => |x| {
                try writer.print("{comment}extern {s} {s};", .{ x.location, x.typeExpr, x.name });
            },
            .Function => |x| {
                try writer.print("{comment}{s} {s} (", .{ x.location, x.returnType, x.name });
                for (x.params, 0..) |param, i| {
                    try writer.print("{s} {s}", .{ param.typeExpr, param.name });
                    if (i < x.params.len - 1) {
                        try writer.writeAll(", ");
                    }
                }
                try writer.writeAll(");");
            },
        }
    }
};

fn parseMember(
    gen: *const Generator,
    ast: zig.Ast,
    decl: zig.Ast.Node.Index,
) !?Member {
    const token_tags = ast.tokens.items(.tag);
    switch (ast.nodes.items(.tag)[decl]) {
        .fn_decl,
        .fn_proto_simple,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto,
        => {
            var buf = std.mem.zeroes([1]zig.Ast.Node.Index);
            const fun_proto = zig.Ast.fullFnProto(ast, &buf, decl).?;

            const name_tok = fun_proto.name_token orelse 0;
            var name = ast.tokenSlice(name_tok);

            log.debug("fn_decl: {s}", .{name});

            if(std.mem.startsWith(u8, name, "@\"") and std.mem.endsWith(u8, name, "\"")) {
                name = name[2..name.len - 1];
                log.debug("stripped name: {s}", .{name});
            }

            if (gen.ignoredDecls.contains(name)) return null;

            const location = Location(gen.path, ast.tokenLocation(0, fun_proto.firstToken()));

            const vis_tok = fun_proto.visib_token orelse 0;
            const vis = token_tags[vis_tok];
            if (vis != .keyword_pub) return null;

            const extern_export_inline_tok = fun_proto.extern_export_inline_token orelse 0;
            const extern_export_inline = token_tags[extern_export_inline_tok];

            if (extern_export_inline != .keyword_export) {
                log.warn("{}: public function {s} is not exported", .{ location, name });
                return null;
            }

            const ret_type_node = fun_proto.ast.return_type;
            const ret_type_start = ast.firstToken(ret_type_node);
            const ret_type_end = ast.lastToken(ret_type_node);
            const ret_type_src = tokensSlice(ast, ret_type_start, ret_type_end);
            const ret_type = try convertTypeExpr(gen.allocator, ret_type_src);

            var paramBuf = std.ArrayList(Member.Function.Param).init(gen.allocator);

            var param_iter = fun_proto.iterate(&ast);
            while (param_iter.next()) |param| {
                const param_name_tok = param.name_token orelse 0;
                const param_name = if (param_name_tok != 0) ast.tokenSlice(param_name_tok) else continue;

                const param_type_node = param.type_expr;
                const param_type_start = ast.firstToken(param_type_node);
                const param_type_end = ast.lastToken(param_type_node);
                const param_type_src = tokensSlice(ast, param_type_start, param_type_end);
                const param_type = try convertTypeExpr(gen.allocator, param_type_src);

                const param_location = Location(gen.path, ast.tokenLocation(0, param_name_tok));

                try paramBuf.append(Member.Function.Param{
                    .name = param_name,
                    .location = param_location,
                    .typeExpr = param_type,
                });
            }

            if (!std.mem.startsWith(u8, name, gen.prefix)) {
                log.warn("{}: exported function {s} does not start with {s}", .{ location, name, gen.prefix });
            }

            return Member{
                .Function = .{
                    .name = name,
                    .location = location,
                    .returnType = ret_type,
                    .params = paramBuf.items,
                },
            };
        },

        .global_var_decl,
        .local_var_decl,
        .simple_var_decl,
        .aligned_var_decl,
        => {
            const var_decl = zig.Ast.fullVarDecl(ast, decl).?;

            const vis = token_tags[var_decl.visib_token orelse 0];
            if (vis != .keyword_pub) return null;

            const exp = token_tags[var_decl.extern_export_token orelse 0];

            const mut_tok = var_decl.ast.mut_token;
            std.debug.assert(mut_tok != 0);

            const mut = token_tags[mut_tok];

            const name_tok = mut_tok + 1;
            var name = ast.tokenSlice(name_tok);

            log.debug("var_decl: {s}", .{name});

            if(std.mem.startsWith(u8, name, "@\"") and std.mem.endsWith(u8, name, "\"")) {
                name = name[2..name.len - 1];
                log.debug("stripped name: {s}", .{name});
            }

            if (gen.ignoredDecls.contains(name)) return null;

            const location = Location(gen.path, ast.tokenLocation(0, var_decl.firstToken()));

            const var_type_node = var_decl.ast.type_node;
            const var_type_start = ast.firstToken(var_type_node);
            const var_type_end = ast.lastToken(var_type_node);
            const var_type_src = tokensSlice(ast, var_type_start, var_type_end);

            const var_init_node = var_decl.ast.init_node;
            const var_init_start = ast.firstToken(var_init_node);
            const var_init_end = ast.lastToken(var_init_node);
            const var_init = tokensSlice(ast, var_init_start, var_init_end);

            if (!std.mem.startsWith(u8, name, gen.prefix)) {
                log.warn("{}: public variable {s} does not start with {s}", .{ location, name, gen.prefix });
            }

            if (std.mem.endsWith(u8, var_type_src, "type")) {
                std.debug.assert(mut == .keyword_const);
                return Member{
                    .TypeDef = .{
                        .name = name,
                        .location = location,
                        .kind = if (std.mem.startsWith(u8, var_type_src, "custom")) .Custom else if (std.mem.startsWith(u8, var_type_src, "opaque")) .Opaque else .Extern,
                    },
                };
            } else if (mut == .keyword_const) {
                if (exp == .keyword_export) {
                    log.warn("{}: public constant {s} does not need to be exported", .{ location, name });
                }

                return Member{
                    .Const = .{
                        .name = name,
                        .location = location,
                        .typeExpr = if (var_type_src.len > 0) try convertTypeExpr(gen.allocator, var_type_src) else {
                            log.err("{}: missing type expr for {s}", .{location, name});
                            return error.MissingTypeExpr;
                        },
                        .valueExpr = var_init,
                    },
                };
            } else if (mut == .keyword_var) {
                if (exp != .keyword_export) {
                    log.warn("{}: public variable {s} is not exported", .{ location, name });
                    return null;
                }

                return Member{
                    .Var = .{
                        .name = name,
                        .location = location,
                        .typeExpr = if (var_type_src.len > 0) try convertTypeExpr(gen.allocator, var_type_src) else {
                            log.err("{}: miissing type expr for {s}", .{location, name});
                            return error.MissingTypeExpr;
                        },
                    },
                };
            } else unreachable;
        },

        else => return null,
    }
}

fn convertTypeExpr(allocator: std.mem.Allocator, src: []const u8) ![]const u8 {
    var slice = src;

    if (slice[0] == '?') {
        std.debug.assert(slice[1] == '*');
        slice = slice[1..];
    }

    if (slice[0] == '*') {
        return try std.fmt.allocPrint(allocator, "{s}*", .{try translatePrimitiveType(allocator, slice[1..])});
    } else {
        return try translatePrimitiveType(allocator, slice);
    }
}

fn translatePrimitiveType(allocator: std.mem.Allocator, slice: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, slice, "BB_")) {
        return slice;
    } else if (strCase(slice, .{ "bool", "void" })) {
        return slice;
    } else if (strCase(slice, .{ "usize", "isize" })) {
        if (slice[0] == 'u') {
            return "size_t";
        } else {
            return "ssize_t";
        }
    } else if (strCase(slice, .{ "i8", "i16", "i32", "i64" })) {
        const size = slice[1..];
        return try std.fmt.allocPrint(allocator, "int{s}_t", .{size});
    } else if (strCase(slice, .{ "u8", "u16", "u32", "u64" })) {
        const size = slice[1..];
        return try std.fmt.allocPrint(allocator, "uint{s}_t", .{size});
    } else if (strCase(slice, .{"anyopaque"})) {
        return "void";
    } else {
        log.err("unrecognized type `{s}`", .{slice});
        return error.UnrecognizedType;
    }
}

inline fn strCase(slice: []const u8, comptime options: anytype) bool {
    inline for (0..options.len) |i| {
        if (std.mem.eql(u8, slice, options[i])) {
            return true;
        }
    }

    return false;
}

fn tagStr(kw: zig.Token.Tag) []const u8 {
    switch (kw) {
        .keyword_pub => return "pub",
        .keyword_const => return "const",
        .keyword_var => return "var",
        .keyword_fn => return "fn",
        .keyword_export => return "export",
        else => return "unknown",
    }
}

fn tokensSlice(ast: zig.Ast, start: zig.Ast.TokenIndex, end: zig.Ast.TokenIndex) []const u8 {
    const span = ast.tokensToSpan(start, end, end);

    return ast.source[span.start..span.end];
}

const LocationFmt = struct {
    path: []const u8,
    line: usize,

    pub fn format(self: LocationFmt, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        if (std.mem.eql(u8, "comment", fmt)) {
            if (RENDER_LINE_COMMENT) {
                try writer.print("// [{s}:{d}]\n", .{ self.path, self.line + 1 });
            }
        } else {
            try writer.print("[{s}:{d}]", .{ self.path, self.line + 1 });
        }
    }
};

fn Location(path: []const u8, loc: zig.Ast.Location) LocationFmt {
    return .{ .path = path, .line = loc.line };
}

const TypeId = enum(u48) {
    _,

    fn of(comptime T: type) TypeId {
        const H = struct {
            var byte: u8 = 0;
            var _ = T;
        };

        return @enumFromInt(@as(u48, @truncate(@intFromPtr(&H.byte))));
    }

    fn render(self: TypeId, gen: *const Generator, writer: anytype) !void {
        const ty = gen.idToType.get(self) orelse unreachable;
        try ty.render(gen, writer);
    }
};

const Type = struct {
    declName: ?[]const u8,
    zigName: []const u8,
    info: TypeInfo,

    fn renderDecl(self: Type, gen: *const Generator, writer: anytype) !void {
        if (self.declName) |dn| switch (self.info) {
            .Function => {
                try writer.writeAll("typedef ");
                try self.info.renderDecl(dn, gen, writer);
                try writer.writeAll(";");
            },
            else => {
                try writer.writeAll("typedef ");
                try self.info.renderDecl(dn, gen, writer);
                try writer.print(" {s};", .{dn});
            },
        } else {
            return error.InvalidDecl;
        }
    }

    fn render(self: Type, gen: *const Generator, writer: anytype) !void {
        if (self.declName) |dn| {
            try writer.writeAll(dn);
        } else {
            try self.info.render(gen, writer);
        }
    }
};

fn toUpperStr(allocator: std.mem.Allocator, str: []const u8) anyerror![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    for (str) |c| {
        if (!std.ascii.isASCII(c)) {
            return error.InvalidAscii;
        }

        try buf.append(std.ascii.toUpper(c));
    }
    return buf.items;
}

const TypeInfo = union(enum) {
    Enum: []const []const u8,
    Union: []const Field,
    Struct: Struct,
    Opaque: void,
    Pointer: TypeId,
    Function: Function,
    Primitive: []const u8,

    const Struct = struct {
        packType: ?TypeId,
        fields: []const Field,
    };

    const Field = struct {
        name: []const u8,
        type: TypeId,
    };

    const Function = struct {
        returnType: TypeId,
        params: []const TypeId,
    };

    fn render(self: TypeInfo, gen: *const Generator, writer: anytype) anyerror!void {
        return self.renderDecl(null, gen, writer);
    }

    fn renderDecl(self: TypeInfo, name: ?[]const u8, gen: *const Generator, writer: anytype) anyerror!void {
        switch (self) {
            .Enum => |x| {
                try if (name) |n| writer.print("enum {s} {{", .{n}) else writer.writeAll("enum {");
                if (x.len > 0) try writer.writeAll("\n");
                if (if (name) |n| gen.enumSuffixes.get(n) orelse null else null) |suffix| {
                    for (x) |variantName| {
                        const upper = toUpperStr(gen.allocator, variantName) catch |err| {
                            log.err("cannot convert variant name {s} to upper case, error {}", .{variantName, err});
                            return err;
                        };
                        try writer.print("    {s}{s}_{s},\n", .{ gen.prefix, upper, suffix });
                    }
                } else {
                    for (x) |variantName| {
                        const upper = toUpperStr(gen.allocator, variantName) catch |err| {
                            log.err("cannot convert variant name {s} to upper case, error {}", .{variantName, err});
                            return err;
                        };
                        try writer.print("    {s}{s},\n", .{ gen.prefix, upper });
                    }
                }
                try writer.writeAll("}");
            },
            .Union => |x| {
                try if (name) |n| writer.print("union {s} {{", .{n}) else writer.writeAll("union {");
                if (x.len > 0) try writer.writeAll("\n");
                for (x) |field| {
                    try writer.writeAll("    ");
                    try field.type.render(gen, writer);
                    try writer.print(" {s};\n", .{field.name});
                }
                try writer.writeAll("}");
            },
            .Struct => |x| {
                try if (name) |n| writer.print("struct {s} {{", .{n}) else writer.writeAll("struct {");
                if (x.fields.len > 0) try writer.writeAll("\n");
                for (x.fields) |field| {
                    try writer.writeAll("    ");
                    try field.type.render(gen, writer);
                    try writer.print(" {s};\n", .{field.name});
                }
                try writer.writeAll("}");
            },
            .Opaque => try writer.writeAll("void"),
            .Pointer => |x| {
                try x.render(gen, writer);
                try writer.writeAll("*");
            },
            .Function => |x| {
                try x.returnType.render(gen, writer);
                try if (name) |n| writer.print(" (*{s}) (", .{n}) else return error.InvalidFunctionPrint;
                for (x.params, 0..) |param, i| {
                    try param.render(gen, writer);
                    if (i < x.params.len - 1) {
                        try writer.writeAll(", ");
                    }
                }
                try writer.writeAll(")");
            },
            .Primitive => |x| try writer.print("{s}", .{x}),
        }
    }
};

fn HeaderGenerator(comptime Module: type) type {
    const S: ZigType.Struct = switch (@typeInfo(Module)) {
        .Struct => |s| s,
        else => @compileError("Expected a struct for c type info generation"),
    };

    const GENERATION_DATA = @field(Module, DATA_SOURCE_NAME);

    return struct {
        allocator: std.mem.Allocator,
        ignoredDecls: std.StringHashMap(void),
        path: []const u8,
        nameToId: std.StringHashMap(TypeId),
        idToType: std.AutoHashMap(TypeId, Type),
        head: []const u8,
        foot: []const u8,
        prefix: []const u8,
        enumSuffixes: std.StringHashMap([]const u8),
        customTypes: std.StringHashMap(CustomType),
        errorStack: std.ArrayList([]const u8),

        const Self = @This();

        const CustomType = GENERATION_DATA.CustomType;

        fn isValidTag(comptime T: type) bool {
            return switch (@typeInfo(T)) {
                .Int => |t| t.bits == 8 or t.bits == 16 or t.bits == 32,
                else => false,
            };
        }

        fn isEmitableType(comptime T: type) bool {
            return switch (@typeInfo(T)) {
                .Void,
                .Bool,
                .Opaque,
                => true,

                .Int => |t| t.bits == 8 or t.bits == 16 or t.bits == 32 or t.bits == 64,
                .Float => |t| t.bits == 32 or t.bits == 64,
                .Fn => |t| t.calling_convention == .C,
                .Struct => |t| t.layout == .@"extern" or t.layout == .@"packed",
                .Union => |t| t.layout == .@"extern" and t.tag_type == null,
                .Enum => |t| t.is_exhaustive and isValidTag(t.tag_type),
                .Pointer => |t| isEmitableType(t.child) and t.size != .Slice,
                .Optional => |t| @typeInfo(t.child) == .Pointer,

                else => false,
            };
        }

        fn init(allocator: std.mem.Allocator) !Self {
            var self = Self{
                .allocator = allocator,
                .ignoredDecls = std.StringHashMap(void).init(allocator),
                .path = GENERATION_DATA.source,
                .nameToId = std.StringHashMap(TypeId).init(allocator),
                .idToType = std.AutoHashMap(TypeId, Type).init(allocator),
                .head = GENERATION_DATA.head,
                .foot = GENERATION_DATA.foot,
                .prefix = GENERATION_DATA.prefix,
                .enumSuffixes = std.StringHashMap([]const u8).init(allocator),
                .customTypes = std.StringHashMap(CustomType).init(allocator),
                .errorStack = std.ArrayList([]const u8).init(allocator),
            };

            try self.ignoredDecls.put("std_options", {});
            try self.ignoredDecls.put(DATA_SOURCE_NAME, {});

            inline for (0..GENERATION_DATA.ignoredDecls.len) |i| {
                try self.ignoredDecls.put(GENERATION_DATA.ignoredDecls[i], {});
            }

            inline for (comptime std.meta.fieldNames(@TypeOf(GENERATION_DATA.customTypes))) |declName| {
                try self.customTypes.put(declName, @field(GENERATION_DATA.customTypes, declName));
            }

            inline for (comptime std.meta.fieldNames(@TypeOf(GENERATION_DATA.enumSuffixes))) |declName| {
                try self.enumSuffixes.put(declName, @field(GENERATION_DATA.enumSuffixes, declName));
            }

            inline for (S.decls) |decl| {
                const T = @field(Module, decl.name);

                if (@TypeOf(T) != type) continue;

                if (isEmitableType(T)) {
                    self.errorStack.append(decl.name) catch unreachable;
                    defer self.errorStack.clearRetainingCapacity();
                    _ = self.genTypeDecl(decl.name, T) catch |err| {
                        log.err("error: {}", .{err});
                        log.err("error stack:", .{});
                        for (self.errorStack.items) |ty| {
                            log.err("    {s}", .{ty});
                        }
                        return err;
                    };
                }
            }

            return self;
        }

        fn lookupType(self: *const Self, name: []const u8) ?*Type {
            const id = self.nameToId.get(name) orelse return null;
            return self.idToType.getPtr(id) orelse unreachable;
        }

        fn genType(self: *Self, comptime T: type) !TypeId {
            return try self.genTypeDecl(null, T);
        }

        fn genTypeDecl(self: *Self, declName: ?[]const u8, comptime T: type) !TypeId {
            const zigName = @typeName(T);
            self.errorStack.append(zigName) catch unreachable;

            var err = false;
            defer if (!err) {
                _ = self.errorStack.pop();
            };
            errdefer err = true;

            const id = TypeId.of(T);
            if (self.idToType.contains(id)) return id;

            const info = try self.genTypeInfo(T);
            const ty = Type{
                .declName = declName,
                .zigName = zigName,
                .info = info,
            };

            try self.idToType.put(id, ty);

            if (declName) |dn| {
                std.debug.assert(!self.nameToId.contains(dn));
                try self.nameToId.put(dn, id);
            }

            return id;
        }

        fn genTypeInfo(self: *Self, comptime T: type) !TypeInfo {
            const info = @typeInfo(T);

            return switch (T) {
                c_char => TypeInfo{ .Primitive = "char" },
                c_short => TypeInfo{ .Primitive = "short" },
                c_int => TypeInfo{ .Primitive = "int" },
                c_long => TypeInfo{ .Primitive = "long" },
                c_longlong => TypeInfo{ .Primitive = "long long" },
                c_longdouble => TypeInfo{ .Primitive = "long double" },
                c_uint => TypeInfo{ .Primitive = "unsigned int" },
                c_ushort => TypeInfo{ .Primitive = "unsigned short" },
                c_ulong => TypeInfo{ .Primitive = "unsigned long" },
                c_ulonglong => TypeInfo{ .Primitive = "unsigned long long" },

                else => switch (info) {
                    .Void => TypeInfo{ .Primitive = "void" },
                    .Bool => TypeInfo{ .Primitive = "bool" },
                    .Int => |x| switch (x.signedness) {
                        .signed => switch (x.bits) {
                            8 => TypeInfo{ .Primitive = "int8_t" },
                            16 => TypeInfo{ .Primitive = "int16_t" },
                            32 => TypeInfo{ .Primitive = "int32_t" },
                            64 => TypeInfo{ .Primitive = "int64_t" },
                            else => return error.InvalidType,
                        },
                        .unsigned => switch (x.bits) {
                            8 => TypeInfo{ .Primitive = "uint8_t" },
                            16 => TypeInfo{ .Primitive = "uint16_t" },
                            32 => TypeInfo{ .Primitive = "uint32_t" },
                            64 => TypeInfo{ .Primitive = "uint64_t" },
                            else => return error.InvalidType,
                        },
                    },
                    .Float => |x| switch (x.bits) {
                        32 => TypeInfo{ .Primitive = "float" },
                        64 => TypeInfo{ .Primitive = "double" },
                        else => return error.InvalidType,
                    },
                    .Opaque => TypeInfo{ .Opaque = {} },
                    .Fn => |x| fun: {
                        if (x.calling_convention != .C) return error.InvalidType;

                        const returnType = try self.genType(x.return_type orelse return error.InvalidType);

                        var paramTypes = std.ArrayList(Type).init(self.allocator);
                        inline for (x.params) |param| {
                            try paramTypes.append(try self.genType(param.type orelse return error.InvalidType));
                        }

                        break :fun TypeInfo{ .Function = .{ .returnType = returnType, .params = paramTypes.items } };
                    },
                    .Struct => |x| str: {
                        if (x.layout != .@"extern" and x.layout != .@"packed") return error.InvalidType;

                        var fields = std.ArrayList(TypeInfo.Field).init(self.allocator);
                        inline for (x.fields) |field| {
                            try fields.append(TypeInfo.Field{ .name = field.name, .type = try self.genType(field.type) });
                        }

                        const packType = if (x.layout != .@"packed") null else if (x.backing_integer) |bi| pack: {
                            break :pack try self.genType(bi);
                        } else null;

                        break :str TypeInfo{ .Struct = .{
                            .fields = fields.items,
                            .packType = packType,
                        } };
                    },
                    .Union => |x| un: {
                        if (x.layout != .@"extern") return error.InvalidType;
                        if (x.tag_type != null) return error.InvalidType;

                        var fields = std.ArrayList(TypeInfo.Field).init(self.allocator);
                        inline for (x.fields) |field| {
                            try fields.append(TypeInfo.Field{ .name = field.name, .type = try self.genType(field.type) });
                        }

                        break :un TypeInfo{
                            .Union = fields.items,
                        };
                    },
                    .Enum => |x| en: {
                        if (!isValidTag(x.tag_type)) return error.InvalidType;

                        var fields = std.ArrayList([]const u8).init(self.allocator);
                        inline for (x.fields) |field| {
                            try fields.append(field.name);
                        }

                        break :en TypeInfo{ .Enum = fields.items };
                    },
                    .Pointer => |x| ptr: {
                        if (x.size == .Slice) return error.InvalidType;
                        const child = try self.genType(x.child);
                        break :ptr TypeInfo{ .Pointer = child };
                    },
                    .Optional => |x| opt: {
                        if (@typeInfo(x.child) != .Pointer) return error.InvalidType;
                        break :opt self.genType(x.child);
                    },
                    else => return error.InvalidType,
                },
            };
        }
    };
}
