const std = @import("std");

const mach_glfw = @import("mach_glfw");
const ZigImGui_build_script = @import("ZigImGui");


const ShaderCompiler = struct {
    compiler_kind: enum { glslang, glslc },
    run_step: *std.Build.Step.Run,
};

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

fn create_imgui_vulkan_static_lib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imgui_dep: *std.Build.Dependency,
    vulkan_headers_dep: *std.Build.Dependency,
    ZigImGui_dep: *std.Build.Dependency,
) *std.Build.Step.Compile {
    // compile the desired backend into a separate static library
    const imgui_vulkan = b.addStaticLibrary(.{
        .name = "imgui_vulkan",
        .target = target,
        .optimize = optimize,
    });
    imgui_vulkan.root_module.link_libcpp = true;
    // link in the necessary symbols from ImGui base
    imgui_vulkan.linkLibrary(ZigImGui_dep.artifact("cimgui"));

    // use the same override DEFINES that the ImGui base does
    for (ZigImGui_build_script.IMGUI_C_DEFINES) |c_define| {
        imgui_vulkan.root_module.addCMacro(c_define[0], c_define[1]);
    }

    // add some extra defines so ImGui builds without vulkan in such a way it
    // can be dynamically loaded at runtime without dynamic linking
    imgui_vulkan.root_module.addCMacro("IMGUI_IMPL_VULKAN_NO_PROTOTYPES", "1");
    imgui_vulkan.root_module.addCMacro("VK_NO_PROTOTYPES", "1");

    // ensure the backend has access to the ImGui headers it expects
    imgui_vulkan.addIncludePath(imgui_dep.path("."));
    imgui_vulkan.addIncludePath(imgui_dep.path("backends/"));

    // Also add vulkan headers needed by `imgui_impl_vulkan.cpp`
    imgui_vulkan.addIncludePath(vulkan_headers_dep.path("include/"));

    imgui_vulkan.addCSourceFile(.{
        .file = imgui_dep.path("backends/imgui_impl_vulkan.cpp"),
        // use the same compile flags that the ImGui base does
        .flags = ZigImGui_build_script.IMGUI_C_FLAGS,
    });

    return imgui_vulkan;
}

