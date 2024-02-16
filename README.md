# Zig-ImGui

Zig-ImGui uses [cimgui](https://github.com/cimgui/cimgui) to generate [Zig](https://github.com/ziglang/zig) bindings for [Dear ImGui](https://github.com/ocornut/imgui).

It is currently up to date with [Dear ImGui v1.90.3](https://github.com/ocornut/imgui/releases/tag/v1.90.3).

At the time of writing, Zig-ImGui has been validated against zig `0.12.0-dev.2757+bec851172`

## Using the pre-generated bindings

Zig-ImGui strives to be easy to use.  To use the pre-generated bindings, do the following:

- Copy from the following dependency section into your project's `build.zig.zon` file:
    ```zig
    .{
        .name = "myproject",
        .version = "1.0.0", // whatever your version is
        .dependencies =
        .{
            .ZigImGui =
            .{
                // See `zig fetch --save <url>` for a command-line interface for adding dependencies.
                //.example = .{
                //    // When updating this field to a new URL, be sure to delete the corresponding
                //    // `hash`, otherwise you are communicating that you expect to find the old hash at
                //    // the new URL.
                //    .url = "https://example.com/foo.tar.gz",
                //
                //    // This is computed from the file contents of the directory of files that is
                //    // obtained after fetching `url` and applying the inclusion rules given by
                //    // `paths`.
                //    //
                //    // This field is the source of truth; packages do not come from a `url`; they
                //    // come from a `hash`. `url` is just one of many possible mirrors for how to
                //    // obtain a package matching this `hash`.
                //    //
                //    // Uses the [multihash](https://multiformats.io/multihash/) format.
                //    .hash = "...",
                //
                //    // When this is provided, the package is found in a directory relative to the
                //    // build root. In this case the package's hash is irrelevant and therefore not
                //    // computed. This field and `url` are mutually exclusive.
                //    .path = "foo",
                //},
                .hash = "1220fd4f4b5999fdaa5d6a80f515e9f486a49cac21e15d4e6ec5672cfc8c55bf329b",
                // Make sure to grab the latest commit version and not whatever is in this sample here
                .url = "git+https://gitlab.com/joshua.software.dev/Zig-ImGui.git#28e254661cb9d9812f2274a0b217d17a5f163da3",
            },
        },
    }
    ```
- In your build.zig, add the following:
    ```zig
    const ZigImGui_dep = b.dependency("ZigImGui", .{
        .target = target,
        .optimize = optimize,
        // Include support for using freetype font rendering in addition to
        // ImGui's default truetype, necessary for emoji support
        //
        // Note: ImGui will prefer using freetype by default when this option
        // is enabled, but the option to use typetype manually at runtime is
        // still available
        .enable_freetype = true, // if unspecified, the default is false
        // Enable ImGui's extension to freetype which uses lunasvg:
        // https://github.com/sammycage/lunasvg
        // to support SVGinOT (SVG in Open Type) color emojis
        //
        // Notes from ImGui's documentation:
        // * Not all types of color fonts are supported by FreeType at the
        //   moment.
        // * Stateful Unicode features such as skin tone modifiers are not
        //   supported by the text renderer.
        .enable_lunasvg = false // if unspecified, the default is false
    });

    // exes and shared libraries are also fine
    const my_static_lib = b.addStaticLibrary(.{
        .name = "my_static_lib",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    my_static_lib.root_module.addImport("Zig-ImGui", ZigImGui_dep.module("Zig-ImGui"));
    ```
- In your project, use `@import("Zig-ImGui")` to obtain the bindings.
- For more detailed documentation, see the [official ImGui documentation](https://github.com/ocornut/imgui/tree/v1.90.3-docking/docs).
- For an example of using these bindings, see [the included examples](https://gitlab.com/joshua.software.dev/Zig-ImGui/-/tree/master/examples/) or for a real project see [joshua-software-dev/AthenaOverlay](https://codeberg.org/joshua-software-dev/AthenaOverlay).

## Using the Dear ImGui Backends

Dear ImGui contains a number of [BACKENDS](https://github.com/ocornut/imgui/blob/master/docs/BACKENDS.md) that provide easier setup and abstraction of underlying platforms to lower the amount of work necessary to facilitate using it. Zig-ImGui does not compile these automatically, and you'll need to include the ones you want to use in your build manually. For example, to use the `imgui_impl_opengl3` backend:

```zig
// in your build.zig

const std = @import("std");

const ZigImGui_build_script = @import("ZigImGui");

pub fn build(b: *std.Build) void {
    // ...

    // init the ZigImGui dep with your preferred settings
    const ZigImGui_dep = b.dependency("ZigImGui", .{
        .target = target,
        .optimize = optimize,
        .enable_freetype = true,
        .enable_lunasvg = true,
    });
    // get the underlying ocornut/imgui repo dependency that Zig-ImGui uses
    const imgui_dep = ZigImGui_dep.builder.dependency("imgui", .{
        .target = target,
        .optimize = optimize,
    });

    const imgui_opengl = create_imgui_opengl_static_lib(b, target, optimize, imgui_dep, ZigImGui_dep);

    const exe = b.addExecutable(.{
        .name = "example",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addImport("Zig-ImGui", ZigImGui_dep.module("Zig-ImGui"));
    exe.linkLibrary(imgui_opengl);

    // ...
}

fn create_imgui_opengl_static_lib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imgui_dep: *std.Build.Dependency,
    ZigImGui_dep: *std.Build.Dependency,
) *std.Build.Step.Compile {
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

    // ensure the backend has access to the ImGui headers it expects
    imgui_opengl.addIncludePath(imgui_dep.path("."));
    imgui_opengl.addIncludePath(imgui_dep.path("backends/"));

    imgui_opengl.addCSourceFile(.{
        .file = imgui_dep.path("backends/imgui_impl_opengl3.cpp"),
        // use the same compile flags that the ImGui base does
        .flags = ZigImGui_build_script.IMGUI_C_FLAGS,
    });

    return imgui_opengl;
}
```

then, in your project, you'll want to define extern functions for the backend so you can call into them:

```zig
// src/main.zig

const zimgui = @import("Zig-ImGui");

pub extern fn ImGui_ImplOpenGL3_Init(glsl_version: ?[*:0]const u8) bool;
pub extern fn ImGui_ImplOpenGL3_Shutdown() void;
pub extern fn ImGui_ImplOpenGL3_NewFrame() void;
pub extern fn ImGui_ImplOpenGL3_RenderDrawData(draw_data: *const anyopaque) void;

pub fn main() !void {
    // ...

    var context = zimgui.CreateContext();

    // ...

    while (true) {
        // ...

        // this alone in not enough to use this backend, and is merely an
        // example of the shape of things you need to do.
        ImGui_ImplOpenGL3_NewFrame();

        // ..
    }
}
```

## Binding style

These bindings generally prefer the original Dear ImGui naming styles over Zig style.  Functions, types, and fields match the casing of the original.  Prefixes like ImGui* or Im* have been stripped.  Enum names as prefixes to enum values have also been stripped.

"Flags" enums have been translated to packed structs of bools, with helper functions for performing bit operations.  ImGuiCond specifically has been translated to CondFlags to match the naming style of other flag enums.

Const reference parameters have been translated to by-value parameters, which the Zig compiler will implement as by-const-reference with extra restrictions.  Mutable reference parameters have been converted to pointers.

Functions with default values have two generated variants.  The original name maps to the "simple" version with all defaults set.  Adding "Ext" to the end of the function will produce the more complex version with all available parameters.

Functions with multiple overloads have a postfix appended based on the first difference in parameter types.

For example, these two C++ functions generate four Zig functions:
```c++
void ImGui::SetWindowCollapsed(char const *name, bool collapsed, ImGuiCond cond = 0);
void ImGui::SetWindowCollapsed(bool collapsed, ImGuiCond cond = 0);
```
```zig
fn SetWindowCollapsed_Str(name: ?[*:0]const u8, collapsed: bool) void;
fn SetWindowCollapsed_StrExt(name: ?[*:0]const u8, collapsed: bool, cond: CondFlags) void;
fn SetWindowCollapsed_Bool(collapsed: bool) void;
fn SetWindowCollapsed_BoolExt(collapsed: bool, cond: CondFlags) void;
```

Nullability and array-ness of pointer parameters is hand-tuned by the logic in generate.py.  If you find any incorrect translations, please open an issue.

## Generating new bindings

To use a different version of Dear ImGui, new bindings need to be generated. You can set your preferred version in Zig-ImGui's `build.zig.zon` and `src/generator/build.zig.zon`, and then use the `zig build generate` command to do the necessary generation. It is preferable to have luajit or lua5.1 and python3 in $PATH for use in the generation, but if they are not available there, then they will instead be built from source by the `build.zig` script.

Some changes to Dear ImGui may require more in-depth changes to generate correct bindings. You may need to check for updates to upstream cimgui, or add rules to `src/generator/generate.py`.

You can do a quick check of the integrity of the bindings with `zig build test`.  This will verify that the version of Dear ImGui matches the bindings, and compile all wrapper functions in the bindings.
