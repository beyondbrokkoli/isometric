local ffi = require("ffi")
local bit = require("bit")

-- [NEW] Explicit Decoupled Imports
local reg = require("registry_vk")
local vk_mem = reg.vk_mem
local vk_struct = reg.vk_struct

local is_windows = (ffi.os == "Windows")
if is_windows then
    ffi.cdef[[
        void* _aligned_malloc(size_t size, size_t alignment);
        void _aligned_free(void* ptr);
    ]]
else
    ffi.cdef[[
        void* aligned_alloc(size_t alignment, size_t size);
        void free(void* ptr);
    ]]
end

local function platform_aligned_alloc(alignment, size)
    if is_windows then return ffi.C._aligned_malloc(size, alignment)
    else return ffi.C.aligned_alloc(alignment, size) end
end

local function platform_aligned_free(ptr)
    if is_windows then ffi.C._aligned_free(ptr)
    else ffi.C.free(ptr) end
end

local Memory = {
    Buffers = {},
    DeviceMemory = {},
    Mapped = {},
    AVX_Arrays = {}
}

local function FindSmartBufferMemory(vk, physicalDevice, typeFilter)
    local memProperties = ffi.new("VkPhysicalDeviceMemoryProperties")
    vk.vkGetPhysicalDeviceMemoryProperties(physicalDevice, memProperties)

    local rebarFlags = bit.bor(vk_mem.device_local, vk_mem.host_visible, vk_mem.host_coherent)
    for i = 0, memProperties.memoryTypeCount - 1 do
        if bit.band(typeFilter, bit.lshift(1, i)) ~= 0 and bit.band(memProperties.memoryTypes[i].propertyFlags, rebarFlags) == rebarFlags then
            print("[MEMORY] ReBAR Supported! Streaming directly to VRAM.")
            return i
        end
    end

    local stdFlags = bit.bor(vk_mem.host_visible, vk_mem.host_coherent)
    for i = 0, memProperties.memoryTypeCount - 1 do
        local flags = memProperties.memoryTypes[i].propertyFlags
        local has_std = bit.band(flags, stdFlags) == stdFlags
        local not_cached = bit.band(flags, vk_mem.host_cached) == 0
        if bit.band(typeFilter, bit.lshift(1, i)) ~= 0 and has_std and not_cached then
            print("[MEMORY] ReBAR NOT found. Falling back to System RAM (Write-Combining).")
            return i
        end
    end
    error("FATAL: Failed to find suitable buffer memory!")
end

function Memory.CreateHostVisibleBuffer(name, cdef_type, element_count, usage_flags, core_state)
    local vk = core_state.vk
    local byte_size = ffi.sizeof(cdef_type) * element_count

    local bufInfo = ffi.new("VkBufferCreateInfo", {
        sType = vk_struct.buffer_create, size = byte_size, usage = usage_flags, sharingMode = 0
    })
    local pBuffer = ffi.new("VkBuffer[1]")
    assert(vk.vkCreateBuffer(core_state.device, bufInfo, nil, pBuffer) == 0, "FATAL: vkCreateBuffer failed")
    Memory.Buffers[name] = pBuffer[0]

    local memReqs = ffi.new("VkMemoryRequirements")
    vk.vkGetBufferMemoryRequirements(core_state.device, Memory.Buffers[name], memReqs)

    local allocInfo = ffi.new("VkMemoryAllocateInfo", {
        sType = vk_struct.mem_alloc, allocationSize = memReqs.size,
        memoryTypeIndex = FindSmartBufferMemory(vk, core_state.physicalDevice, memReqs.memoryTypeBits)
    })
    local pMemory = ffi.new("VkDeviceMemory[1]")
    assert(vk.vkAllocateMemory(core_state.device, allocInfo, nil, pMemory) == 0)
    Memory.DeviceMemory[name] = pMemory[0]

    assert(vk.vkBindBufferMemory(core_state.device, Memory.Buffers[name], Memory.DeviceMemory[name], 0) == 0)

    local ppData = ffi.new("void*[1]")
    assert(vk.vkMapMemory(core_state.device, Memory.DeviceMemory[name], 0, byte_size, 0, ppData) == 0)

    local ptr_addr = tonumber(ffi.cast("uint64_t", ppData[0]))
    assert(bit.band(ptr_addr, 31) == 0, "FATAL: Vulkan memory is not 32-byte aligned.")

    Memory.Mapped[name] = ffi.cast(cdef_type .. "*", ppData[0])
    print(string.format("[MEMORY] Allocated & Mapped VRAM Buffer: %s (%.2f MB)", name, byte_size / (1024*1024)))
end

function Memory.AllocateSoA(type_str, count, names)
    local base_type = string.gsub(type_str, "%[.-%]", "")
    local byte_size = ffi.sizeof(base_type) * count
    local align_bytes = 32

    for i = 1, #names do
        local raw_ptr = platform_aligned_alloc(align_bytes, byte_size)
        assert(raw_ptr ~= nil, "FATAL: C-Allocator failed to provide aligned memory!")
        Memory.AVX_Arrays[names[i]] = ffi.cast(base_type .. "*", raw_ptr)
        print(string.format("[MEMORY] Allocated Fast CPU RAM: %s (%.2f MB)", names[i], byte_size / (1024*1024)))
    end
end

function Memory.FreeSoA(names)
    for i = 1, #names do
        local ptr = Memory.AVX_Arrays[names[i]]
        if ptr then
            platform_aligned_free(ptr)
            Memory.AVX_Arrays[names[i]] = nil
        end
    end
end

function Memory.DestroyBuffer(name, core_state)
    local vk = core_state.vk
    if Memory.Buffers[name] then vk.vkDestroyBuffer(core_state.device, Memory.Buffers[name], nil) end
    if Memory.DeviceMemory[name] then
        vk.vkUnmapMemory(core_state.device, Memory.DeviceMemory[name])
        vk.vkFreeMemory(core_state.device, Memory.DeviceMemory[name], nil)
    end
end

return Memory
