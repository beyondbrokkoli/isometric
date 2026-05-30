local ffi = require("ffi")

local cfg = require("config_engine")
local reg = require("registry_vk")
local manifest = require("pipeline_manifest")

local seq = {}

seq.boot = {
    {
        name = "Vulkan Instance",
        action = function(ctx)
            local vulkan = require("vulkan_core")
            ctx.vk_runtime = vulkan.create_instance(reg.vk_reqs.instance_ext)
            ffi.cdef("void vx_sys_publish_instance(void* instance);")
            ffi.C.vx_sys_publish_instance(ctx.vk_runtime.instance)
        end
    },
    {
        name = "GLFW Window Boot",
        action = function(ctx)
            print("[WEAVER] Ordering C-Core to Boot GLFW Window...")
            ffi.C.vx_sys_set_cmd(cfg.sys.boot, cfg.win.w, cfg.win.h)
            return "AWAIT_SURFACE"
        end
    },
    {
        name = "Vulkan Logical Device",
        action = function(ctx)
            local vulkan = require("vulkan_core")
            local surface_ptr = ffi.C.vx_sys_get_surface()
            vulkan.finalize_device_and_swapchain(ctx.vk_runtime, surface_ptr, reg.vk_reqs.device_ext)
        end
    },
    {
        name = "Memory Arenas Allocation",
        action = function(ctx)
            local memory = require("memory")
            for _, arena in ipairs(cfg.memory_arenas) do
                memory.CreateHostVisibleBuffer(arena.name, arena.cdef_type, arena.count, arena.usage, ctx.vk_runtime)
            end
        end
    },
    {
        name = "Swapchain Initialization",
        action = function(ctx)
            local swapchain = require("swapchain")
            ctx.sc_state = swapchain.Init(ctx.vk_runtime.vk, ctx.vk_runtime, cfg.win.w, cfg.win.h, ctx.old_swapchain)
        end
    },
    {
        name = "Descriptors Matrix",
        action = function(ctx)
            local descriptors = require("descriptors")
            local memory = require("memory")
            local master_gpu_buffer = memory.Buffers["MASTER_GPU_BLOCK"]
            ctx.desc_state = descriptors.Init(ctx.vk_runtime.vk, ctx.vk_runtime.device, master_gpu_buffer)
        end
    },
    {
        name = "Compute Graph Pipelines",
        action = function(ctx)
            local compute = require("compute_pipeline")
            local layout = ctx.desc_state.pipelineLayout
            ctx.comp_state = compute.Init(ctx.vk_runtime.vk, ctx.vk_runtime.device, layout, manifest.compute)
        end
    },
    {
        name = "Graphics Pipelines & Depth Buffer",
        action = function(ctx)
            local graphics = require("graphics_pipeline")
            local layout = ctx.desc_state.pipelineLayout
            local colorFormat = ctx.sc_state.format
            ctx.gfx_state = graphics.Init(
                ctx.vk_runtime.vk, ctx.vk_runtime, cfg.win.w, cfg.win.h,
                layout, colorFormat, manifest.graphics -- [UPDATED]
            )
        end
    },
    {
        name = "Renderer Synchronization",
        action = function(ctx)
            local renderer = require("renderer")
            ctx.sync_state = renderer.InitSync(ctx.vk_runtime.vk, ctx.vk_runtime.device, cfg.cfg.frame_slots)
        end
    },
    {
        name = "Async Overlord Handoff",
        action = function(ctx)
            print("[WEAVER] Packing C-Core Mailbox and firing Render Thread...")
            local vk, dev = ctx.vk_runtime.vk, ctx.vk_runtime.device
            local sc, sync = ctx.sc_state, ctx.sync_state

            local wsi = ffi.new("RenderThreadInit")
            wsi.device = dev
            wsi.queue = ctx.vk_runtime.queue
            wsi.swapchain = sc.handle

            for i = 0, sc.imageCount - 1 do
                wsi.swapchain_images[i] = ffi.cast("uint64_t", sc.images[i])
                wsi.swapchain_views[i]  = ffi.cast("uint64_t", sc.imageViews[i])
            end

            for i = 0, cfg.cfg.frame_slots - 1 do
                wsi.image_available[i] = sync.imageAvailable[i]
                wsi.render_finished[i] = sync.renderFinished[i]
                wsi.in_flight[i]       = sync.inFlight[i]
            end

            wsi.vkWaitForFences         = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkWaitForFences"))
            wsi.vkAcquireNextImageKHR = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkAcquireNextImageKHR"))
            wsi.vkResetFences           = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkResetFences"))
            wsi.vkQueueSubmit           = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkQueueSubmit"))
            wsi.vkQueuePresentKHR       = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkQueuePresentKHR"))
            wsi.pfnBegin                = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkCmdBeginRenderingKHR"))
            wsi.pfnEnd                  = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkCmdEndRenderingKHR"))
            wsi.pfnSetCullMode          = vk.vkGetDeviceProcAddr(dev, "vkCmdSetCullModeEXT")
            wsi.pfnSetFrontFace         = vk.vkGetDeviceProcAddr(dev, "vkCmdSetFrontFaceEXT")
            wsi.pfnSetPrimitiveTopology = vk.vkGetDeviceProcAddr(dev, "vkCmdSetPrimitiveTopologyEXT")
            wsi.pfnSetDepthTestEnable   = vk.vkGetDeviceProcAddr(dev, "vkCmdSetDepthTestEnableEXT")
            wsi.pfnSetDepthWriteEnable  = vk.vkGetDeviceProcAddr(dev, "vkCmdSetDepthWriteEnableEXT")
            wsi.pfnSetDepthCompareOp    = vk.vkGetDeviceProcAddr(dev, "vkCmdSetDepthCompareOpEXT")

            ffi.cdef[[
                void vx_stream_init(RenderThreadInit* wsi);
                void vx_thread_start();
            ]]

            ffi.C.vx_stream_init(wsi)
            ffi.C.vx_thread_start()
            print("[WEAVER] Engine Initialization Complete. Async Overlord is LIVE.")
        end
    }
}

seq.resize = { seq.boot[5], seq.boot[8], seq.boot[9] }

return seq
