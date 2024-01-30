const builtin = @import("builtin");
const std = @import("std");

const imgui_glfw = @import("imgui_glfw.zig");
const imgui_vk = @import("imgui_vk.zig");
const vk_dispatch = @import("vk_dispatch.zig");

const glfw = @import("mach-glfw");
const vk = @import("vk");
const zimgui = @import("Zig-ImGui");


const SwapchainState = enum {
    reuse_swapchain,
    rebuild_swapchain,
};

const CLEAR_COLOR = zimgui.Vec4.init(0.45, 0.55, 0.60, 1.0);
const MIN_IMAGE_COUNT: u32 = 2;

/// Default GLFW error handling callback
fn glfw_error_callback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
    std.log.err("GLFW: {}: {s}\n", .{ error_code, description });
}

fn check_vk_result(result: vk.Result) callconv(.C) void {
    if (@intFromEnum(result) >= 0) return;

    std.log.err("[Vulkan] Error: VkResult = {any}", .{ result });
    std.process.exit(1);
}

fn is_extension_available(available_extensions: []const vk.ExtensionProperties, extension: []const u8) bool {
    for (available_extensions) |available| {
        if (std.mem.eql(
            u8,
            extension,
            available.extension_name[0..@min(extension.len, available.extension_name.len)],
        )) {
            return true;
        }
    }

    return false;
}

fn setup_vulkan_select_physical_device(allocator: std.mem.Allocator, instance: vk.Instance) !vk.PhysicalDevice {
    const gpus = blk: {
        var count: u32 = undefined;
        _ = try vk_dispatch.instance_wrapper.enumeratePhysicalDevices(instance, &count, null);
        var buf = try allocator.alloc(vk.PhysicalDevice, count);
        _ = try vk_dispatch.instance_wrapper.enumeratePhysicalDevices(instance, &count, buf[0..].ptr);
        break :blk buf;
    };
    defer allocator.free(gpus);

    // If a number >1 of GPUs got reported, find discrete GPU if present, or
    // use first one available. This covers most common cases
    // (multi-gpu/integrated+dedicated graphics). Handling more complicated
    // setups (multiple dedicated GPUs) is out of scope of this sample.
    for (gpus) |physical_device| {
        const props = vk_dispatch.instance_wrapper.getPhysicalDeviceProperties(physical_device);
        if (props.device_type == .discrete_gpu) {
            return physical_device;
        }
    }

    // Use first GPU (Integrated) is a Discrete one is not available.
    if (gpus.len >= 1) {
        return gpus[0];
    }
    return .null_handle;
}

