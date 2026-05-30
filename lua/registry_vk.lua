local ffi = require("ffi")
require("vulkan_headers")

local reg = {
    vk_queue = { graphics = 1, compute = 2, transfer = 4 },
    vk_struct = {
        app_info = 0, instance_create = 1, device_queue_create = 2, device_create = 3,
        mem_alloc = 5, fence_create = 8, semaphore_create = 9, buffer_create = 12,
        image_create = 14, image_view_create = 15, shader_module_create = 16,
        pipeline_shader_stage_create = 18, pipeline_vertex_input_state_create = 19,
        pipeline_input_assembly_state_create = 20, pipeline_viewport_state_create = 22,
        pipeline_rasterization_state_create = 23, pipeline_multisample_state_create = 24,
        pipeline_depth_stencil_state_create = 25, pipeline_color_blend_state_create = 26,
        pipeline_dynamic_state_create = 27, graphics_pipeline_create = 28, compute_pipeline_create = 29,
        pipeline_layout_create = 30, desc_set_layout_create = 32, desc_pool_create = 33,
        desc_set_alloc = 34, write_desc_set = 35, command_buffer_begin = 42,
        image_memory_barrier = 45, memory_barrier = 46, submit_info = 4,
        rendering_info = 1000044000, rendering_attachment_info = 1000044001,
        pipeline_rendering_create = 1000044002, dynamic_rendering_features = 1000044003,
        extended_dynamic_state_features = 1000267000, extended_dynamic_state2_features = 1000377000,
        swapchain_create = 1000001000, present_info = 1000001001,
    },
    vk_result = { success = 0, error_out_of_date = -1000000001 },
    vk_format = { b8g8r8a8_srgb = 50, d32_sfloat = 126 },
    vk_image = { view_type_2d = 1, type_2d = 1, tiling_optimal = 0, usage_color_attachment = 16, usage_depth_attachment = 32, aspect_color = 1, aspect_depth = 2, sample_count_1 = 1 },
    vk_layout = { undefined = 0, color_attachment_optimal = 2, depth_attachment_optimal = 3, present_src = 1000001002 },
    vk_swapchain = { color_space_srgb_nonlinear = 0, composite_alpha_opaque = 1, present_mode_fifo = 2 },
    vk_state = { cull_none = 0, front_ccw = 0, topo_point = 0, topo_tri = 3, cmp_le = 3, cmp_ge = 4, depth_off = 0, depth_on = 1 },
    vk_pipeline = { poly_mode_fill = 0, cull_back = 1, face_ccw = 0, blend_src_alpha = 6, blend_one = 1, color_mask_rgba = 15 },
    vk_dynamic = { viewport = 0, scissor = 1, cull_mode_ext = 1000267000, front_face_ext = 1000267001, primitive_topo_ext = 1000267002, depth_test_ext = 1000267006, depth_write_ext = 1000267007, depth_compare_op_ext = 1000267008 },
    vk_shader_stage = { vert = 1, frag = 16, comp = 32 },
    vk_desc = { ssbo = 7 },
    vk_mem = { device_local = 1, host_visible = 2, host_coherent = 4, host_cached = 8 },
    vk_reqs = {
        instance_ext = { "VK_KHR_get_physical_device_properties2" },
        device_ext = {
            "VK_KHR_swapchain", "VK_KHR_dynamic_rendering", "VK_KHR_depth_stencil_resolve",
            "VK_KHR_create_renderpass2", "VK_KHR_multiview", "VK_KHR_maintenance2",
            "VK_EXT_extended_dynamic_state", "VK_EXT_extended_dynamic_state2"
        }
    },
    -- [RESTORED] Vulkan Host Interface
    c_vk_structs = [[
        typedef struct {
            VkDevice device; VkQueue queue; VkQueue transfer_queue; VkSwapchainKHR swapchain;
            uint64_t swapchain_images[10]; uint64_t swapchain_views[10];
            VkSemaphore image_available[10]; VkSemaphore render_finished[10];
            VkFence in_flight[10]; void* vkWaitForFences; void* vkAcquireNextImageKHR;
            void* vkResetFences; void* vkQueueSubmit; void* vkQueuePresentKHR;
            void* pfnBegin; void* pfnEnd; void* pfnSetCullMode; void* pfnSetFrontFace;
            void* pfnSetPrimitiveTopology; void* pfnSetDepthTestEnable;
            void* pfnSetDepthWriteEnable; void* pfnSetDepthCompareOp;
        } RenderThreadInit;
    ]],
    -- [NEW] Data-Driven Schema
    structs = {
        {
            name = "mat4_t", glsl = "mat4", align = 16,
            members = { { type = "float", name = "m", count = 16 } }
        },
        {
            name = "RtsTileInstance", glsl = "RtsTileInstance", align = 16,
            members = {
                { type = "float", name = "px" },
                { type = "float", name = "py" },
                { type = "float", name = "pz" },
                { type = "uint32_t", name = "tile_data" }
            }
        },
        {
            name = "PushConstants", glsl = "PushConstants", align = 16,
            members = {
                { type = "mat4_t", name = "viewProj" },
                { type = "uint32_t", name = "soa_upload_idx" },
                { type = "uint32_t", name = "aos_current_idx" },
                { type = "uint32_t", name = "aos_prev_idx" },
                { type = "uint32_t", name = "particle_count" },
                { type = "float", name = "dt" },
                { type = "float", name = "total_time" },
                { type = "uint32_t", name = "target_state" }
            }
        },
        {
            name = "DrawCommand", c_only = true, align = 8,
            members = {
                { type = "uint64_t", name = "pipeline_id" },
                { type = "uint64_t", name = "descriptor_set" },
                { type = "uint32_t", name = "index_count" },
                { type = "uint32_t", name = "instance_count" },
                { type = "uint32_t", name = "first_index" },
                { type = "int32_t", name = "vertex_offset" },
                { type = "uint32_t", name = "first_instance" },
                { type = "uint16_t", name = "pc_offset" },
                { type = "uint16_t", name = "pc_size" },
                { type = "uint8_t", name = "push_constants", count = 128 },
                { type = "int16_t", name = "scissor_x" },
                { type = "int16_t", name = "scissor_y" },
                { type = "uint16_t", name = "scissor_w" },
                { type = "uint16_t", name = "scissor_h" },
                { type = "uint8_t", name = "cull_mode" },
                { type = "uint8_t", name = "depth_test" },
                { type = "uint8_t", name = "depth_write" },
                { type = "uint8_t", name = "depth_compare_op" },
                { type = "uint8_t", name = "front_face" },
                { type = "uint8_t", name = "topology" }
            }
        },
        {
            name = "RenderPacket", c_only = true, align = 64, force_align = true,
            members = {
                { type = "DrawCommand*", name = "draw_queue" },
                { type = "uint32_t", name = "draw_count" },
                { type = "uint64_t", name = "gfx_layout" },
                { type = "uint64_t", name = "vertex_buffer" },
                { type = "uint64_t", name = "index_buffer" },
                { type = "uint64_t", name = "swapchain_image" },
                { type = "uint64_t", name = "swapchain_view" },
                { type = "uint64_t", name = "depth_image" },
                { type = "uint64_t", name = "depth_view" },
                { type = "uint32_t", name = "width" },
                { type = "uint32_t", name = "height" }
            }
        }
    }
}

