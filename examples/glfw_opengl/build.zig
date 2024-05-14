const std = @import("std");

const zgl = @import("zgl");
const ZigImGui_build_script = @import("ZigImGui");


fn create_imgui_glfw_static_lib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    glfw_dep: *std.Build.Dependency,
    imgui_dep: *std.Build.Dependency,
    ZigImGui_dep: *std.Build.Dependency,
    lazy_xcode_dep: ?*std.Build.Dependency,
) *std.Build.Step.Compile {
    // compile the desired backend into a separate static library
    const imgui_glfw = b.addStaticLibrary(.{
        .name = "imgui_glfw",
        .target = target,
        .optimize = optimize,
    });
    imgui_glfw.linkLibCpp();
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

    // Linking a compiled artifact auto-includes its headers now, fetch it here
    // so Dear ImGui's GLFW implementation can use it.
    const glfw_lib = glfw_dep.artifact("glfw");

    // For MacOS specifically, ensure we include system headers that zig
    // doesn't by default, which the xcode_frameworks project helpfully
    // provides.
    if (lazy_xcode_dep) |xcode_dep| {
        glfw_lib.addSystemFrameworkPath(xcode_dep.path("Frameworks/"));
        glfw_lib.addSystemIncludePath(xcode_dep.path("include/"));
        glfw_lib.addLibraryPath(xcode_dep.path("lib/"));

        imgui_glfw.addSystemFrameworkPath(xcode_dep.path("Frameworks/"));
        imgui_glfw.addSystemIncludePath(xcode_dep.path("include/"));
        imgui_glfw.addLibraryPath(xcode_dep.path("lib/"));
    }
    imgui_glfw.linkLibrary(glfw_lib);

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

    // This should only replace the first occurrance of this #if near the top
    // of the file where it decides if it should include the GLES headers
    // instead of dynamically linking. We want dynamic linking for portability,
    // but also want Dear ImGui to limit its OpenGL API usage as is appropriate
    // for whatever version we've targeted, hence this substitution.
    const search_text_1 = "#if defined(IMGUI_IMPL_OPENGL_ES2)";
    const start_pos_1 = std.mem.indexOf(u8, list.items, search_text_1)
        orelse return error.InvalidSourceFile;
    try list.replaceRange(start_pos_1, search_text_1.len, "#if false");

    // This also should only replace the first occurrance of this #if near the
    // top  of the file where it decides if it should include the GLES headers
    // instead of dynamically linking. We want dynamic linking for portability,
    // but also want Dear ImGui to limit its OpenGL API usage as is appropriate
    // for whatever version we've targeted, hence this substitution.
    const search_text_2 = "#elif defined(IMGUI_IMPL_OPENGL_ES3)";
    const start_pos_2 = std.mem.indexOf(u8, list.items, search_text_2)
        orelse return error.InvalidSourceFile;
    try list.replaceRange(start_pos_2, search_text_2.len, "#elif false");

    // Normally, this setting disables Dear ImGui's builtin dynamic OpenGL
    // loader completely. For this project, it is preferrable for Dear ImGui to
    // keep using its included loader, but to skip the loader's dlopen of
    // OpenGL. This allows us to delegate the locating and opening of the
    // OpenGL dynamic library to glfw, and then give the `glXGetProcAddress`/
    // `glXGetProcAddressARB` function pointer that glfw located directly to
    // Dear ImGui's loader.
    const search_text_3 = "#elif !defined(IMGUI_IMPL_OPENGL_LOADER_CUSTOM)";
    const start_pos_3 = std.mem.indexOf(u8, list.items, search_text_3)
        orelse return error.InvalidSourceFile;
    try list.replaceRange(start_pos_3, search_text_3.len, "#else");

    return list.toOwnedSlice();
}

fn create_imgui_opengl_static_lib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imgui_dep: *std.Build.Dependency,
    ZigImGui_dep: *std.Build.Dependency,
    selected_opengl_version: zgl.OpenGlVersion,
) !*std.Build.Step.Compile {
    // compile the desired backend into a separate static library
    const imgui_opengl = b.addStaticLibrary(.{
        .name = "imgui_opengl",
        .target = target,
        .optimize = optimize,
    });
    imgui_opengl.linkLibCpp();
    // link in the necessary symbols from ImGui base
    imgui_opengl.linkLibrary(ZigImGui_dep.artifact("cimgui"));

    // use the same override DEFINES that the ImGui base does
    for (ZigImGui_build_script.IMGUI_C_DEFINES) |c_define| {
        imgui_opengl.root_module.addCMacro(c_define[0], c_define[1]);
    }

    // ensure the backend has access to the ImGui headers it expects
    imgui_opengl.addIncludePath(imgui_dep.path("."));
    imgui_opengl.addIncludePath(imgui_dep.path("backends/"));

    imgui_opengl.defineCMacro("IMGUI_IMPL_OPENGL_LOADER_CUSTOM", "1");
    if (selected_opengl_version.es) {
        imgui_opengl.defineCMacro(b.fmt("IMGUI_IMPL_OPENGL_ES{d}", .{ selected_opengl_version.major }), "1");
    }

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
    });
    const glfw_dep = mach_glfw_dep.builder.dependency("glfw", .{ .target = target, .optimize = optimize });
    const lazy_xcode_dep = switch (target.result.os.tag.isDarwin()) {
        true => glfw_dep.builder.lazyDependency("xcode_frameworks", .{ .target = target, .optimize = optimize }),
        else => null,
    };
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

    const imgui_glfw = create_imgui_glfw_static_lib(
        b,
        target,
        optimize,
        glfw_dep,
        imgui_dep,
        ZigImGui_dep,
        lazy_xcode_dep,
    );
    const imgui_opengl = try create_imgui_opengl_static_lib(
        b,
        target,
        optimize,
        imgui_dep,
        ZigImGui_dep,
        selected_opengl_version,
    );

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "mach-glfw", .module = mach_glfw_dep.module("mach-glfw") },
        .{ .name = "zgl", .module = zgl_dep.module("zgl") },
        .{ .name = "Zig-ImGui", .module = ZigImGui_dep.module("Zig-ImGui") },
    };

    const exe = b.addExecutable(.{
        .name = "example_glfw_opengl",
        .root_source_file = b.path("src/main.zig"),
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

    if (lazy_xcode_dep) |xcode_dep| {
        exe.addSystemFrameworkPath(xcode_dep.path("Frameworks/"));
        exe.addSystemIncludePath(xcode_dep.path("include/"));
        exe.addLibraryPath(xcode_dep.path("lib/"));
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
