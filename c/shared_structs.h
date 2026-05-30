// AUTO-GENERATED FROM registry_export.lua
#pragma once
#include <stdint.h>

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
    

#ifdef VX_ENABLE_VULKAN_STRUCTS
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
    
#endif // VX_ENABLE_VULKAN_STRUCTS
