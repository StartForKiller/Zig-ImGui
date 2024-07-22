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
    const lua_path: ?[]const u8 = b.findProgram(&.{ "luajit", "lua5.1" }, &.{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };

    // hopefully, this can be replaced by a rewrite in zig in the future, until
    // then, python is necessary to generate the bindings
    const python_path = blk: {
        const path = b.findProgram(&.{ "python", "python3" }, &.{}) catch |err| switch (err) {
            error.FileNotFound => return error.Python3NotFound,
            else => return err,
        };

        const result = try std.process.Child.run(.{
            .allocator = b.allocator,
            .argv = &.{
                path,
                "--version",
            },
            .max_output_bytes = 4096,
        });

        switch (result.term) {
            .Exited => |e| if (e != 0) return error.PythonUnexpectedError,
            else => unreachable,
        }
        break :blk path;
    };

    const lua51_dep: ?*std.Build.Dependency = blk: {
        if (lua_path == null) {
            break :blk b.lazyDependency("lua51", .{
                .target = b.host,
                .optimize = .ReleaseFast,
            });
        }

        break :blk null;
    };

    const cimgui_generate_command =
        if (lua_path) |path|
        b.addSystemCommand(&.{path})
    else if (lua51_dep) |dep|
        b.addRunArtifact(dep.artifact("lua5.1"))
    else
        b.addSystemCommand(&.{"luajit"});

    cimgui_generate_command.setCwd(cimgui_dep.path("generator/"));
    cimgui_generate_command.addFileArg(cimgui_dep.path("generator/generator.lua"));
    cimgui_generate_command.addArgs(&.{
        b.fmt("{s} cc", .{b.graph.zig_exe}),
        "freetype",
        "-DIMGUI_ENABLE_STB_TRUETYPE -DIMGUI_USE_WCHAR32",
    });

    {
        const imgui_path = try std.fs.path.relative(
            b.allocator,
            cimgui_dep.path("generator/").getPath(b),
            imgui_dep.path("/").getPath(b),
        );
        defer b.allocator.free(imgui_path);

        cimgui_generate_command.setEnvironmentVariable("IMGUI_PATH", imgui_path);
    }

    const fix_tool = b.addExecutable(.{
        .name = "fix_cimgui_sources",
        .root_source_file = b.path("src/fixup_generated_cimgui.zig"),
        .target = b.host,
    });
    const fix_step = b.addRunArtifact(fix_tool);
    fix_step.step.dependOn(&cimgui_generate_command.step);
    fix_step.addFileArg(cimgui_dep.path("/"));

    const write_step = b.addUpdateSourceFiles();
    write_step.step.dependOn(&fix_step.step);
    write_step.addCopyFileToSource(cimgui_dep.path("cimgui.cpp"), "../src/generated/cimgui.cpp");
    write_step.addCopyFileToSource(cimgui_dep.path("cimgui.h"), "../src/generated/cimgui.h");

    const python_generate_command = b.addSystemCommand(&.{python_path});
    python_generate_command.step.dependOn(&write_step.step);
    python_generate_command.setEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "1");
    python_generate_command.addFileArg(b.path("generate.py"));

    {
        const cmds_json_relpath = try std.fs.path.relative(
            b.allocator,
            b.build_root.path orelse return error.InvalidBuildRoot,
            cimgui_dep.path("generator/output/definitions.json").getPath(b),
        );
        defer b.allocator.free(cmds_json_relpath);

        python_generate_command.setEnvironmentVariable(
            "COMMANDS_JSON_FILE",
            cmds_json_relpath,
        );
    }

    {
        const impl_json_relpath = try std.fs.path.relative(
            b.allocator,
            b.build_root.path orelse return error.InvalidBuildRoot,
            cimgui_dep.path("generator/output/definitions_impl.json").getPath(b),
        );
        defer b.allocator.free(impl_json_relpath);

        python_generate_command.setEnvironmentVariable(
            "IMPL_JSON_FILE",
            impl_json_relpath,
        );
    }

    {
        const output_relpath = try std.fs.path.relative(
            b.allocator,
            b.build_root.path orelse return error.InvalidBuildRoot,
            b.pathFromRoot("../src/generated/imgui.zig"),
        );
        defer b.allocator.free(output_relpath);

        python_generate_command.setEnvironmentVariable(
            "OUTPUT_PATH",
            output_relpath,
        );
    }

    {
        const struct_json_relpath = try std.fs.path.relative(
            b.allocator,
            b.build_root.path orelse return error.InvalidBuildRoot,
            cimgui_dep.path("generator/output/structs_and_enums.json").getPath(b),
        );
        defer b.allocator.free(struct_json_relpath);

        python_generate_command.setEnvironmentVariable(
            "STRUCT_JSON_FILE",
            struct_json_relpath,
        );
    }

    {
        const template_file_relpath = try std.fs.path.relative(
            b.allocator,
            b.build_root.path orelse return error.InvalidBuildRoot,
            b.path("src/template.zig").getPath(b),
        );
        defer b.allocator.free(template_file_relpath);

        python_generate_command.setEnvironmentVariable(
            "TEMPLATE_FILE",
            template_file_relpath,
        );
    }

    {
        const typedef_json_relpath = try std.fs.path.relative(
            b.allocator,
            b.build_root.path orelse return error.InvalidBuildRoot,
            cimgui_dep.path("generator/output/typedefs_dict.json").getPath(b),
        );
        defer b.allocator.free(typedef_json_relpath);

        python_generate_command.setEnvironmentVariable(
            "TYPEDEFS_JSON_FILE",
            typedef_json_relpath,
        );
    }

    b.getInstallStep().dependOn(&python_generate_command.step);
}
