const std = @import("std");
const config = @import("config.zig");
const ascii = std.ascii;

const d = config.default;

pub const fields = &config.mergeFields(config.fields, &.{
    .{ .name = "vesti_uucode_custom", .type = CharType },
});

// implemetn is_alphanumeric and is_ascii_digit
pub const build_components = &config.mergeComponents(config.build_components, &.{
    .{
        .Impl = ComputeVestiUucodeCustom,
        .inputs = &.{"general_category"},
        .fields = &.{"vesti_uucode_custom"},
    },
});

pub const get_components: []const config.Component = &.{}; // not supported in uucode yet

const CharType = enum(u3) {
    is_ascii_digit,
    is_ascii_alphanumeric,
    is_nonascii_numeric,
    is_nonascii_nonnumber_alphabetic,
    otherwise,
};

const ComputeVestiUucodeCustom = struct {
    pub fn build(
        comptime InputRow: type,
        comptime Row: type,
        allocator: std.mem.Allocator,
        io: std.Io,
        inputs: config.MultiSlice(InputRow),
        rows: *config.MultiSlice(Row),
        backing: anytype,
        tracking: anytype,
    ) !void {
        _ = allocator;
        _ = io;
        _ = backing;
        _ = tracking;

        rows.len = config.num_code_points;
        const items = rows.items(.vesti_uucode_custom);
        const gc = inputs.items(.general_category);

        for (0..config.num_code_points) |i| {
            const cp: u21 = @intCast(i);

            if (cp <= 0xFF and ascii.isDigit(@truncate(cp))) {
                items[i] = CharType.is_ascii_digit;
            } else if (cp <= 0xFF and ascii.isAlphanumeric(@truncate(cp))) {
                items[i] = CharType.is_ascii_alphanumeric;
            } else {
                switch (gc[i]) {
                    .number_decimal_digit, // Nd
                    .number_letter, // Nl
                    .number_other, // No
                    => {
                        items[i] = CharType.is_nonascii_numeric;
                    },
                    .letter_uppercase, // Lu
                    .letter_lowercase, // Ll
                    .letter_titlecase, // Lt
                    .letter_modifier, // Lm
                    .letter_other, // Lo
                    => {
                        items[i] = CharType.is_nonascii_nonnumber_alphabetic;
                    },
                    else => {
                        items[i] = CharType.otherwise;
                    },
                }
            }
        }
    }
};

// Configure tables with the `tables` declaration.
// The only required field is `fields`, and the rest have reasonable defaults.
pub const tables = [_]config.Table{
    .{
        .stages = .auto,
        .packing = .auto,
        .fields = &.{
            "vesti_uucode_custom",
            "is_alphabetic",
            "wcwidth_standalone",
        },
    },
};
