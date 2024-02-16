const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    _ = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    _ = b.standardOptimizeOption(.{});

    const imgui_dep = b.dependency("imgui", .{});
    const cimgui_dep = b.dependency("cimgui", .{});

    // use system lua if available to run the cimgui generator script
    const lua_path: ?[]const u8 = b.findProgram(&.{ "luajit", "lua5.1" }, &.{})
        catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };

    // hopefully, this can be replaced by a rewrite in zig in the future, until
    // then, python is necessary to generate the bindings
    const python_path: ?[]const u8 = b.findProgram(&.{ "python", "python3" }, &.{})
        catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };

    const lua51_dep = blk: {
        if (lua_path == null) {
            break :blk b.lazyDependency("lua51", .{
                .target = b.host,
                .optimize = .ReleaseFast,
            });
        }

        break :blk null;
    };

    const python_w2c2zig_dep: ?*std.Build.Dependency = blk: {
        if (python_path == null) {
            break :blk b.lazyDependency("python_w2c2zig", .{
                .target = b.host,
                .optimize = .ReleaseFast,
            });
        }

        break :blk null;
    };

    const cimgui_generator_lazypath = cimgui_dep.path("generator/");
    const cimgui_generator_path = cimgui_generator_lazypath.getPath(b);

    const cimgui_generate_command =
        if (lua_path) |path|
            b.addSystemCommand(&.{ path })
        else
            b.addRunArtifact(lua51_dep.?.artifact("lua5.1"));

    cimgui_generate_command.addArgs(&.{
        b.pathJoin(&.{ cimgui_generator_path, "generator.lua" }),
        b.fmt("{s} cc", .{ b.graph.zig_exe }),
        "freetype",
        "-DIMGUI_ENABLE_STB_TRUETYPE -DIMGUI_USE_WCHAR32",
    });
    cimgui_generate_command.setCwd(cimgui_generator_lazypath);
    cimgui_generate_command.setEnvironmentVariable("IMGUI_PATH", imgui_dep.path("").getPath(b));

    const fix_tool = b.addExecutable(.{
        .name = "fix_cimgui_sources",
        .root_source_file = .{ .path = "fixup_generated_cimgui.zig" },
        .target = b.host,
    });
    const fix_step = b.addRunArtifact(fix_tool);
    fix_step.step.dependOn(&cimgui_generate_command.step);
    fix_step.addArg(cimgui_dep.path("").getPath(b));

    const write_step = b.addWriteFiles();
    write_step.step.dependOn(&fix_step.step);
    write_step.addCopyFileToSource(
        .{ .cwd_relative = cimgui_dep.path("cimgui.cpp").getPath(b) },
        "../generated/cimgui.cpp"
    );
    write_step.addCopyFileToSource(
        .{ .cwd_relative = cimgui_dep.path("cimgui.h").getPath(b) },
        "../generated/cimgui.h"
    );

    const python_generate_command =
        if (python_path) |path|
            b.addSystemCommand(&.{ path })
        else
            b.addRunArtifact(python_w2c2zig_dep.?.artifact("CPython"));
    python_generate_command.step.dependOn(&write_step.step);
    python_generate_command.setEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "1");

    var temp_path_arena = std.heap.ArenaAllocator.init(b.allocator);
    defer temp_path_arena.deinit();

    python_generate_command.addArg(
        try std.fs.path.relative(
            temp_path_arena.allocator(),
            b.pathFromRoot("."),
            b.pathFromRoot("generate.py"),
        ),
    );
    _ = temp_path_arena.reset(.free_all);

    python_generate_command.setEnvironmentVariable(
        "COMMANDS_JSON_FILE",
        try std.fs.path.relative(
            temp_path_arena.allocator(),
            b.pathFromRoot("."),
            b.pathJoin(&.{
                cimgui_generator_path,
                "output",
                "definitions.json",
            }),
        ),
    );
    _ = temp_path_arena.reset(.free_all);

    python_generate_command.setEnvironmentVariable(
        "IMPL_JSON_FILE",
        try std.fs.path.relative(
            temp_path_arena.allocator(),
            b.pathFromRoot("."),
            b.pathJoin(&.{
                cimgui_generator_path,
                "output",
                "definitions_impl.json",
            }),
        ),
    );
    _ = temp_path_arena.reset(.free_all);

    python_generate_command.setEnvironmentVariable(
        "OUTPUT_PATH",
        try std.fs.path.relative(
            temp_path_arena.allocator(),
            b.pathFromRoot("."),
            b.pathFromRoot("../generated/imgui.zig"),
        ),
    );
    _ = temp_path_arena.reset(.free_all);

    python_generate_command.setEnvironmentVariable(
        "STRUCT_JSON_FILE",
        try std.fs.path.relative(
            temp_path_arena.allocator(),
            b.pathFromRoot("."),
            b.pathJoin(&.{
                cimgui_generator_path,
                "output",
                "structs_and_enums.json",
            }),
        ),
    );
    _ = temp_path_arena.reset(.free_all);

    python_generate_command.setEnvironmentVariable(
        "TEMPLATE_FILE",
        try std.fs.path.relative(
            temp_path_arena.allocator(),
            b.pathFromRoot("."),
            b.pathFromRoot("../template.zig"),
        ),
    );
    _ = temp_path_arena.reset(.free_all);

    python_generate_command.setEnvironmentVariable(
        "TYPEDEFS_JSON_FILE",
        try std.fs.path.relative(
            temp_path_arena.allocator(),
            b.pathFromRoot("."),
            b.pathJoin(&.{
                cimgui_generator_path,
                "output",
                "typedefs_dict.json",
            }),
        ),
    );
    _ = temp_path_arena.reset(.free_all);

    b.getInstallStep().dependOn(&python_generate_command.step);
}
