const std = @import("std");

const mach_glfw = @import("mach_glfw");
const zgl = @import("zgl");
const ZigImGui_build_script = @import("ZigImGui");


fn create_imgui_glfw_static_lib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    glfw_dep: *std.Build.Dependency,
    imgui_dep: *std.Build.Dependency,
    ZigImGui_dep: *std.Build.Dependency,
) *std.Build.Step.Compile {
    // compile the desired backend into a separate static library
    const imgui_glfw = b.addStaticLibrary(.{
        .name = "imgui_glfw",
        .target = target,
        .optimize = optimize,
    });
    imgui_glfw.root_module.link_libcpp = true;
    // link in the necessary symbols from ImGui base
    imgui_glfw.linkLibrary(ZigImGui_dep.artifact("cimgui"));

    // use the same override DEFINES that the ImGui base does
    for (ZigImGui_build_script.IMGUI_C_DEFINES) |c_define| {
        imgui_glfw.root_module.addCMacro(c_define[0], c_define[1]);
    }

    // ensure only a basic version of glfw is given to `imgui_impl_glfw.cpp` to
    // ensure it can be loaded with no extra headers.
    imgui_glfw.root_module.addCMacro("GLFW_INCLUDE_NONE", "1");

    // ensure the backend has access to the ImGui headers it expects
    imgui_glfw.addIncludePath(imgui_dep.path("."));
    imgui_glfw.addIncludePath(imgui_dep.path("backends/"));

    // this backend needs glfw and opengl headers as well
    imgui_glfw.addIncludePath(glfw_dep.path("include/"));
    mach_glfw.addPaths(imgui_glfw, glfw_dep.builder);

    imgui_glfw.addCSourceFile(.{
        .file = imgui_dep.path("backends/imgui_impl_glfw.cpp"),
        // use the same compile flags that the ImGui base does
        .flags = ZigImGui_build_script.IMGUI_C_FLAGS,
    });

    return imgui_glfw;
}

/// touches up `imgui_impl_opengl3.cpp` to remove its needless incompatiblity
/// with simultaneous dynamic loading of opengl and OpenGL ES 2.0 support
fn generate_modified_imgui_source(b: *std.Build, path: []const u8) ![]const u8 {

    var list = blk: {
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();

        var list = std.ArrayList(u8).init(b.allocator);
        try file.reader().readAllArrayList(&list, std.math.maxInt(usize));
        break :blk list;
    };
    defer list.deinit();

    const search_text = "#elif !defined(IMGUI_IMPL_OPENGL_LOADER_CUSTOM)";
    const start_pos = std.mem.indexOf(u8, list.items, search_text)
        orelse return error.InvalidSourceFile;
    try list.replaceRange(start_pos, search_text.len, "#else");

    return list.toOwnedSlice();
}

fn create_imgui_opengl_static_lib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imgui_dep: *std.Build.Dependency,
    ZigImGui_dep: *std.Build.Dependency,
) !*std.Build.Step.Compile {
    // compile the desired backend into a separate static library
    const imgui_opengl = b.addStaticLibrary(.{
        .name = "imgui_opengl",
        .target = target,
        .optimize = optimize,
    });
    imgui_opengl.root_module.link_libcpp = true;
    // link in the necessary symbols from ImGui base
    imgui_opengl.linkLibrary(ZigImGui_dep.artifact("cimgui"));

    // use the same override DEFINES that the ImGui base does
    for (ZigImGui_build_script.IMGUI_C_DEFINES) |c_define| {
        imgui_opengl.root_module.addCMacro(c_define[0], c_define[1]);
    }
    imgui_opengl.root_module.addCMacro("IMGUI_IMPL_OPENGL_LOADER_CUSTOM", "1");

    // ensure the backend has access to the ImGui headers it expects
    imgui_opengl.addIncludePath(imgui_dep.path("."));
    imgui_opengl.addIncludePath(imgui_dep.path("backends/"));

    imgui_opengl.addCSourceFile(.{
        .file = b.addWriteFiles().add("imgui_impl_opengl3.cpp",
            try generate_modified_imgui_source(
                b,
                imgui_dep.path("backends/imgui_impl_opengl3.cpp").getPath(imgui_dep.builder),
            ),
        ),
        // use the same compile flags that the ImGui base does
        .flags = ZigImGui_build_script.IMGUI_C_FLAGS,
    });

    return imgui_opengl;
}

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
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

    const force_opengl_version = b.option(
        []const u8,
        "force_opengl_version",
        "Force a particular OpenGL target version. Versions between " ++
        "'ES_VERSION_2_0'-'ES_VERSION_3_2' and 'VERSION_3_2'-'VERSION_4_6' " ++
        "are expected to work on at least 1 platform, others versions are " ++
        "unsupported, but still accepted by this argument for completeness.",
    );

    const selected_opengl_version =
        if (force_opengl_version) |forced|
            zgl.OpenGlVersionLookupTable.get(forced)
                orelse return error.UnsupportedOpenGlVersion
        else if (target.result.isDarwin() or target.result.os.tag == .windows)
            zgl.OpenGlVersionLookupTable.get("VERSION_3_2")
                orelse unreachable
        else
            zgl.OpenGlVersionLookupTable.get("ES_VERSION_2_0")
                orelse unreachable;

    const mach_glfw_dep = b.dependency("mach_glfw", .{
        .target = target,
        .optimize = optimize,
        .enable_version_check = false,
    });
    const glfw_dep = mach_glfw_dep.builder.dependency("glfw", .{ .target = target, .optimize = optimize });
    const zgl_dep = b.dependency("zgl", .{
        .target = target,
        .optimize = optimize,
        .binding_version = @as([]const u8, b.fmt("{s}VERSION_{d}_{d}", .{
            if (selected_opengl_version.es)
                "ES_"
            else
                "",
            selected_opengl_version.major,
            selected_opengl_version.minor,
        })),
    });
    const ZigImGui_dep = b.dependency("ZigImGui", .{
        .target = target,
        .optimize = optimize,
        .enable_freetype = true,
        .enable_lunasvg = true,
    });
    const imgui_dep = ZigImGui_dep.builder.dependency("imgui", .{ .target = target, .optimize = optimize });

    const imgui_glfw = create_imgui_glfw_static_lib(b, target, optimize, glfw_dep, imgui_dep, ZigImGui_dep);
    const imgui_opengl = try create_imgui_opengl_static_lib(b, target, optimize, imgui_dep, ZigImGui_dep);

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "mach-glfw", .module = mach_glfw_dep.module("mach-glfw") },
        .{ .name = "zgl", .module = zgl_dep.module("zgl") },
        .{ .name = "Zig-ImGui", .module = ZigImGui_dep.module("Zig-ImGui") },
    };

    const exe = b.addExecutable(.{
        .name = "example_glfw_opengl",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    for (imports) |import| {
        exe.root_module.addImport(import.name, import.module);
    }

    {
        const opts = b.addOptions();
        opts.addOption(u32, "OPENGL_MAJOR_VERSION", selected_opengl_version.major);
        opts.addOption(u32, "OPENGL_MINOR_VERSION", selected_opengl_version.minor);
        opts.addOption(bool, "OPENGL_ES_PROFILE", selected_opengl_version.es);
        exe.root_module.addImport("build_options", opts.createModule());
    }

    exe.linkLibrary(imgui_glfw);
    exe.linkLibrary(imgui_opengl);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
