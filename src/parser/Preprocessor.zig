const std = @import("std");
const mem = std.mem;

const Allocator = mem.Allocator;
const MultiArrayList = std.MultiArrayList;
const Lexer = @import("../lexer/Lexer.zig");
const Token = @import("../lexer/Token.zig");
const TokenType = Token.TokenType;

allocator: Allocator,
lexer: Lexer,

const Self = @This();

pub fn init(allocator: Allocator, source: []const u8) !Self {
    var self: Self = undefined;

    self.allocator = allocator;
    self.lexer = try Lexer.init(source);

    return self;
}

pub fn preprocess(self: *Self) !MultiArrayList(Token) {
    var output: MultiArrayList(Token) = .{};

    while (!self.lexer.lex_finished) {
        const token = self.nextToken();
        try self.preprocessToken(token, &output);
    }

    return output;
}

inline fn nextToken(self: *Self) Token {
    return self.lexer.next();
}

inline fn expect(
    self: Self,
    comptime is_peek: enum(u1) { current, peek },
    comptime toktypes: []const TokenType,
) bool {
    var output: u1 = 0;
    const what_token = switch (is_peek) {
        .current => "curr_tok",
        .peek => "peek_tok",
    };
    inline for (toktypes) |toktype| {
        output |= @intFromBool(@intFromEnum(@field(self, what_token).toktype) ==
            @intFromEnum(toktype));
    }
    return output == 1;
}

fn preprocessToken(self: *Self, token: Token, tok_list: *MultiArrayList(Token)) !void {
    switch (token.toktype) {
        .BuiltinFunction => |name| {
            if (mem.eql(u8, name, "def")) {
                try self.preprocessDef(tok_list);
            } else {
                try tok_list.append(self.allocator, token);
            }
        },
        else => try tok_list.append(self.allocator, token),
    }
}

const ComptimeFunction = struct {
    name: []const u8,
    params: MultiArrayList(Token),
    contents: MultiArrayList(Token),
};

fn preprocessDef(self: *Self, tok_list: *MultiArrayList(Token)) !void {
    _ = self;
    _ = tok_list;
}
