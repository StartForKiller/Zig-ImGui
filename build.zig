const std = @import("std");


pub fn build(b: *std.Build) void {
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

    const enable_opengl = b.option(bool, "enable_opengl",
        "Enable building ImGui's OpenGL loader backend."
    ) orelse false;

    const freetype_dep: ?*std.Build.Dependency =
        if (enable_freetype)
            b.dependency("freetype", .{ .target = target, .optimize = optimize })
        else
            null;

    const imgui_dep = b.dependency("imgui", .{ .target = target, .optimize = optimize });

    const lunasvg_dep: ?*std.Build.Dependency =
        if (enable_freetype)
            b.dependency("lunasvg", .{ .target = target, .optimize = optimize })
        else
            null;

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

    const imgui_flags: []const []const u8 = &.{
        "-std=c++11",
        "-fvisibility=hidden",
    };

    const imgui_sources: []const std.Build.LazyPath = &.{
        .{ .path = "zig-imgui/cimgui.cpp" },
        imgui_dep.path("imgui.cpp"),
        imgui_dep.path("imgui_demo.cpp"),
        imgui_dep.path("imgui_draw.cpp"),
        imgui_dep.path("imgui_tables.cpp"),
        imgui_dep.path("imgui_widgets.cpp"),
    };

    cimgui.root_module.addCMacro("IMGUI_DISABLE_OBSOLETE_FUNCTIONS", "1");
    cimgui.root_module.addCMacro("IMGUI_DISABLE_OBSOLETE_KEYIO", "1");
    cimgui.root_module.addCMacro("IMGUI_IMPL_API", "extern \"C\"");
    cimgui.root_module.addCMacro("IMGUI_USE_WCHAR32", "1");
    cimgui.root_module.addCMacro("ImTextureID", "unsigned long long");
    cimgui.addIncludePath(.{ .path = "zig-imgui/" });
    cimgui.addIncludePath(imgui_dep.path("."));
    for (imgui_sources) |file| {
        cimgui.addCSourceFile(.{
            .file = file,
            .flags = imgui_flags,
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

        // freetype_flags.append("-fno-sanitize-trap=undefined") catch @panic("oom");
        // freetype_flags.append("-fno-sanitize-recover=undefined") catch @panic("oom");
        // cimgui.addLibraryPath(.{ .path = "/usr/lib/" });
        // cimgui.linkSystemLibrary("ubsan");

        cimgui.addIncludePath(imgui_dep.path("misc/freetype"));
        cimgui.addCSourceFile(.{
            .file = .{ .path = "zig-imgui/imgui_freetype.cpp" },
            .flags = imgui_flags,
        });
    }

    const zig_imgui = b.addModule("Zig-ImGui", .{
        .root_source_file = .{ .path = "zig-imgui/imgui.zig" },
        .target = target,
        .optimize = optimize,
    });
    zig_imgui.linkLibrary(cimgui);

    if (enable_opengl) {
        const imgui_opengl = b.addStaticLibrary(.{
            .name = "imgui_opengl",
            .target = target,
            .optimize = optimize,
        });
        imgui_opengl.root_module.link_libcpp = true;
        imgui_opengl.linkLibrary(cimgui);
        imgui_opengl.root_module.addCMacro("IMGUI_DISABLE_OBSOLETE_FUNCTIONS", "1");
        imgui_opengl.root_module.addCMacro("IMGUI_DISABLE_OBSOLETE_KEYIO", "1");
        imgui_opengl.root_module.addCMacro("IMGUI_IMPL_API", "extern \"C\"");
        imgui_opengl.root_module.addCMacro("IMGUI_USE_WCHAR32", "1");
        imgui_opengl.root_module.addCMacro("ImTextureID", "unsigned long long");
        imgui_opengl.addIncludePath(imgui_dep.path("."));
        imgui_opengl.addIncludePath(imgui_dep.path("backends/"));
        imgui_opengl.addCSourceFile(.{
            .file = imgui_dep.path("backends/imgui_impl_opengl3.cpp"),
            .flags = imgui_flags,
        });

        zig_imgui.linkLibrary(imgui_opengl);
    }

    const test_exe = b.addTest(.{
        .root_source_file = .{ .path = "zig-imgui/tests.zig" },
        .target = target,
        .optimize = optimize,
    });
    test_exe.root_module.addImport("Zig-ImGui", zig_imgui);

    const test_step = b.step("test", "Run zig-imgui tests");
    test_step.dependOn(&test_exe.step);
}