/// This function populates all the vk_dispatch vtables, and they are safe to
/// call only after it returns without error.
fn setup_vulkan(allocator: std.mem.Allocator) !imgui_vk.ImGui_ImplVulkan_InitInfo {
    // We are dynamically loading vulkan, which glfw provides an easy helper
    // for. We use the glfw `getInstanceProcAddress` function to get the vulkan
    // `getInstanceProcAddr` function pointer. These functions should return
    // the same addresses for a given input, however, the glfw function is a
    // `callconv(.C)` function. While this is the calling convention used by
    // vulkan on nearly all platforms, different ones are used on some
    // platforms. To conform to this, instead we use the glfw function to get
    // the actual vulkan function pointer that has the appropriate calling
    // convention.
    const gpa: vk.PfnGetInstanceProcAddr = @ptrCast(
        glfw.getInstanceProcAddress(null, vk.BaseCommandFlags.cmdName(.getInstanceProcAddr))
            orelse return error.VulkanUnsupported
    );

    // Populate a minimal vtable with the few vulkan functions we can load
    // without having set up a vk.Instance
    vk_dispatch.base_wrapper = try vk_dispatch.BaseWrapperVtable.load(gpa);

    // Create Vulkan Instance
    const instance: vk.Instance = blk: {
        // Enumerate available extensions
        const available_extensions: []const vk.ExtensionProperties = blk2: {
            var count: u32 = undefined;
            _ = try vk_dispatch.base_wrapper.enumerateInstanceExtensionProperties(null, &count, null);
            var buf = try allocator.alloc(vk.ExtensionProperties, count);
            _ = try vk_dispatch.base_wrapper.enumerateInstanceExtensionProperties(null, &count, buf[0..].ptr);
            break :blk2 buf;
        };
        defer allocator.free(available_extensions);

        // Collect required extensions
        var required_extensions = std.ArrayList([*:0]const u8).init(allocator);
        defer required_extensions.deinit();
        try required_extensions.appendSlice(glfw.getRequiredInstanceExtensions().?);
        try required_extensions.append(vk.extension_info.khr_get_physical_device_properties_2.name);
        if (builtin.os.tag.isDarwin()) {
            try required_extensions.append(vk.extension_info.khr_portability_enumeration.name);
        }

        // Ensure required extensions available
        for (required_extensions.items) |required_raw| {
            const required: [:0]const u8 = std.mem.span(required_raw);
            if (!is_extension_available(available_extensions, required)) {
                return error.UnsupportedVulkanExtension;
            }
        }

        // Create Vulkan Instance
        const instance_create_info: vk.InstanceCreateInfo = .{
            .flags = .{ .enumerate_portability_bit_khr = builtin.os.tag.isDarwin() },
            .enabled_extension_count = @intCast(required_extensions.items.len),
            .pp_enabled_extension_names = required_extensions.items.ptr,
        };
        break :blk try vk_dispatch.base_wrapper.createInstance(&instance_create_info, null);
    };

    // Populate secondary vtable that requires a vk.Instance to populate
    vk_dispatch.instance_wrapper = try vk_dispatch.InstanceWrapperVtable.load(
        instance,
        vk_dispatch.base_wrapper.dispatch.vkGetInstanceProcAddr,
    );
    errdefer vk_dispatch.instance_wrapper.destroyInstance(instance, null);

    // Select Physical Device (GPU)
    const physical_device = try setup_vulkan_select_physical_device(allocator, instance);

    // Select graphics queue family
    const queue_family_index: u32 = blk: {
        var count: u32 = undefined;
        vk_dispatch.instance_wrapper.getPhysicalDeviceQueueFamilyProperties(physical_device, &count, null);
        var buf = try allocator.alloc(vk.QueueFamilyProperties, count);
        defer allocator.free(buf);
        vk_dispatch.instance_wrapper.getPhysicalDeviceQueueFamilyProperties(physical_device, &count, buf[0..].ptr);

        for (buf, 0..) |q_props, i| {
            if (q_props.queue_flags.contains(.{ .graphics_bit = true })) {
                break :blk @intCast(i);
            }
        }

        return error.VulkanGraphicsQueueNotFound;
    };

    // Create Logical Device (with 1 queue)
    const device = blk: {
        // Collect required extensions
        var required_extensions = std.ArrayList([*:0]const u8).init(allocator);
        defer required_extensions.deinit();
        try required_extensions.append(vk.extension_info.khr_swapchain.name);

        // Enumerate available physical device extensions
        var count: u32 = undefined;
        _ = try vk_dispatch.instance_wrapper.enumerateDeviceExtensionProperties(physical_device, null, &count, null);
        var buf = try allocator.alloc(vk.ExtensionProperties, count);
        defer allocator.free(buf);
        _ = try vk_dispatch.instance_wrapper.enumerateDeviceExtensionProperties(
            physical_device,
            null,
            &count,
            buf[0..].ptr,
        );

        if (is_extension_available(buf, vk.extension_info.khr_portability_subset.name)) {
            try required_extensions.append(vk.extension_info.khr_portability_subset.name);
        }

        const device_create_info: vk.DeviceCreateInfo = .{
            .queue_create_info_count = 1,
            .p_queue_create_infos = &@as([1]vk.DeviceQueueCreateInfo, .{
                .{
                    .queue_family_index = queue_family_index,
                    .queue_count = 1,
                    .p_queue_priorities = &@as([1]f32, .{ 1.0 }),
                },
            }),
            .enabled_extension_count = @intCast(required_extensions.items.len),
            .pp_enabled_extension_names = required_extensions.items[0..].ptr,
        };
        break :blk try vk_dispatch.instance_wrapper.createDevice(physical_device, &device_create_info, null);
    };

    // Populate tertiary vtable that requires a vk.Device to populate
    vk_dispatch.device_wrapper = try vk_dispatch.DeviceWrapperVtable.load(
        device,
        vk_dispatch.instance_wrapper.dispatch.vkGetDeviceProcAddr,
    );
    errdefer vk_dispatch.device_wrapper.destroyDevice(device, null);

    const device_queue = vk_dispatch.device_wrapper.getDeviceQueue(device, queue_family_index, 0);

    // Create Descriptor Pool
    // The example only requires a single combined image sampler descriptor for
    // the font image and only uses one descriptor set (for that). If you wish
    // to load e.g. additional textures you may need to alter pools sizes.
    const pool_info: vk.DescriptorPoolCreateInfo = .{
        .flags = .{ .free_descriptor_set_bit = true },
        .max_sets = 1,
        .pool_size_count = 1,
        .p_pool_sizes = &@as([1]vk.DescriptorPoolSize, .{
            .{ .type = .combined_image_sampler, .descriptor_count = 1 },
        }),
    };
    const descriptor_pool = try vk_dispatch.device_wrapper.createDescriptorPool(device, &pool_info, null);

    const Intermediary = struct {
        instance: vk.Instance,

        // we use `callconv(vk.vulkan_call_conv)` here for the same reason we
        // did a two step load of the `base_wrapper` near the beginning of this
        // function
        pub fn load(fn_name: [*:0]const u8, self_ptr: ?*anyopaque) callconv(vk.vulkan_call_conv) vk.PfnVoidFunction {
            const self: *@This() = @ptrCast(@alignCast(self_ptr.?));
            return vk_dispatch.base_wrapper.getInstanceProcAddr(self.instance, fn_name);
        }
    };
    // while this is never mutated, Dear ImGui's headers require a that it
    // calls a function that takes a mutable pointer, so this is mutable to
    // allow that.
    var intermediary: Intermediary = .{ .instance = instance };

    // Have Dear ImGui load its internal vulkan vtable
    if (!imgui_vk.ImGui_ImplVulkan_LoadFunctions(&Intermediary.load, @ptrCast(&intermediary))) {
        return error.ImGuiVulkanVtableCreationFailed;
    }

    return .{
        .instance = instance,
        .physical_device = physical_device,
        .device = device,
        .queue_family = queue_family_index,
        .queue = device_queue,
        .pipeline_cache = .null_handle,
        .descriptor_pool = descriptor_pool,
        .subpass = 0,
        .min_image_count = MIN_IMAGE_COUNT,
        .image_count = 0,
        .msaa_samples = .{ .@"1_bit" = true },

        .use_dynamic_rendering = false,
        .color_attachment_format = .undefined,

        .allocator = null,
        .check_vk_result_fn_ptr = &check_vk_result,
        .min_allocation_size = 0,
    };
}

