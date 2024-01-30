const vk = @import("vk");


pub const BaseWrapperVtable = vk.BaseWrapper(.{
    .createInstance = true,
    .enumerateInstanceExtensionProperties = true,
    .getInstanceProcAddr = true,
});

pub const InstanceWrapperVtable = vk.InstanceWrapper(.{
    .createDevice = true,
    .destroyInstance = true,
    .enumerateDeviceExtensionProperties = true,
    .enumeratePhysicalDevices = true,
    .getDeviceProcAddr = true,
    .getPhysicalDeviceProperties = true,
    .getPhysicalDeviceQueueFamilyProperties = true,
    .getPhysicalDeviceSurfaceSupportKHR = true,
});

pub const DeviceWrapperVtable = vk.DeviceWrapper(.{
    .acquireNextImageKHR = true,
    .beginCommandBuffer = true,
    .cmdBeginRenderPass = true,
    .cmdEndRenderPass = true,
    .createDescriptorPool = true,
    .createShaderModule = true,
    .destroyDescriptorPool = true,
    .destroyDevice = true,
    .destroyShaderModule = true,
    .deviceWaitIdle = true,
    .endCommandBuffer = true,
    .getDeviceQueue = true,
    .queuePresentKHR = true,
    .queueSubmit = true,
    .resetCommandPool = true,
    .resetFences = true,
    .waitForFences = true,
});

pub var base_wrapper: BaseWrapperVtable = undefined;
pub var instance_wrapper: InstanceWrapperVtable = undefined;
pub var device_wrapper: DeviceWrapperVtable = undefined;