/// This function makes it easy to prefer using an install of glslang or glslc
/// already installed on the system if it is available.
///
/// Note, that the run step returned has no arguments set, and they will need
/// to be given to the step afterwards. Set `use_fallback` to false to prevent
/// compiling glslangValidator from source if it not found in $PATH.
fn get_shader_compiler(b: *std.Build, use_fallback: bool) !ShaderCompiler {
    const maybe_glslang_path = b.findProgram(&.{ "glslang", "glslangValidator" }, &.{})
        catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
    if (maybe_glslang_path) |glslang_path| {
        return .{
            .compiler_kind = .glslang,
            .run_step = b.addSystemCommand(&.{ glslang_path }),
        };
    }

    const maybe_glslc_path = b.findProgram(&.{ "glslc" }, &.{})
        catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
    if (maybe_glslc_path) |glslc_path| {
        return .{
            .compiler_kind = .glslc,
            .run_step = b.addSystemCommand(&.{ glslc_path }),
        };
    }

    if (use_fallback) {
        const glslang_dep = b.lazyDependency("glslang", .{
            .target = b.host,
            .optimize = .ReleaseFast,
        });

        if (glslang_dep) |dep| {
            return .{
                .compiler_kind = .glslang,
                .run_step = b.addRunArtifact(dep.artifact("glslangValidator")),
            };
        }

        // prevent erroring before lazy_dep is ready
        return .{
            .compiler_kind = .glslang,
            .run_step = b.addSystemCommand(&.{ "glslang" }),
        };
    }

    return error.NoShaderCompilerFound;
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

    const cpu_rendering_fallback = b.option(
        bool,
        "cpu_rendering_fallback",
        "When enabled, a CPU Vulkan renderer (swiftshader) will be " ++
        "statically included in the binary to use if a suitable vulkan " ++
        "driver cannot be found at runtime. Can bloat the binary size " ++
        "significantly. On MacOS, this replaces the vulkan driver " ++
        "completely, and is disabled by default. For other platforms, " ++
        "Default=true for debug builds, false for release builds",
    )
        orelse (!target.result.os.tag.isDarwin() and optimize == .Debug);

    const use_system_vk_xml = b.option(
        bool,
        "use_system_vk_xml",
        "Use /usr/share/vulkan/registry/vk.xml to generate Vulkan bindings " ++
        "instead of downloading the latest bindings from the Vulkan SDK. " ++
        "Default=false"
    )
        orelse false;

    const mach_glfw_dep = b.dependency("mach_glfw", .{
        .target = target,
        .optimize = optimize,
        .enable_version_check = false,
    });
    const glfw_dep = mach_glfw_dep.builder.dependency("glfw", .{ .target = target, .optimize = optimize });
    const vulkan_docs_dep = b.dependency("vulkan_docs", .{});
    const vulkan_headers_dep = glfw_dep.builder.dependency("vulkan_headers", .{});
    const vulkan_zig_dep = b.dependency("vulkan_zig", .{
        .target = b.host,
        .optimize = .Debug,
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
    );
    const imgui_vulkan = create_imgui_vulkan_static_lib(
        b,
        target,
        optimize,
        imgui_dep,
        vulkan_headers_dep,
        ZigImGui_dep,
    );

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "mach-glfw", .module = mach_glfw_dep.module("mach-glfw") },
        .{
            .name = "vk",
            .module = blk: {
                const SYSTEM_VULKAN_PATH = "/usr/share/vulkan/registry/vk.xml";

                const found_system_vk_xml = blk2: {
                    std.fs.accessAbsolute(SYSTEM_VULKAN_PATH, .{})
                        catch break :blk2 false;
                    break :blk2 true;
                };

                const gen_cmd = b.addRunArtifact(vulkan_zig_dep.artifact("generator"));
                gen_cmd.addFileArg(
                    if (use_system_vk_xml and found_system_vk_xml)
                        .{ .path = SYSTEM_VULKAN_PATH }
                    else
                        vulkan_docs_dep.path("xml/vk.xml")
                );

                break :blk b.addModule("vk", .{ .root_source_file = gen_cmd.addOutputFileArg("vk.zig") });
            },
        },
        .{ .name = "Zig-ImGui", .module = ZigImGui_dep.module("Zig-ImGui") },
    };

    const exe = b.addExecutable(.{
        .name = "example_glfw_vulkan",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    for (imports) |import| {
        exe.root_module.addImport(import.name, import.module);
    }
    exe.linkLibrary(imgui_glfw);
    exe.linkLibrary(imgui_vulkan);

    if (cpu_rendering_fallback) {
        switch (target.result.os.tag) {
            .ios, .macos, .watchos, .tvos => switch (target.result.cpu.arch) {
                .aarch64 => if (b.lazyDependency(
                    "swiftshader",
                    .{
                        .target = target,
                        .optimize = .ReleaseSmall,
                        .jit_mode = switch (optimize) {
                            .Debug => @as([]const u8, "LLVMv10"),
                            else => @as([]const u8, "LLVMv16"),
                        },
                    },
                )) |swiftshader_dep| {
                    exe.linkLibrary(swiftshader_dep.artifact("vk_swiftshader_static"));
                },
                .x86_64 => if (b.lazyDependency(
                    "swiftshader",
                    .{
                        .target = target,
                        .optimize = .ReleaseSmall,
                        .jit_mode = switch (optimize) {
                            .Debug => @as([]const u8, "Subzero"),
                            else => @as([]const u8, "LLVMv16"),
                        },
                    },
                )) |swiftshader_dep| {
                    exe.linkLibrary(swiftshader_dep.artifact("vk_swiftshader_static"));
                },
                else => return error.UnsupportedCPUArchitecture,
            },
            .linux => if (b.lazyDependency(
                "swiftshader",
                .{
                    .target = target,
                    .optimize = .ReleaseSmall,
                    .jit_mode = switch (optimize) {
                        .Debug => switch (target.result.cpu.arch) {
                            .arm, .mipsel, .x86, .x86_64 => @as([]const u8, "Subzero"),
                            .riscv64 => @as([]const u8, "LLVMv16"),
                            else => @as([]const u8, "LLVMv10"),
                        },
                        else => switch (target.result.cpu.arch) {
                            .arm, .x86 => @as([]const u8, "LLVMv10"),
                            else => @as([]const u8, "LLVMv16"),
                        },
                    },
                },
            )) |swiftshader_dep| {
                exe.linkLibrary(swiftshader_dep.artifact("vk_swiftshader_static"));
            },
            .windows => if (b.lazyDependency(
                "swiftshader",
                .{
                    .target = target,
                    .optimize = .ReleaseSmall,
                    .jit_mode = switch (optimize) {
                        .Debug => switch (target.result.cpu.arch) {
                            .x86, .x86_64 => @as([]const u8, "Subzero"),
                            else => @as([]const u8, "LLVMv10"),
                        },
                        else => switch (target.result.cpu.arch) {
                            .x86 => @as([]const u8, "LLVMv10"),
                            else => @as([]const u8, "LLVMv16"),
                        },
                    },
                },
            )) |swiftshader_dep| {
                exe.linkLibrary(swiftshader_dep.artifact("vk_swiftshader_static"));
            },
            else => {},
        }
    } else if (target.result.isDarwin()) {
        if (b.lazyDependency("MoltenVK", .{})) |MoltenVK_dep| {
            if (b.lazyDependency("xcode_frameworks", .{})) |xcode_dep| {
                exe.root_module.addSystemFrameworkPath(.{
                    .cwd_relative = xcode_dep.builder.pathFromRoot("Frameworks/")
                });
                exe.root_module.addSystemIncludePath(.{
                    .cwd_relative = xcode_dep.builder.pathFromRoot("include/")
                });
                exe.root_module.addLibraryPath(.{
                    .cwd_relative = xcode_dep.builder.pathFromRoot("lib/")
                });
            }

            exe.linkFramework("IOSurface");
            exe.linkFramework("Metal");
            exe.linkFramework("QuartzCore");
            exe.addLibraryPath(MoltenVK_dep.path("MoltenVK/MoltenVK.xcframework/macos-arm64_x86_64"));
            exe.linkSystemLibrary("MoltenVK");
        }
    }

    {
        const opts = b.addOptions();
        opts.addOption(bool, "CPU_RENDERING_FALLBACK", cpu_rendering_fallback);
        exe.root_module.addImport("build_options", opts.createModule());
    }

    // add shader compilation to demo how it can be done in a build script
    const compile_frag_step = try get_shader_compiler(b, true);
    switch (compile_frag_step.compiler_kind) {
        .glslang => compile_frag_step.run_step.addArg("-V"),
        .glslc => {
            compile_frag_step.run_step.addArg("-O");
            compile_frag_step.run_step.addArg("-fshader-stage=frag");
        },
    }
    compile_frag_step.run_step.addFileArg(.{ .path = "src/imgui.frag.glsl" });
    compile_frag_step.run_step.addArg("-o");
    const frag_spv = compile_frag_step.run_step.addOutputFileArg("imgui.frag.spv");
    exe.root_module.addAnonymousImport("imgui.frag.spv", .{ .root_source_file = frag_spv });

    const compile_vert_step = try get_shader_compiler(b, true);
    switch (compile_vert_step.compiler_kind) {
        .glslang => compile_vert_step.run_step.addArg("-V"),
        .glslc => {
            compile_vert_step.run_step.addArg("-O");
            compile_vert_step.run_step.addArg("-fshader-stage=vert");
        },
    }
    compile_vert_step.run_step.addFileArg(.{ .path = "src/imgui.vert.glsl" });
    compile_vert_step.run_step.addArg("-o");
    const vert_spv = compile_vert_step.run_step.addOutputFileArg("imgui.vert.spv");
    exe.root_module.addAnonymousImport("imgui.vert.spv", .{ .root_source_file = vert_spv });

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