fn setup_vulkan_window(
    init_info: imgui_vk.ImGui_ImplVulkan_InitInfo,
    surface: vk.SurfaceKHR,
    width: u32,
    height: u32,
) !imgui_vk.ImGui_ImplVulkanH_Window {
    // Check for WSI support
    const supported = try vk_dispatch.instance_wrapper.getPhysicalDeviceSurfaceSupportKHR(
        init_info.physical_device,
        init_info.queue_family,
        surface,
    );
    if (supported != vk.TRUE) {
        return error.VulkanSurfaceUnsupported;
    }

    // Select Surface Format
    const surface_format = imgui_vk.ImGui_ImplVulkanH_SelectSurfaceFormat(
        init_info.physical_device,
        surface,
        &@as([4]vk.Format, .{ .b8g8r8a8_unorm, .r8g8b8a8_unorm, .b8g8r8_unorm, .r8g8b8_unorm }),
        4,
        .srgb_nonlinear_khr,
    );

    // Select Present Mode
    const present_mode = imgui_vk.ImGui_ImplVulkanH_SelectPresentMode(
        init_info.physical_device,
        surface,
        &@as([1]vk.PresentModeKHR, .{ .fifo_khr }),
        1,
    );

    // Dear ImGui prefers fields in this struct to be zero init. This isn't
    // idiomatic to do in zig, but cross language interactions like this can
    // occasionally make it necessary.
    var wd = std.mem.zeroInit(imgui_vk.ImGui_ImplVulkanH_Window, .{
        .surface = surface,
        .surface_format = surface_format,
        .present_mode = present_mode,
        .clear_enable = true,
    });

    // Create SwapChain, RenderPass, Framebuffer, etc.
    imgui_vk.ImGui_ImplVulkanH_CreateOrResizeWindow(
        init_info.instance,
        init_info.physical_device,
        init_info.device,
        &wd,
        init_info.queue_family,
        null,
        @intCast(width),
        @intCast(height),
        MIN_IMAGE_COUNT,
    );

    return wd;
}

