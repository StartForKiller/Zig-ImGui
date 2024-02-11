const std = @import("std");


pub const IMGUI_C_DEFINES: []const [2][]const u8 = &.{
    .{ "IMGUI_DISABLE_OBSOLETE_FUNCTIONS", "1" },
    .{ "IMGUI_DISABLE_OBSOLETE_KEYIO", "1" },
    .{ "IMGUI_IMPL_API", "extern \"C\"" },
    .{ "IMGUI_USE_WCHAR32", "1" },
    .{ "ImTextureID", "ImU64" },
};

pub const IMGUI_C_FLAGS: []const []const u8 = &.{
    "-std=c++11",
    "-fvisibility=hidden",
};

fn create_generation_step(
    b: *std.Build,
    cimgui_dep: *std.Build.Dependency,
    imgui_dep: *std.Build.Dependency,
    lua51_dep: *std.Build.Dependency,
    python_w2c2zig_dep: *std.Build.Dependency,
) !*std.Build.Step {
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

    const cimgui_generator_lazypath = cimgui_dep.path("generator/");
    const cimgui_generator_path = cimgui_generator_lazypath.getPath(b);

    const cimgui_generate_command =
        if (lua_path) |path|
            b.addSystemCommand(&.{ path })
        else
            b.addRunArtifact(lua51_dep.artifact("lua5.1"));
    cimgui_generate_command.addArgs(&.{
        b.pathJoin(&.{ cimgui_generator_path, "generator.lua" }),
        b.fmt("{s} cc", .{ b.zig_exe }),
        "freetype",
        "-DIMGUI_ENABLE_STB_TRUETYPE -DIMGUI_USE_WCHAR32",
    });
    cimgui_generate_command.setCwd(cimgui_generator_lazypath);
    cimgui_generate_command.setEnvironmentVariable("IMGUI_PATH", imgui_dep.path("").getPath(b));

    const fix_tool = b.addExecutable(.{
        .name = "fix_cimgui_sources",
        .root_source_file = .{ .path = "src/generator/fixup_generated_cimgui.zig" },
        .target = b.host,
    });
    const fix_step = b.addRunArtifact(fix_tool);
    fix_step.step.dependOn(&cimgui_generate_command.step);
    fix_step.addArg(cimgui_dep.path("").getPath(b));

    const write_step = b.addWriteFiles();
    write_step.step.dependOn(&fix_step.step);
    write_step.addCopyFileToSource(
        .{ .cwd_relative = cimgui_dep.path("cimgui.cpp").getPath(b) },
        "src/generated/cimgui.cpp"
    );
    write_step.addCopyFileToSource(
        .{ .cwd_relative = cimgui_dep.path("cimgui.h").getPath(b) },
        "src/generated/cimgui.h"
    );

    const python_generate_command =
        if (python_path) |path|
            b.addSystemCommand(&.{ path })
        else
            b.addRunArtifact(python_w2c2zig_dep.artifact("CPython"));
    python_generate_command.step.dependOn(&write_step.step);
    python_generate_command.addArg(b.pathFromRoot("src/generator/generate.py"));
    python_generate_command.setEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "1");
    python_generate_command.setEnvironmentVariable("COMMANDS_JSON_FILE", b.pathJoin(&.{
        cimgui_generator_path,
        "output",
        "definitions.json",
    }));
    python_generate_command.setEnvironmentVariable("IMPL_JSON_FILE", b.pathJoin(&.{
        cimgui_generator_path,
        "output",
        "definitions_impl.json",
    }));
    python_generate_command.setEnvironmentVariable("STRUCT_JSON_FILE", b.pathJoin(&.{
        cimgui_generator_path,
        "output",
        "structs_and_enums.json",
    }));
    python_generate_command.setEnvironmentVariable("TYPEDEFS_JSON_FILE", b.pathJoin(&.{
        cimgui_generator_path,
        "output",
        "typedefs_dict.json",
    }));
    python_generate_command.setEnvironmentVariable("OUTPUT_PATH", b.pathFromRoot("src/generated/imgui.zig"));
    python_generate_command.setEnvironmentVariable("TEMPLATE_FILE", b.pathFromRoot("src/template.zig"));

    return &python_generate_command.step;
}

pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const enable_freetype = b.option(bool, "enable_freetype",
        "Enable building freetype as ImGui's font renderer."
    ) orelse false;

    const enable_lunasvg = b.option(bool, "enable_lunasvg",
        "Enable building lunasvg to provide better emoji support in freetype. Requires freetype to be enabled."
    ) orelse false;

    const cimgui_dep = b.dependency("cimgui", .{ .target = target, .optimize = optimize });
    const freetype_dep: ?*std.Build.Dependency =
        if (enable_freetype)
            b.dependency("freetype", .{ .target = target, .optimize = optimize })
        else
            null;
    const imgui_dep = b.dependency("imgui", .{ .target = target, .optimize = optimize });
    const lua51_dep = b.dependency("lua51", .{ .target = b.host, .optimize = .ReleaseFast });
    const lunasvg_dep: ?*std.Build.Dependency =
        if (enable_freetype)
            b.dependency("lunasvg", .{ .target = target, .optimize = optimize })
        else
            null;
    const python_w2c2zig_dep = b.dependency("python_w2c2zig", .{ .target = b.host, .optimize = .ReleaseFast });

    const gen_step = try create_generation_step(b, cimgui_dep, imgui_dep, lua51_dep, python_w2c2zig_dep);
    const cli_generate_step = b.step(
        "generate",
        "Generate cimgui and zig bindings for Dear ImGui.",
    );
    cli_generate_step.dependOn(gen_step);

    const cimgui = b.addStaticLibrary(.{
        .name = "cimgui",
        .target = target,
        .optimize = optimize,
    });
    cimgui.root_module.link_libcpp = true;

    if (enable_freetype) {
        cimgui.root_module.addCMacro("IMGUI_ENABLE_FREETYPE", "1");
        cimgui.root_module.addCMacro("CIMGUI_FREETYPE", "1");
        cimgui.linkLibrary(freetype_dep.?.artifact("freetype"));
    }

    const imgui_sources: []const std.Build.LazyPath = &.{
        .{ .path = "src/generated/cimgui.cpp" },
        imgui_dep.path("imgui.cpp"),
        imgui_dep.path("imgui_demo.cpp"),
        imgui_dep.path("imgui_draw.cpp"),
        imgui_dep.path("imgui_tables.cpp"),
        imgui_dep.path("imgui_widgets.cpp"),
    };

    for (IMGUI_C_DEFINES) |c_define| {
        cimgui.root_module.addCMacro(c_define[0], c_define[1]);
    }
    cimgui.addIncludePath(.{ .path = "src/generated/" });
    cimgui.addIncludePath(imgui_dep.path("."));
    for (imgui_sources) |file| {
        cimgui.addCSourceFile(.{
            .file = file,
            .flags = IMGUI_C_FLAGS,
        });
    }

    if (enable_freetype) {
        if (enable_lunasvg) {
            cimgui.root_module.addCMacro("IMGUI_ENABLE_FREETYPE_LUNASVG", "1");

            const plutovg_sources: []const std.Build.LazyPath = &.{
                lunasvg_dep.?.path("3rdparty/plutovg/plutovg.c"),
                lunasvg_dep.?.path("3rdparty/plutovg/plutovg-paint.c"),
                lunasvg_dep.?.path("3rdparty/plutovg/plutovg-geometry.c"),
                lunasvg_dep.?.path("3rdparty/plutovg/plutovg-blend.c"),
                lunasvg_dep.?.path("3rdparty/plutovg/plutovg-rle.c"),
                lunasvg_dep.?.path("3rdparty/plutovg/plutovg-dash.c"),
                lunasvg_dep.?.path("3rdparty/plutovg/plutovg-ft-raster.c"),
                lunasvg_dep.?.path("3rdparty/plutovg/plutovg-ft-stroker.c"),
                lunasvg_dep.?.path("3rdparty/plutovg/plutovg-ft-math.c"),
            };
            cimgui.addIncludePath(lunasvg_dep.?.path("3rdparty/plutovg/"));
            for (plutovg_sources) |file| {
                cimgui.addCSourceFile(.{
                    .file = file,
                    .flags = &.{
                        "-std=gnu11",
                        "-fvisibility=hidden",
                    },
                });
            }

            const lunasvg_sources: []const std.Build.LazyPath = &.{
                lunasvg_dep.?.path("source/lunasvg.cpp"),
                lunasvg_dep.?.path("source/element.cpp"),
                lunasvg_dep.?.path("source/property.cpp"),
                lunasvg_dep.?.path("source/parser.cpp"),
                lunasvg_dep.?.path("source/layoutcontext.cpp"),
                lunasvg_dep.?.path("source/canvas.cpp"),
                lunasvg_dep.?.path("source/clippathelement.cpp"),
                lunasvg_dep.?.path("source/defselement.cpp"),
                lunasvg_dep.?.path("source/gelement.cpp"),
                lunasvg_dep.?.path("source/geometryelement.cpp"),
                lunasvg_dep.?.path("source/graphicselement.cpp"),
                lunasvg_dep.?.path("source/maskelement.cpp"),
                lunasvg_dep.?.path("source/markerelement.cpp"),
                lunasvg_dep.?.path("source/paintelement.cpp"),
                lunasvg_dep.?.path("source/stopelement.cpp"),
                lunasvg_dep.?.path("source/styledelement.cpp"),
                lunasvg_dep.?.path("source/styleelement.cpp"),
                lunasvg_dep.?.path("source/svgelement.cpp"),
                lunasvg_dep.?.path("source/symbolelement.cpp"),
                lunasvg_dep.?.path("source/useelement.cpp"),
            };
            cimgui.addIncludePath(lunasvg_dep.?.path("include/"));
            for (lunasvg_sources) |file| {
                cimgui.addCSourceFile(.{
                    .file = file,
                    .flags = &.{
                        "-std=gnu++11",
                        "-fvisibility=hidden",
                    },
                });
            }
        }

        cimgui.addIncludePath(imgui_dep.path("misc/freetype"));
        cimgui.addCSourceFile(.{
            .file = .{ .path = "src/generated/imgui_freetype.cpp" },
            .flags = IMGUI_C_FLAGS,
        });
    }
    b.installArtifact(cimgui);

    const zig_imgui = b.addModule("Zig-ImGui", .{
        .root_source_file = .{ .path = "src/generated/imgui.zig" },
        .target = target,
        .optimize = optimize,
    });
    zig_imgui.linkLibrary(cimgui);

    const test_exe = b.addTest(.{
        .root_source_file = .{ .path = "src/tests.zig" },
        .target = target,
        .optimize = optimize,
    });
    test_exe.root_module.addImport("Zig-ImGui", zig_imgui);

    const test_step = b.step("test", "Run zig-imgui tests");
    test_step.dependOn(&test_exe.step);
}
