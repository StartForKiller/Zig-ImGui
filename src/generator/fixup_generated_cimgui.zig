const std = @import("std");


fn read_all_posix_line_endings(input_reader: std.io.AnyReader, output: *std.ArrayList(u8)) !void {
    var buf = std.io.bufferedReader(input_reader);
    var reader = buf.reader();

    while (true) {
        const b1 = reader.readByte()
            catch |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            };

        switch (b1) {
            '\r' => {
                const b2 = reader.readByte()
                    catch |err| switch (err) {
                        error.EndOfStream => {
                            try output.append(b1);
                            return;
                        },
                        else => return err,
                    };

                switch (b2) {
                    '\n' => try output.append('\n'),
                    else => {
                        try output.append(b1);
                        try output.append(b2);
                    }
                }
            },
            else => try output.append(b1),
        }
    }
}

fn fix_cpp(allocator: std.mem.Allocator, input_folder: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{
        input_folder,
        "cimgui.cpp",
    });
    defer allocator.free(path);

    const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_write });
    defer file.close();

    var cpp_contents = std.ArrayList(u8).init(allocator);
    defer cpp_contents.deinit();
    try read_all_posix_line_endings(file.reader().any(), &cpp_contents);

    const bad_define_text = "#define IMGUI_ENABLE_FREETYPE\n";
    const bad_define_text_start_pos = std.mem.indexOf(u8, cpp_contents.items, bad_define_text)
        orelse return error.InvalidSourceFile;
    try cpp_contents.replaceRange(bad_define_text_start_pos, bad_define_text.len, "");

    const bad_include_text = "#include \"./imgui/";
    var replace_count: usize = 0;
    while (std.mem.indexOf(u8, cpp_contents.items, bad_include_text)) |found| {
        try cpp_contents.replaceRange(found, bad_include_text.len, "#include \"");
        replace_count += 1;
    }
    if (replace_count < 1) return error.InvalidSourceFile;

    const freetype_start_text = "ImGuiFreeType_GetBuilderForFreeType()";
    const freetype_start_pos = blk: {
        var start = std.mem.indexOf(u8, cpp_contents.items, freetype_start_text)
            orelse return error.InvalidSourceFile;
        while (start > 0) : (start -= 1) {
            if (cpp_contents.items[start] == '\n') break :blk start;
        }

        return error.InvalidSourceFile;
    };
    try cpp_contents.insertSlice(freetype_start_pos, "\n#ifdef IMGUI_ENABLE_FREETYPE");

    const freetype_end_text = "\n/////////////////////////////manual written functions";
    const freetype_end_text_start_pos = blk: {
        var end = std.mem.indexOf(u8, cpp_contents.items, freetype_end_text)
            orelse return error.InvalidSourceFile;
        while (end > 0) : (end -= 1) {
            if (cpp_contents.items[end] == '\n') {
                continue;
            }

            break :blk end + 1;
        }

        return error.InvalidSourceFile;
    };
    try cpp_contents.insertSlice(freetype_end_text_start_pos, "\n#endif");

    try file.seekTo(0);
    try file.setEndPos(0);
    try file.writeAll(cpp_contents.items);
}

fn fix_h(allocator: std.mem.Allocator, input_folder: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{
        input_folder,
        "cimgui.h",
    });
    defer allocator.free(path);

    const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_write });
    defer file.close();

    var h_contents = std.ArrayList(u8).init(allocator);
    defer h_contents.deinit();
    try read_all_posix_line_endings(file.reader().any(), &h_contents);

    const bad_typing_text = "typedef void* ImTextureID;";
    const bad_typing_text_start_pos = std.mem.indexOf(u8, h_contents.items, bad_typing_text)
        orelse return error.InvalidSourceFile;
    try h_contents.replaceRange(bad_typing_text_start_pos, bad_typing_text.len, "typedef ImU64 ImTextureID;");

    const freetype_start_text = "ImGuiFreeType_GetBuilderForFreeType(";
    const freetype_start_pos = blk: {
        var start = std.mem.indexOf(u8, h_contents.items, freetype_start_text)
            orelse return error.InvalidSourceFile;
        while (start > 0) : (start -= 1) {
            if (h_contents.items[start] == '\n') break :blk start;
        }

        return error.InvalidSourceFile;
    };
    try h_contents.insertSlice(freetype_start_pos, "\n#ifdef IMGUI_ENABLE_FREETYPE");

    const freetype_end_text = "\n/////////////////////////hand written functions";
    const freetype_end_text_start_pos = blk: {
        var end = std.mem.indexOf(u8, h_contents.items, freetype_end_text)
            orelse return error.InvalidSourceFile;
        while (end > 0) : (end -= 1) {
            if (h_contents.items[end] == '\n') {
                continue;
            }

            break :blk end + 1;
        }

        return error.InvalidSourceFile;
    };
    try h_contents.insertSlice(freetype_end_text_start_pos, "\n#endif");

    try file.seekTo(0);
    try file.setEndPos(0);
    try file.writeAll(h_contents.items);
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(gpa.allocator());
    defer std.process.argsFree(gpa.allocator(), args);
    const input_folder: []const u8 = args[1];

    try fix_cpp(gpa.allocator(), input_folder);
    try fix_h(gpa.allocator(), input_folder);
}
