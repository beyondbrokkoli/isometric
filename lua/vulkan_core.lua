local ffi = require("ffi")
local bit = require("bit")
require("vulkan_headers")

local reg = require("boilerplate")
local cfg = reg.cfg
local vk_struct = reg.vk_struct
local vk_queue = reg.vk_queue

ffi.cdef[[
    const char** vx_sys_glfw_extensions(uint32_t* count);
    void vx_sys_inject_validation(void* instance);
    void vx_sys_eject_validation(void* instance);
]]

local vk
local success, lib = pcall(ffi.load, "vulkan-1")
if not success then success, lib = pcall(ffi.load, "vulkan") end
if not success then success, lib = pcall(ffi.load, "libvulkan.so.1") end
assert(success, "FATAL: Could not load Vulkan!")
vk = lib

local core = {}

-- PART 1: Instance Creation
function core.create_instance(req_extensions)
    print("[LUA] Initializing Vulkan Core (Instance Generation)...")

    -- 1. Ask C for GLFW Extensions natively
    local pCount = ffi.new("uint32_t[1]")
    local glfwExtensions = ffi.C.vx_sys_glfw_extensions(pCount)
    local exts_count = pCount[0]

    -- 2. Calculate Total Extension Array Size
    -- Base = GLFW count + Registry requested count
    local total_exts = exts_count + #req_extensions
    if cfg.use_validation == 1 then
        total_exts = total_exts + 1   -- Add space for VK_EXT_debug_utils
    end

    -- 3. Allocate the C-Array
    local instanceExtensions = ffi.new("const char*[?]", total_exts)

    -- Copy GLFW extensions first
    for i = 0, exts_count - 1 do
        instanceExtensions[i] = glfwExtensions[i]
    end

    -- Copy our Registry extensions right after
    local ext_idx = exts_count
    for _, ext in ipairs(req_extensions) do
        instanceExtensions[ext_idx] = ext
        ext_idx = ext_idx + 1
    end

    -- 4. Configure Validation Layers
    local validationLayers = nil
    local layerCount = 0

    if cfg.use_validation == 1 then
        instanceExtensions[ext_idx] = "VK_EXT_debug_utils"
        validationLayers = ffi.new("const char*[1]", {"VK_LAYER_KHRONOS_validation"})
        layerCount = 1
        print("[LUA] Validation Layers ENABLED.")
    else
        print("[LUA] Validation Layers DISABLED. Running raw.")
    end

    -- 5. Build Info Structs & Create
    local appInfo = ffi.new("VkApplicationInfo", {
        sType = vk_struct.app_info,
        pApplicationName = "VX Engine Runtime",
        apiVersion = cfg.vk_api_version
    })

    local createInfo = ffi.new("VkInstanceCreateInfo", {
        sType = vk_struct.instance_create,
        pApplicationInfo = appInfo,
        enabledExtensionCount = total_exts,
        ppEnabledExtensionNames = instanceExtensions,
        enabledLayerCount = layerCount,
        ppEnabledLayerNames = validationLayers
    })

    local pInstance = ffi.new("VkInstance[1]")
    assert(vk.vkCreateInstance(createInfo, nil, pInstance) == 0, "FATAL: vkCreateInstance failed!")
    local instance = pInstance[0]

    if cfg.use_validation == 1 then
        ffi.C.vx_sys_inject_validation(instance)
    end

    return { vk = vk, instance = instance }
end

