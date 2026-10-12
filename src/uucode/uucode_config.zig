const std = @import("std");
const config = @import("config.zig");
const ascii = std.ascii;

const setBuiltField = config.setBuiltField;

// Register the custom boolean fields on top of the default fields.
pub const fields = &config.mergeFields(config.fields, &.{
    .{ .name = "is_alphanumeric", .type = bool },
    .{ .name = "is_numeric", .type = bool },
    .{ .name = "is_ascii_digit", .type = bool },
    .{ .name = "is_ascii_alphanumeric", .type = bool },
});

pub const build_components = &config.mergeComponents(config.build_components, &.{
    .{
        .Impl = VestiUucodeCustom,
        .inputs = &.{"general_category"},
        .fields = &.{
            "is_alphanumeric",
            "is_numeric",
            "is_ascii_digit",
            "is_ascii_alphanumeric",
        },
    },
});

pub const get_components = config.get_components;

// Configure tables with the `tables` declaration.
// The only required field is `fields`, and the rest have reasonable defaults.
pub const tables: []const config.Table = &.{
    .{
        .fields = &.{
            "wcwidth_standalone",
            "is_numeric",
            "is_alphanumeric",
            "is_ascii_digit",
            "is_ascii_alphanumeric",
            "is_alphabetic",
        },
    },
};

const VestiUucodeCustom = struct {
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

        for (0..config.num_code_points) |i| {
            const cp: u21 = @intCast(i);
            const input = inputs.get(i);
            const gc = input.general_category;
            var row: Row = undefined;

            if (cp <= 0xFF and ascii.isDigit(@truncate(cp))) {
                setBuiltField(&row, "is_ascii_digit", true);
                setBuiltField(&row, "is_ascii_alphanumeric", true);
                setBuiltField(&row, "is_alphanumeric", true);
                setBuiltField(&row, "is_numeric", true);
            } else if (cp <= 0xFF and ascii.isAlphabetic(@truncate(cp))) {
                setBuiltField(&row, "is_ascii_digit", false);
                setBuiltField(&row, "is_ascii_alphanumeric", true);
                setBuiltField(&row, "is_alphanumeric", true);
                setBuiltField(&row, "is_numeric", false);
            } else {
                setBuiltField(&row, "is_ascii_digit", false);
                setBuiltField(&row, "is_ascii_alphanumeric", false);

                switch (gc) {
                    .number_decimal_digit,
                    .number_letter,
                    .number_other,
                    => {
                        setBuiltField(&row, "is_numeric", true);
                        setBuiltField(&row, "is_alphanumeric", true);
                    },
                    .letter_uppercase,
                    .letter_lowercase,
                    .letter_titlecase,
                    .letter_modifier,
                    .letter_other,
                    => {
                        setBuiltField(&row, "is_numeric", false);
                        setBuiltField(&row, "is_alphanumeric", true);
                    },
                    else => {
                        setBuiltField(&row, "is_numeric", false);
                        setBuiltField(&row, "is_alphanumeric", false);
                    },
                }
            }

            rows.append(row);
        }
    }
};
