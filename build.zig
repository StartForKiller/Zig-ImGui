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

    const freetype_dep: ?*std.Build.Dependency =
        if (enable_freetype)
            b.lazyDependency("freetype", .{ .target = target, .optimize = optimize })
        else
            null;
    const generator_dep = b.dependency("generator", .{});
    const imgui_dep = b.dependency("imgui", .{});
    const lunasvg_dep: ?*std.Build.Dependency =
        if (enable_freetype)
            b.lazyDependency("lunasvg", .{})
        else
            null;

    const cli_generate_step = b.step(
        "generate",
        "Generate cimgui and zig bindings for Dear ImGui.",
    );
    cli_generate_step.dependOn(generator_dep.builder.getInstallStep());

    const cimgui = b.addStaticLibrary(.{
        .name = "cimgui",
        .target = target,
        .optimize = optimize,
    });
    cimgui.root_module.link_libcpp = true;

    if (enable_freetype) {
        cimgui.root_module.addCMacro("IMGUI_ENABLE_FREETYPE", "1");
        cimgui.root_module.addCMacro("CIMGUI_FREETYPE", "1");
        if (freetype_dep) |dep| {
            cimgui.linkLibrary(dep.artifact("freetype"));
        }
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
            if (lunasvg_dep) |dep| {
                cimgui.root_module.addCMacro("IMGUI_ENABLE_FREETYPE_LUNASVG", "1");

                cimgui.addIncludePath(dep.path("3rdparty/plutovg/"));
                cimgui.addCSourceFiles(.{
                    .dependency = dep,
                    .files = &.{
                        "3rdparty/plutovg/plutovg.c",
                        "3rdparty/plutovg/plutovg-paint.c",
                        "3rdparty/plutovg/plutovg-geometry.c",
                        "3rdparty/plutovg/plutovg-blend.c",
                        "3rdparty/plutovg/plutovg-rle.c",
                        "3rdparty/plutovg/plutovg-dash.c",
                        "3rdparty/plutovg/plutovg-ft-raster.c",
                        "3rdparty/plutovg/plutovg-ft-stroker.c",
                        "3rdparty/plutovg/plutovg-ft-math.c",
                    },
                    .flags = &.{
                        "-std=gnu11",
                        "-fvisibility=hidden",
                    },
                });

                cimgui.addIncludePath(dep.path("include/"));
                cimgui.addCSourceFiles(.{
                    .dependency = dep,
                    .files = &.{
                        "source/lunasvg.cpp",
                        "source/element.cpp",
                        "source/property.cpp",
                        "source/parser.cpp",
                        "source/layoutcontext.cpp",
                        "source/canvas.cpp",
                        "source/clippathelement.cpp",
                        "source/defselement.cpp",
                        "source/gelement.cpp",
                        "source/geometryelement.cpp",
                        "source/graphicselement.cpp",
                        "source/maskelement.cpp",
                        "source/markerelement.cpp",
                        "source/paintelement.cpp",
                        "source/stopelement.cpp",
                        "source/styledelement.cpp",
                        "source/styleelement.cpp",
                        "source/svgelement.cpp",
                        "source/symbolelement.cpp",
                        "source/useelement.cpp",
                    },
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