-- PART 2: Logical Device Generation
function core.finalize_device_and_swapchain(vk_state, surface_ptr, req_extensions)
    print("[LUA] Resuming Vulkan Setup. Finalizing Logical Device...")

    local vk = vk_state.vk
    local instance = vk_state.instance
    local surface = ffi.cast("VkSurfaceKHR", surface_ptr)
    vk_state.surface = surface

    -- 6. Find GPU and Queue Family (Untouched Mechanism)
    local pDeviceCount = ffi.new("uint32_t[1]")
    vk.vkEnumeratePhysicalDevices(instance, pDeviceCount, nil)
    local pDevices = ffi.new("VkPhysicalDevice[?]", pDeviceCount[0])
    vk.vkEnumeratePhysicalDevices(instance, pDeviceCount, pDevices)

    local physicalDevice = pDevices[0]
    vk_state.physicalDevice = physicalDevice

    local pQueueFamilyCount = ffi.new("uint32_t[1]")
    vk.vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice, pQueueFamilyCount, nil)
    local queueFamilies = ffi.new("VkQueueFamilyProperties[?]", pQueueFamilyCount[0])
    vk.vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice, pQueueFamilyCount, queueFamilies)

    local qIndex = -1
    for i = 0, pQueueFamilyCount[0] - 1 do
        if bit.band(queueFamilies[i].queueFlags, vk_queue.graphics) ~= 0 then
            qIndex = i
            break
        end
    end
    assert(qIndex ~= -1, "FATAL: Could not find a Graphics queue!")
    vk_state.qIndex = qIndex

    local queuePriority = ffi.new("float[1]", 1.0)
    local queueCreateInfo = ffi.new("VkDeviceQueueCreateInfo", {
        sType = vk_struct.device_queue_create,
        queueFamilyIndex = qIndex,
        queueCount = 1,
        pQueuePriorities = queuePriority
    })

    -- THE REFACTOR: Dynamic Device Extensions
    -- Allocate the C-array dynamically based on the registry table length
    local ext_count = #req_extensions    local deviceExtensions = ffi.new("const char*[?]", ext_count)
    for i, ext in ipairs(req_extensions) do
        deviceExtensions[i-1] = ext -- C arrays are 0-indexed, Lua is 1-indexed!
    end

    -- 7. Device Features (The Mechanism of linking pNext chain remains)
    local dynamicRendering = ffi.new("VkPhysicalDeviceDynamicRenderingFeatures")
    ffi.fill(dynamicRendering, ffi.sizeof(dynamicRendering))
    dynamicRendering.sType = vk_struct.dynamic_rendering_features
    dynamicRendering.dynamicRendering = 1

    local extDynamicState = ffi.new("VkPhysicalDeviceExtendedDynamicStateFeaturesEXT")
    ffi.fill(extDynamicState, ffi.sizeof(extDynamicState))
    extDynamicState.sType = vk_struct.extended_dynamic_state_features
    extDynamicState.pNext = dynamicRendering
    extDynamicState.extendedDynamicState = 1

    local extDynamicState2 = ffi.new("VkPhysicalDeviceExtendedDynamicState2FeaturesEXT")
    ffi.fill(extDynamicState2, ffi.sizeof(extDynamicState2))
    extDynamicState2.sType = vk_struct.extended_dynamic_state2_features
    extDynamicState2.pNext = extDynamicState
    extDynamicState2.extendedDynamicState2 = 1

    local deviceFeatures = ffi.new("VkPhysicalDeviceFeatures")
    ffi.fill(deviceFeatures, ffi.sizeof(deviceFeatures))
    deviceFeatures.largePoints = 1

    -- 8. Device Creation
    local deviceCreateInfo = ffi.new("VkDeviceCreateInfo")
    ffi.fill(deviceCreateInfo, ffi.sizeof(deviceCreateInfo))
    deviceCreateInfo.sType = vk_struct.device_create
    deviceCreateInfo.pNext = extDynamicState2
    deviceCreateInfo.queueCreateInfoCount = 1
    deviceCreateInfo.pQueueCreateInfos = queueCreateInfo

    -- INJECT THE DYNAMIC EXTENSIONS HERE
    deviceCreateInfo.enabledExtensionCount = ext_count
    deviceCreateInfo.ppEnabledExtensionNames = deviceExtensions

    deviceCreateInfo.pEnabledFeatures = deviceFeatures

    local pDevice = ffi.new("VkDevice[1]")
    assert(vk.vkCreateDevice(physicalDevice, deviceCreateInfo, nil, pDevice) == 0, "FATAL: vkCreateDevice failed!")

    local device = pDevice[0]
    vk_state.device = device
    print("[LUA] Logical Device Created!")

    local pQueue = ffi.new("VkQueue[1]")
    vk.vkGetDeviceQueue(device, qIndex, 0, pQueue)
    vk_state.queue = pQueue[0]

    return vk_state
end

-- TEARDOWN
function core.Destroy(vk_state)
    print("[TEARDOWN] Shutting down Vulkan Core...")
    local vk = vk_state.vk

    if vk_state.device ~= nil then
        vk.vkDestroyDevice(vk_state.device, nil)
    end

    if vk_state.surface ~= nil then
        vk.vkDestroySurfaceKHR(vk_state.instance, vk_state.surface, nil)
    end

    if vk_state.instance ~= nil then
        if cfg.use_validation == 1 then
            ffi.C.vx_sys_eject_validation(vk_state.instance)
        end
        vk.vkDestroyInstance(vk_state.instance, nil)
    end
end

return core