fn cleanup_vulkan(init_info: imgui_vk.ImGui_ImplVulkan_InitInfo) void {
    vk_dispatch.device_wrapper.destroyDescriptorPool(init_info.device, init_info.descriptor_pool, null);
    vk_dispatch.device_wrapper.destroyDevice(init_info.device, null);
    vk_dispatch.instance_wrapper.destroyInstance(init_info.instance, null);
}

fn cleanup_vulkan_window(instance: vk.Instance, device: vk.Device, wd: *imgui_vk.ImGui_ImplVulkanH_Window) void {
    imgui_vk.ImGui_ImplVulkanH_DestroyWindow(instance, device, wd, null);
}

fn frame_render(
    wd: *imgui_vk.ImGui_ImplVulkanH_Window,
    draw_data: *const zimgui.DrawData,
    device: vk.Device,
    queue: vk.Queue,
) !SwapchainState {
    const image_acquired_semaphore = wd.frames_semaphores.?[wd.semaphore_index].image_acquired_semaphore;
    const render_complete_semaphore = wd.frames_semaphores.?[wd.semaphore_index].render_complete_semaphore;
    const out = vk_dispatch.device_wrapper.acquireNextImageKHR(
        device,
        wd.swapchain,
        std.math.maxInt(u64),
        image_acquired_semaphore,
        .null_handle,
    )
        catch |err| switch (err) {
            error.OutOfDateKHR => return .rebuild_swapchain,
            else => return err,
        };
    if (out.result == .suboptimal_khr) return .rebuild_swapchain;

    const frame_data = wd.frames.?[wd.frame_index];
    // wait indefinitely instead of periodically checking
    _ = try vk_dispatch.device_wrapper.waitForFences(
        device,
        1,
        &@as([1]vk.Fence, .{ frame_data.fence }),
        vk.TRUE,
        std.math.maxInt(u64),
    );

    try vk_dispatch.device_wrapper.resetFences(device, 1, &@as([1]vk.Fence, .{ frame_data.fence }));
    try vk_dispatch.device_wrapper.resetCommandPool(device, frame_data.command_pool, .{});

    const cmdbuf_begin_info: vk.CommandBufferBeginInfo = .{
        .flags = .{ .one_time_submit_bit = true },
    };
    try vk_dispatch.device_wrapper.beginCommandBuffer(frame_data.command_buffer, &cmdbuf_begin_info);

    const render_pass_begin_info: vk.RenderPassBeginInfo = .{
        .render_pass = wd.render_pass,
        .framebuffer = frame_data.framebuffer,
        .render_area = .{
            .extent = .{ .width = @intCast(wd.width), .height = @intCast(wd.height) },
            .offset = .{ .x = 0, .y = 0 },
        },
        .clear_value_count = 1,
        .p_clear_values = &@as([1]vk.ClearValue, .{ wd.clear_value }),
    };
    vk_dispatch.device_wrapper.cmdBeginRenderPass(frame_data.command_buffer, &render_pass_begin_info, .@"inline");

    // Record Dear Imgui primitives into command buffer
    imgui_vk.ImGui_ImplVulkan_RenderDrawData(draw_data, frame_data.command_buffer, .null_handle);

    // Submit command buffer
    vk_dispatch.device_wrapper.cmdEndRenderPass(frame_data.command_buffer);
    try vk_dispatch.device_wrapper.endCommandBuffer(frame_data.command_buffer);

    const queue_submit_info: vk.SubmitInfo = .{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = &@as([1]vk.Semaphore, .{ image_acquired_semaphore }),
        .p_wait_dst_stage_mask = &@as([1]vk.PipelineStageFlags, .{ .{ .color_attachment_output_bit = true } }),
        .command_buffer_count = 1,
        .p_command_buffers = &@as([1]vk.CommandBuffer, .{ frame_data.command_buffer }),
        .signal_semaphore_count = 1,
        .p_signal_semaphores = &@as([1]vk.Semaphore, .{ render_complete_semaphore }),
    };
    try vk_dispatch.device_wrapper.queueSubmit(
        queue,
        1,
        &@as([1]vk.SubmitInfo, .{ queue_submit_info }),
        frame_data.fence,
    );
    return .reuse_swapchain;
}