-- [NEW] Dynamic FFI Bootstrapper
local function get_base_size(type_str)
    if string.find(type_str, "64") or string.find(type_str, "*") then return 8 end
    if string.find(type_str, "32") or type_str == "float" then return 4 end
    if string.find(type_str, "16") then return 2 end
    if string.find(type_str, "8") then return 1 end
    return 64 -- mat4_t fallback
end

local cdef_builder = ""
for _, struct in ipairs(reg.structs) do
    local attr = struct.force_align and "__attribute__((packed, aligned("..struct.align..")))" or "__attribute__((packed))"
    cdef_builder = cdef_builder .. string.format("typedef struct %s {\n", attr)

    local offset = 0
    local pad_id = 0
    for _, m in ipairs(struct.members) do
        local m_size = get_base_size(m.type)

        -- Strict Padding Injection (FFI Side)
        local rem = offset % m_size
        if rem ~= 0 then
            local pad_bytes = m_size - rem
            cdef_builder = cdef_builder .. string.format("    uint8_t _pad_%d[%d];\n", pad_id, pad_bytes)
            offset = offset + pad_bytes
            pad_id = pad_id + 1
        end

        local arr = m.count and string.format("[%d]", m.count) or ""
        cdef_builder = cdef_builder .. string.format("    %s %s%s;\n", m.type, m.name, arr)
        offset = offset + (m_size * (m.count or 1))
    end

    -- Tail padding for struct alignment
    local tail_rem = offset % struct.align
    if tail_rem ~= 0 then
        local tail_pad = struct.align - tail_rem
        cdef_builder = cdef_builder .. string.format("    uint8_t _pad_tail[%d];\n", tail_pad)
    end

    cdef_builder = cdef_builder .. "} " .. struct.name .. ";\n\n"
end

-- Append the raw Vulkan interfaces for FFI parsing
cdef_builder = cdef_builder .. reg.c_vk_structs
ffi.cdef(cdef_builder)

return reg
