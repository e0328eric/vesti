const std = @import("std");
const diag = @import("../diagnostic.zig");
const mem = std.mem;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Child = std.process.Child;
const CowStr = @import("../CowStr.zig").CowStr;
const Codegen = @import("../Codegen.zig");
const Io = std.Io;
const Parser = @import("../parser/Parser.zig");
const LatexEngine = Parser.LatexEngine;

pub const Error = Allocator.Error || error{
    JlInitFailed,
};

const Self = @This();

// C allocator using at Julia
const c_alloc = std.heap.c_allocator;

//          ╭─────────────────────────────────────────────────────────╮
//          │               Extern Types and Functions                │
//          ╰─────────────────────────────────────────────────────────╯

const jl_value_t = opaque {};

extern "c" fn jl_init() void;
extern "c" fn jl_atexit_hook(exitcode: c_int) void;
extern "c" fn jl_eval_string(code: [*:0]const u8) ?*jl_value_t;

extern "c" fn run_jlcode(code: [*:0]const u8, fmt: [*:0]const u8, ...) bool;

//          ╭─────────────────────────────────────────────────────────╮
//          │                    Public Functions                     │
//          ╰─────────────────────────────────────────────────────────╯

pub fn init(engine: LatexEngine) Error!Self {
    ves_jl.vesti_output = try c_alloc.create(ArrayList(u8));
    errdefer c_alloc.destroy(ves_jl.vesti_output);
    ves_jl.vesti_output.* = try ArrayList(u8).initCapacity(c_alloc, 100);
    errdefer ves_jl.vesti_output.deinit(c_alloc);
    ves_jl.engine = engine;

    // initializing vesti
    jl_init();

    const julia_vesti = @embedFile("vesti.jl");
    if (!run_jlcode(
        @ptrCast(julia_vesti),
        "failed to initialize Vesti module\n",
    )) return error.JlInitFailed;

    return .{};
}

pub fn deinit(self: *Self) void {
    _ = self;

    jl_atexit_hook(0);
    ves_jl.vesti_output.deinit(c_alloc);
    c_alloc.destroy(ves_jl.vesti_output);
}

pub fn getVestiOutputStr(self: *Self, outside_alloc: Allocator) !ArrayList(u8) {
    _ = self;

    const data = try ves_jl.vesti_output.clone(outside_alloc);
    ves_jl.vesti_output.clearRetainingCapacity();
    return data;
}

pub fn runJlCode(self: *Self, code: []const u8, is_global: bool) !void {
    _ = self;

    if (is_global) {
        if (!run_jlcode(@ptrCast(code), "Failed to evaluate jlcode\n")) {
            return error.JlEvalFailed;
        }
        return;
    }

    // base64 encoding for jlcode
    var b64 = Io.Writer.Allocating.init(c_alloc);
    defer b64.deinit();

    try std.base64.standard.Encoder.encodeWriter(&b64.writer, code);

    const rand_int = std.crypto.random.int(u64);
    const temp_jl = try std.fmt.allocPrint(c_alloc, "tmp_{x}.jl", .{rand_int});
    defer c_alloc.free(temp_jl);

    const jlcode = try std.fmt.allocPrintSentinel(
        c_alloc,
        \\let vesjl = Module(:vesjl)
        \\    # evaluate jlcode
        \\    import Base64
        \\    __jlcode_src__ = String(Base64.base64decode("{s}"))
        \\    # make importing Main.Vesti in default
        \\    __jlcode_src__ = """import Main.Vesti
        \\    """ * __jlcode_src__
        \\    Base.include_string(vesjl, __jlcode_src__, "{s}")
        \\    nothing
        \\end
    ,
        .{ b64.written(), temp_jl },
        0,
    );
    defer c_alloc.free(jlcode);

    if (!run_jlcode(@ptrCast(jlcode), "Failed to evaluate jlcode\n")) {
        return error.JlEvalFailed;
    }
}