fn frame_present(wd: *imgui_vk.ImGui_ImplVulkanH_Window, queue: vk.Queue) !SwapchainState {
    const render_complete_semaphore = wd.frames_semaphores.?[wd.semaphore_index].render_complete_semaphore;
    const present_info: vk.PresentInfoKHR = .{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = &@as([1]vk.Semaphore, .{ render_complete_semaphore }),
        .swapchain_count = 1,
        .p_swapchains = &@as([1]vk.SwapchainKHR, .{ wd.swapchain }),
        .p_image_indices = &@as([1]u32, .{ wd.frame_index }),
    };
    const result = vk_dispatch.device_wrapper.queuePresentKHR(queue, &present_info)
        catch |err| switch (err) {
            error.OutOfDateKHR => return .rebuild_swapchain,
            else => return err,
        };
    if (result == .suboptimal_khr) return .rebuild_swapchain;

    // Now we can use the next set of semaphores
    wd.semaphore_index = (wd.semaphore_index + 1) % wd.image_count;
    return .reuse_swapchain;
}

/// ImGui's helper functions load pre-compiled SPIR-V shaders for you, so this
/// is completely unnecessary. This is only to demo how to include shaders
/// easily in a zig project.
fn load_dummy_shaders(device: vk.Device) !void {
    // Shader modules are loaded from u32 arrays, and `@alignOf(u32) == 4`.
    // Unforunately, @embedFile is a `[] align (1) const u8`. Thankfully, even
    // though @alignCast cannot increase the pointer alignment of a type, it
    // does assert that it was able to do the conversion because it was already
    // aligned correctly. By making this a comptime block, we are able to take
    // advantage of this and verify at compile time that the embedded shader is
    // able to be coerced safely into an `[] align (4) const u8`. Then, we can
    // safely use `std.mem.bytesAsSlice()` to cast these well aligned bytes
    // into a `[] align (4) const u32`, aka a `[]const u32` for short.
    const frag_src: []const u32 = comptime blk: {
        const raw: []const u8 = @embedFile("imgui.frag.spv");
        const aligned: [] align(@alignOf(u32)) const u8 = @alignCast(raw);
        break :blk std.mem.bytesAsSlice(u32, aligned[0..]);
    };
    const frag_module = try vk_dispatch.device_wrapper.createShaderModule(
        device,
        &.{ .code_size = frag_src.len * @sizeOf(u32), .p_code = frag_src.ptr },
        null,
    );

    // same trick as above
    const vert_src: []const u32 = comptime blk: {
        const raw: []const u8 = @embedFile("imgui.vert.spv");
        const aligned: [] align(@alignOf(u32)) const u8 = @alignCast(raw);
        break :blk std.mem.bytesAsSlice(u32, aligned[0..]);
    };
    const vert_module = try vk_dispatch.device_wrapper.createShaderModule(
        device,
        &.{ .code_size = vert_src.len * @sizeOf(u32), .p_code = vert_src.ptr },
        null,
    );

    // just immediately delete after verifying that we *can* load these modules
    vk_dispatch.device_wrapper.destroyShaderModule(device, vert_module, null);
    vk_dispatch.device_wrapper.destroyShaderModule(device, frag_module, null);
}

