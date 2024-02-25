const builtin = @import("builtin");
const std = @import("std");

const imgui_glfw = @import("imgui_glfw.zig");
const imgui_ogl = @import("imgui_ogl.zig");

const build_options = @import("build_options");
const glfw = @import("mach-glfw");
const zgl_helpers = @import("zgl");
const zgl = zgl_helpers.binding;
const zimgui = @import("Zig-ImGui");


/// Default GLFW error handling callback
fn errorCallback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
    std.log.err("GLFW: {}: {s}\n", .{ error_code, description });
}

fn glGetProcAddress(p: glfw.GLProc, proc: [:0]const u8) ?zgl.FunctionPointer {
    _ = p;
    return glfw.getProcAddress(proc);
}

// Main code
pub fn main() !u8 {
    glfw.setErrorCallback(errorCallback);
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{ glfw.getErrorString() });
        return 1;
    }
    defer glfw.terminate();

    // Create our window
    const window = glfw.Window.create(
        800,
        800,
        "mach-glfw + zig-opengl + Zig-ImGui",
        null,
        null,
        switch (build_options.OPENGL_ES_PROFILE) {
            true => .{
                .client_api = .opengl_es_api,
                .opengl_forward_compat = builtin.os.tag.isDarwin(),
                .opengl_profile = .opengl_core_profile,
                .context_creation_api = .egl_context_api,
                .context_version_major = build_options.OPENGL_MAJOR_VERSION,
                .context_version_minor = build_options.OPENGL_MINOR_VERSION,
            },
            else => .{
                .client_api = .opengl_api,
                .opengl_forward_compat = builtin.os.tag.isDarwin(),
                .opengl_profile = .opengl_core_profile,
                .context_version_major = build_options.OPENGL_MAJOR_VERSION,
                .context_version_minor = build_options.OPENGL_MINOR_VERSION,
            },
        },
    ) orelse {
        std.log.err("failed to create GLFW window: {?s}", .{ glfw.getErrorString() });
        return 1;
    };
    defer window.destroy();

    glfw.makeContextCurrent(window);
    glfw.swapInterval(1); // Enable Vsync

    // dynamic load opengl
    const proc: glfw.GLProc = undefined;
    try zgl.load(proc, glGetProcAddress);

    std.log.debug("OpenGL Version = {?s}", .{ zgl_helpers.getString(.version) });

    // Setup Dear ImGui context
    const im_context = zimgui.CreateContext();
    zimgui.SetCurrentContext(im_context);
    {
        const im_io = zimgui.GetIO();
        im_io.IniFilename = null;
        im_io.ConfigFlags = zimgui.ConfigFlags.with(
            im_io.ConfigFlags,
            .{ .NavEnableKeyboard = true, .NavEnableGamepad = true },
        );
    }

    // Setup Dear ImGui style
    zimgui.StyleColorsDark();

    // Setup Platform/Renderer backends
    _ = imgui_glfw.ImGui_ImplGlfw_InitForOpenGL(window.handle, true);
    switch (imgui_ogl.populate_dear_imgui_opengl_symbol_table(@ptrCast(&glfw.getProcAddress))) {
        .ok => {},
        .init_error, .open_library => return error.LoadOpenGLFailed,
        .opengl_version_unsupported => if (!build_options.OPENGL_ES_PROFILE) return error.UnsupportedOpenGlVersion,
    }
    _ = imgui_ogl.ImGui_ImplOpenGL3_Init(
        if (build_options.OPENGL_ES_PROFILE and build_options.OPENGL_MAJOR_VERSION <= 2)
            "#version 100"
        else if (build_options.OPENGL_ES_PROFILE and build_options.OPENGL_MAJOR_VERSION >= 3)
            "#version 300 es"
        else if (builtin.target.isDarwin())
            "#version 150"
        else
            null
    );

    // INSERT LOAD FONTS HERE

    const clear_color = zimgui.Vec4.init(1.0, 0.0, 1.0, 1.0);

    // Main loop
    while (!window.shouldClose()) {
        // Poll and handle events (inputs, window resize, etc.)
        glfw.pollEvents();

        // Start the Dear ImGui frame
        imgui_ogl.ImGui_ImplOpenGL3_NewFrame();
        imgui_glfw.ImGui_ImplGlfw_NewFrame();
        zimgui.NewFrame();

        // Normal Dear ImGui use
        {
            // This should be all that's necessary to center the window,
            // unforunately imgui ignores these settings for the demo window, so
            // something more jank is in order
            //
            // zimgui.SetNextWindowPos(zimgui.Vec2.init(
            //     ((@as(f32, @floatFromInt(window_size.width)) - 550) / 2),
            //     ((@as(f32, @floatFromInt(window_size.height)) - 680) / 2),
            // ));

            // Behold: Jank.
            const demo_window_x: f32 = 550.0;
            const demo_window_y: f32 = 680.0;
            const demo_offset_x: f32 = 650.0;
            const demo_offset_y: f32 = 20.0;
            const view = zimgui.GetMainViewport();
            const im_io = zimgui.GetIO();

            view.?.WorkPos.x -= demo_offset_x - ((im_io.DisplaySize.x - demo_window_x) / 2);
            view.?.WorkPos.y -= demo_offset_y - ((im_io.DisplaySize.y - demo_window_y) / 2);

            zimgui.ShowDemoWindow();
        }

        // Rendering
        zimgui.Render();
        const fb_size = window.getFramebufferSize();
        zgl.viewport(0, 0, @intCast(fb_size.width), @intCast(fb_size.height));
        zgl.clearColor(
            clear_color.x * clear_color.w,
            clear_color.y * clear_color.w,
            clear_color.z * clear_color.w,
            clear_color.w,
        );
        zgl.clear(zgl.COLOR_BUFFER_BIT);
        imgui_ogl.ImGui_ImplOpenGL3_RenderDrawData(zimgui.GetDrawData());

        window.swapBuffers();
    }

    // Cleanup
    imgui_ogl.ImGui_ImplOpenGL3_Shutdown();
    imgui_glfw.ImGui_ImplGlfw_Shutdown();
    zimgui.DestroyContext();

    return 0;
}
