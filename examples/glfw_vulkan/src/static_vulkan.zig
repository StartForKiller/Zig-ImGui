const builtin = @import("builtin");

const build_options = @import("build_options");
const vk = @import("vk");


const internal = struct {
    pub extern fn vkGetInstanceProcAddr(
        instance: vk.Instance,
        p_name: [*:0]const u8,
    ) callconv(vk.vulkan_call_conv) vk.PfnVoidFunction;

    pub fn stub_vkGetInstanceProcAddr(
        instance: vk.Instance,
        p_name: [*:0]const u8,
    ) callconv(vk.vulkan_call_conv) vk.PfnVoidFunction {
        _ = instance;
        _ = p_name;
        return null;
    }
};

pub const vkGetInstanceProcAddr =
    if (
        (builtin.os.tag.isDarwin() and build_options.MOLTENVK_DRIVER_MODE == .static) or
        build_options.SWIFTSHADER_DRIVER_MODE == .static
    )
        internal.vkGetInstanceProcAddr
    else
        internal.stub_vkGetInstanceProcAddr;