// Main code
pub fn main() !u8 {
    glfw.setErrorCallback(glfw_error_callback);
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{ glfw.getErrorString() });
        return 1;
    }
    defer glfw.terminate();

    if (!glfw.vulkanSupported()) {
        std.log.err("GLFW: Vulkan Not Supported\n", .{});
        return 1;
    }

    // Create window with Vulkan context
    const window = glfw.Window.create(
        800,
        800,
        "mach-glfw + vulkan-zig + Zig-ImGui",
        null,
        null,
        .{ .client_api = .no_api },
    ) orelse {
        std.log.err("failed to create GLFW window: {?s}", .{ glfw.getErrorString() });
        return 1;
    };
    defer window.destroy();

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    var init_info = try setup_vulkan(gpa.allocator());

    // Create Window Surface
    const surface = blk: {
        var surface: vk.SurfaceKHR = undefined;
        switch (@as(vk.Result, @enumFromInt(glfw.createWindowSurface(init_info.instance, window, null, &surface))))
        {
            .success => {},
            .error_out_of_host_memory => return error.OutOfHostMemory,
            .error_out_of_device_memory => return error.OutOfDeviceMemory,
            .error_native_window_in_use_khr => return error.NativeWindowInUseKHR,
            else => |result| check_vk_result(result),
        }
        break :blk surface;
    };

    // Create Framebuffers
    var wd = blk: {
        const fb_size = window.getFramebufferSize();
        break :blk try setup_vulkan_window(init_info, surface, fb_size.width, fb_size.height);
    };
    init_info.image_count = wd.image_count;

    // Setup Dear ImGui context
    const im_context = zimgui.CreateContext();
    defer zimgui.DestroyContext();
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

    // Setup Platfrom/Renderer backends
    _ = imgui_glfw.ImGui_ImplGlfw_InitForVulkan(window.handle, true);
    _ = imgui_vk.ImGui_ImplVulkan_Init(&init_info, wd.render_pass);

    // INSERT LOAD FONTS HERE

    try load_dummy_shaders(init_info.device);

    // Our state
    var rebuild_swapchain = false;

    // Main loop
    while (!window.shouldClose()) {
        // Poll and handle events (inputs, window resize, etc.)
        glfw.pollEvents();

        // Rebuild swap chain?
        if (rebuild_swapchain) {
            const fb_size = window.getFramebufferSize();
            if (fb_size.width > 0 and fb_size.height > 0) {
                // This is probably unnecessary since we never change it?
                imgui_vk.ImGui_ImplVulkan_SetMinImageCount(MIN_IMAGE_COUNT);

                imgui_vk.ImGui_ImplVulkanH_CreateOrResizeWindow(
                    init_info.instance,
                    init_info.physical_device,
                    init_info.device,
                    &wd,
                    init_info.queue_family,
                    null,
                    @intCast(fb_size.width),
                    @intCast(fb_size.height),
                    MIN_IMAGE_COUNT,
                );
                wd.frame_index = 0;
                rebuild_swapchain = false;
            }
        }

        // Start the Dear ImGui frame
        imgui_vk.ImGui_ImplVulkan_NewFrame();
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
        const draw_data = zimgui.GetDrawData();
        const is_minimized = (draw_data.DisplaySize.x <= 0.0) and (draw_data.DisplaySize.y <= 0.0);
        if (!is_minimized) {
            wd.clear_value.color.float_32 = .{
                CLEAR_COLOR.x * CLEAR_COLOR.w,
                CLEAR_COLOR.y * CLEAR_COLOR.w,
                CLEAR_COLOR.z * CLEAR_COLOR.w,
                CLEAR_COLOR.w,
            };

            if (try frame_render(&wd, draw_data, init_info.device, init_info.queue) == .reuse_swapchain) {
                if (try frame_present(&wd, init_info.queue) == .reuse_swapchain) {
                    continue;
                }
            }

            rebuild_swapchain = true;
        }
    }

    // Cleanup
    try vk_dispatch.device_wrapper.deviceWaitIdle(init_info.device);
    imgui_vk.ImGui_ImplVulkan_Shutdown();
    imgui_glfw.ImGui_ImplGlfw_Shutdown();

    cleanup_vulkan_window(init_info.instance, init_info.device, &wd);
    cleanup_vulkan(init_info);

    return 0;
}
