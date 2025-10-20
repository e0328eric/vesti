const std = @import("std");
const config = @import("config.zig");
const config_x = @import("config.x.zig");
const ascii = std.ascii;

const d = config.default;
const wcwidth = config_x.wcwidth;

// implemetn is_alphanumeric and is_ascii_digit
const vesti_uucode_custom = config.Extension{
    .inputs = &.{"general_category"},
    .compute = &computeVestiUucodeCustom,
    .fields = &.{
        .{ .name = "is_alphanumeric", .type = bool },
        .{ .name = "is_numeric", .type = bool },
        .{ .name = "is_ascii_digit", .type = bool },
    },
};

fn computeVestiUucodeCustom(
    allocator: std.mem.Allocator,
    cp: u21,
    data: anytype,
    backing: anytype,
    tracking: anytype,
) std.mem.Allocator.Error!void {
    _ = allocator;
    _ = backing;
    _ = tracking;

    const gc = data.general_category;

    if (cp <= 0xFF and ascii.isDigit(@truncate(cp))) {
        data.is_ascii_digit = true;
        data.is_alphanumeric = true;
        data.is_numeric = true;
    } else {
        data.is_ascii_digit = false;

        switch (gc) {
            .number_decimal_digit, // Nd
            .number_letter, // Nl
            .number_other, // No
            => {
                data.is_numeric = true;
                data.is_alphanumeric = true;
            },
            .letter_uppercase, // Lu
            .letter_lowercase, // Ll
            .letter_titlecase, // Lt
            .letter_modifier, // Lm
            .letter_other, // Lo
            => {
                data.is_numeric = false;
                data.is_alphanumeric = true;
            },
            else => {
                data.is_numeric = false;
                data.is_alphanumeric = false;
            },
        }
    }
}

// Configure tables with the `tables` declaration.
// The only required field is `fields`, and the rest have reasonable defaults.
pub const tables = [_]config.Table{
    .{
        .stages = .auto,
        .packing = .auto,
        .extensions = &.{
            wcwidth,
            vesti_uucode_custom,
        },
        .fields = &.{
            wcwidth.field("wcwidth"),
            vesti_uucode_custom.field("is_ascii_digit"),
            vesti_uucode_custom.field("is_numeric"),
            vesti_uucode_custom.field("is_alphanumeric"),
            d.field("is_alphabetic"),
        },
    },
};
