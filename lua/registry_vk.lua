local ffi = require("ffi")
require("vulkan_headers") -- [NEW] Teach FFI what a VkDevice is before parsing!

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
    c_math_structs = [[
        typedef struct { float m[16]; } mat4_t;
        typedef struct { float px, py, pz; uint32_t tile_data; } RtsTileInstance;
        typedef struct {
            mat4_t viewProj; uint32_t soa_upload_idx; uint32_t aos_current_idx;
            uint32_t aos_prev_idx; uint32_t particle_count; float dt;
            float total_time; uint32_t target_state;
        } PushConstants;
        typedef struct {
            uint64_t pipeline_id; uint64_t descriptor_set; uint32_t index_count;
            uint32_t instance_count; uint32_t first_index; int32_t vertex_offset;
            uint32_t first_instance; uint16_t pc_offset; uint16_t pc_size;
            uint8_t push_constants[128]; int16_t scissor_x; int16_t scissor_y;
            uint16_t scissor_w; uint16_t scissor_h; uint8_t cull_mode;
            uint8_t depth_test; uint8_t depth_write; uint8_t depth_compare_op;
            uint8_t front_face; uint8_t topology; uint8_t _reserved[10];
        } DrawCommand;
        typedef struct __attribute__((packed, aligned(64))) {
            DrawCommand* draw_queue; uint32_t draw_count; uint32_t _pad_draw[3];
            uint64_t gfx_layout; uint64_t vertex_buffer; uint64_t index_buffer;
            uint64_t swapchain_image; uint64_t swapchain_view; uint64_t depth_image;
            uint64_t depth_view; uint32_t width; uint32_t height; uint8_t _padding[32];
        } RenderPacket;
    ]],
    c_vk_structs = [[
        typedef struct {
            VkDevice device; VkQueue queue; VkSwapchainKHR swapchain;
            uint64_t swapchain_images[10]; uint64_t swapchain_views[10];
            VkSemaphore image_available[10]; VkSemaphore render_finished[10];
            VkFence in_flight[10]; void* vkWaitForFences; void* vkAcquireNextImageKHR;
            void* vkResetFences; void* vkQueueSubmit; void* vkQueuePresentKHR;
            void* pfnBegin; void* pfnEnd; void* pfnSetCullMode; void* pfnSetFrontFace;
            void* pfnSetPrimitiveTopology; void* pfnSetDepthTestEnable;
            void* pfnSetDepthWriteEnable; void* pfnSetDepthCompareOp;
        } RenderThreadInit;
    ]]
}

ffi.cdef(reg.c_math_structs)
ffi.cdef(reg.c_vk_structs)

return reg
