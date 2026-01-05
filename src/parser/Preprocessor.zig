const std = @import("std");

const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;
const Lexer = @import("../lexer/Lexer.zig");
const Token = @import("../lexer/Token.zig");

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

fn preprocessToken(self: *Self, token: Token, tok_list: *MultiArrayList(Token)) !void {
    switch (token.toktype) {
        .BuiltinFunction => {
            // TODO: handle #def builtin
            try tok_list.append(self.allocator, token);
        },
        else => try tok_list.append(self.allocator, token),
    }
}