pub fn changeLatexEngine(self: *Self, new_engine: LatexEngine) void {
    _ = self;
    ves_jl.engine = new_engine;
}

//          ╭────────────────────────────────────────────────────────╮
//          │       boilerplates for making vesti julia module       │
//          ╰────────────────────────────────────────────────────────╯

const VesJl = extern struct {
    vesti_output: *ArrayList(u8),
    engine: LatexEngine,
};

export var ves_jl: VesJl = undefined; // vesti_output will be initialized

export fn zigAllocatorAlloc(n: usize) callconv(.c) ?*anyopaque {
    const ptr = c_alloc.alloc(u8, n) catch return null;
    return @ptrCast(ptr);
}

export fn zigAllocatorFree(ptr: ?*anyopaque, n: usize) callconv(.c) void {
    if (ptr) |p| c_alloc.free(@as([*]u8, @ptrCast(@alignCast(p)))[0..n]);
}

export fn appendCStr(self: *VesJl, str: [*:0]const u8, len: usize) bool {
    self.vesti_output.appendSlice(c_alloc, str[0..len]) catch return false;
    return true;
}

export fn parseVesti(
    output_str: *?[*:0]const u8,
    output_str_len: *usize,
    code: [*:0]const u8,
    len: usize,
) void {
    const vesti_code = code[0..len];

    var diagnostic = diag.Diagnostic{
        .allocator = c_alloc,
    };
    defer diagnostic.deinit();

    var cwd_dir = std.fs.cwd();
    var parser = Parser.init(
        c_alloc,
        vesti_code,
        &cwd_dir,
        &diagnostic,
        false, // disallow nested jlcode
        null, // disallow changing engine type
    ) catch |err| {
        std.debug.print(
            "parse init failed because of {s}\n",
            .{@errorName(err).ptr},
        );
        output_str.* = null;
        return;
    };

    var ast = parser.parse() catch |err| {
        switch (err) {
            Parser.ParseError.ParseFailed => {
                diagnostic.initMetadata(
                    CowStr.init(.Borrowed, .{@as([]const u8, "<jlcode>")}),
                    CowStr.init(.Borrowed, .{@as([]const u8, @ptrCast(vesti_code))}),
                );
                diagnostic.prettyPrint(true) catch {
                    std.debug.print(
                        "diagnostic pretty print failed\n",
                        .{},
                    );
                    output_str.* = null;
                    return;
                };
            },
            else => {},
        }
        std.debug.print(
            "parse failed because of {s}\n",
            .{@errorName(err).ptr},
        );
        output_str.* = null;
        return;
    };
    defer {
        for (ast.items) |*stmt| stmt.deinit(c_alloc);
        ast.deinit(c_alloc);
    }

    var aw = Io.Writer.Allocating.initCapacity(c_alloc, 256) catch @panic("OOM");
    errdefer aw.deinit();
    var codegen = Codegen.init(
        c_alloc,
        vesti_code,
        ast.items,
        &diagnostic,
    ) catch |err| {
        std.debug.print(
            "codegen init failed because of {s}\n",
            .{@errorName(err).ptr},
        );
        output_str.* = null;
        return;
    };
    defer codegen.deinit();
    codegen.codegen(null, &aw.writer) catch |err| {
        diagnostic.initMetadata(
            CowStr.init(.Borrowed, .{@as([]const u8, "<jlcode>")}),
            CowStr.init(.Borrowed, .{@as([]const u8, @ptrCast(vesti_code))}),
        );
        diagnostic.prettyPrint(true) catch {
            std.debug.print(
                "diagnostic pretty print failed\n",
                .{},
            );
            output_str.* = null;
            return;
        };
        std.debug.print(
            "vesti code generation failed because of {s}\n",
            .{@errorName(err).ptr},
        );
        output_str.* = null;
        return;
    };

    const content = aw.toOwnedSliceSentinel(0) catch @panic("OOM");

    output_str.* = content.ptr;
    output_str_len.* = content.len;
    return;
}
