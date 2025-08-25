const std = @import("std");

const UNICODE_VERSION = @import("unicode").UNICODE_VERSION;

fn fetchFile(
    comptime dirname: []const u8,
    comptime filename: []const u8,
    comptime unicode_url: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // our http client, this can make multiple requests
    // (and is even threadsafe, although individual requests are not).
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // we can `catch unreachable` here because we can guarantee that this is a valid url.
    const uri = std.Uri.parse(unicode_url ++ filename) catch unreachable;

    var body = std.ArrayList(u8).init(allocator);
    defer body.deinit();

    // make the connection and set up the request
    const req = try client.fetch(.{
        .location = .{ .uri = uri },
        .response_storage = .{ .dynamic = &body },
        .max_append_size = 1e+9,
        .headers = .{
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = &.{
            .{ .name = "accept", .value = "text/plain" },
        },
    });

    if (req.status != .ok) {
        return error.FetchFailed;
    }

    // Output dir
    var cwd = std.fs.cwd();
    try cwd.makePath(dirname);

    // Output file
    if (cwd.access(dirname ++ filename, .{})) {
        std.log.debug("\tSkipping existing file: {s}", .{dirname ++ filename});
        return; // file already exists
    } else |_| {}

    var file = try cwd.createFile(dirname ++ filename, .{});
    defer file.close();
    try file.writeAll(body.items);
}

pub fn main() !void {
    std.log.info("Fetching Unicode files from the Internet...", .{});

    const aux_files = [_][]const u8{
        "GraphemeBreakProperty.txt",
        "GraphemeBreakTest.txt",
        "SentenceBreakProperty.txt",
        "SentenceBreakTest.txt",
        "WordBreakProperty.txt",
        "WordBreakTest.txt",
    };

    const ext_files = [_][]const u8{
        "DerivedCombiningClass.txt",
        "DerivedEastAsianWidth.txt",
        "DerivedGeneralCategory.txt",
        "DerivedNumericType.txt",
    };

    const ucd_files = [_][]const u8{
        "Blocks.txt",
        "CaseFolding.txt",
        "DerivedCoreProperties.txt",
        "DerivedNormalizationProps.txt",
        "HangulSyllableType.txt",
        "NormalizationTest.txt",
        "PropList.txt",
        "UnicodeData.txt",
    };

    var handles: [aux_files.len + ext_files.len + ucd_files.len + 2]std.Thread = undefined;
    comptime var i: usize = 0;

    inline for (aux_files) |filename| {
        handles[i] = try std.Thread.spawn(.{}, fetchFile, .{
            ".zig-cache/_ziglyph-data/ucd/auxiliary/",
            filename,
            "https://www.unicode.org/Public/" ++ UNICODE_VERSION ++ "/ucd/auxiliary/",
        });

        i += 1;
    }

    inline for (ext_files) |filename| {
        handles[i] = try std.Thread.spawn(.{}, fetchFile, .{
            ".zig-cache/_ziglyph-data/ucd/extracted/",
            filename,
            "https://www.unicode.org/Public/" ++ UNICODE_VERSION ++ "/ucd/extracted/",
        });

        i += 1;
    }

    inline for (ucd_files) |filename| {
        handles[i] = try std.Thread.spawn(.{}, fetchFile, .{
            ".zig-cache/_ziglyph-data/ucd/",
            filename,
            "https://www.unicode.org/Public/" ++ UNICODE_VERSION ++ "/ucd/",
        });

        i += 1;
    }

    handles[i] = try std.Thread.spawn(.{}, fetchFile, .{
        ".zig-cache/_ziglyph-data/ucd/emoji/",
        "emoji-data.txt",
        "https://www.unicode.org/Public/" ++ UNICODE_VERSION ++ "/ucd/emoji/",
    });

    i += 1;

    handles[i] = try std.Thread.spawn(.{}, fetchFile, .{
        ".zig-cache/_ziglyph-data/uca/",
        "allkeys.txt",
        "https://www.unicode.org/Public/UCA/" ++ UNICODE_VERSION ++ "/",
    });

    inline for (handles) |handle| handle.join();

    std.log.info("Fetching done!", .{});
}
