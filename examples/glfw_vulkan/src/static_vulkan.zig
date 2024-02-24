const vk = @import("vk");


pub extern fn vkGetInstanceProcAddr(
    instance: vk.Instance,
    p_name: [*:0]const u8,
) callconv(vk.vulkan_call_conv) vk.PfnVoidFunction;
