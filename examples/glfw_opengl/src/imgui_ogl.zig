const zimgui = @import("Zig-ImGui");

pub extern fn ImGui_ImplOpenGL3_Init(glsl_version: ?[*:0]const u8) bool;
pub extern fn ImGui_ImplOpenGL3_Shutdown() void;
pub extern fn ImGui_ImplOpenGL3_NewFrame() void;
pub extern fn ImGui_ImplOpenGL3_RenderDrawData(draw_data: *const zimgui.DrawData) void;
