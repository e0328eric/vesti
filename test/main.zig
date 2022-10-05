test "testing vesti" {
    // Test Lexer
    _ = @import("lexer/lexer_test.zig");

    // Test Parser
    _ = @import("parser/parser_test.zig");
}
