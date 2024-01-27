const std = @import("std");

const glfw = @import("mach-glfw");
const zgl_helpers = @import("zgl");
const zgl = zgl_helpers.binding;
const zimgui = @import("Zig-ImGui");


pub extern fn ImGui_ImplOpenGL3_Init(glsl_version: ?[*:0]const u8) bool;
pub extern fn ImGui_ImplOpenGL3_Shutdown() void;
pub extern fn ImGui_ImplOpenGL3_NewFrame() void;
pub extern fn ImGui_ImplOpenGL3_RenderDrawData(draw_data: *const anyopaque) void;

pub extern fn ImGui_ImplGlfw_InitForOpenGL(window: *anyopaque, install_callbacks: bool) bool;
pub extern fn ImGui_ImplGlfw_Shutdown() void;
pub extern fn ImGui_ImplGlfw_NewFrame() void;

/// Default GLFW error handling callback
fn errorCallback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
    std.log.err("glfw: {}: {s}\n", .{ error_code, description });
}

fn glGetProcAddress(p: glfw.GLProc, proc: [:0]const u8) ?zgl.FunctionPointer {
    _ = p;
    return glfw.getProcAddress(proc);
}

pub fn main() !void {
    glfw.setErrorCallback(errorCallback);
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{ glfw.getErrorString() });
        std.process.exit(1);
    }
    defer glfw.terminate();

    // Create our window
    const window = glfw.Window.create(
        800,
        800,
        "mach-glfw + zig-opengl + Zig-ImGui",
        null,
        null,
        .{},
    ) orelse {
        std.log.err("failed to create GLFW window: {?s}", .{ glfw.getErrorString() });
        std.process.exit(1);
    };
    defer window.destroy();

    glfw.makeContextCurrent(window);

    const proc: glfw.GLProc = undefined;
    try zgl.load(proc, glGetProcAddress);

    const im_context = zimgui.CreateContext();
    zimgui.SetCurrentContext(im_context);
    {
        const im_io = zimgui.GetIO();
        im_io.IniFilename = null;
    }

    zimgui.StyleColorsDark();
    _ = ImGui_ImplGlfw_InitForOpenGL(@ptrCast(window.handle), true);
    _ = ImGui_ImplOpenGL3_Init(null);

    // Wait for the user to close the window.
    while (!window.shouldClose()) {
        glfw.pollEvents();
        const window_size = window.getFramebufferSize();

        zgl.clearColor(1, 0, 1, 1);
        zgl.clear(zgl.COLOR_BUFFER_BIT);

        ImGui_ImplOpenGL3_NewFrame();
        var im_io = zimgui.GetIO();
        im_io.DisplaySize = zimgui.Vec2.init(@floatFromInt(window_size.width), @floatFromInt(window_size.height));
        zimgui.NewFrame();

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
        view.?.WorkPos.x -= demo_offset_x - ((@as(f32, @floatFromInt(window_size.width)) - demo_window_x) / 2);
        view.?.WorkPos.y -= demo_offset_y - ((@as(f32, @floatFromInt(window_size.height)) - demo_window_y) / 2);

        zimgui.ShowDemoWindow();

        zimgui.EndFrame();
        zimgui.Render();
        ImGui_ImplOpenGL3_RenderDrawData(zimgui.GetDrawData());

        window.swapBuffers();
    }

    ImGui_ImplOpenGL3_Shutdown();
    ImGui_ImplGlfw_Shutdown();
    zimgui.DestroyContext();
}
