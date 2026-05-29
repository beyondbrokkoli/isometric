package.path = "./lua/?.lua;" .. package.path
local ffi = require("ffi")
local math = require("math")

local bp = require("boilerplate")

-- FFI Definitions needed strictly for the runtime loop
ffi.cdef[[
    void* vx_sys_get_surface();
    void vx_sys_set_cmd(int cmd, int w, int h);
    void Sleep(uint32_t dwMilliseconds);
    int usleep(uint32_t usec);
    int vx_core_is_running();
    void vx_core_shutdown();
    void vx_core_mark_finished();

    // OS Timers
    int QueryPerformanceCounter(int64_t *lpPerformanceCount);
    int QueryPerformanceFrequency(int64_t *lpFrequency);
    typedef struct { long tv_sec; long tv_nsec; } timespec;
    int clock_gettime(int clk_id, timespec *tp);

    // C-Core Runtime Interfaces
    int vx_input_last_key();
    uint32_t vx_input_wasd();
    float vx_input_mouse_dx();
    float vx_input_mouse_dy();
    int vx_sys_resize_flag();
    void vx_sys_window_size(int* w, int* h);
    int vx_input_mouse_btn(int btn);
    int vx_input_spacebar();

    // Ring Buffer Interfaces
    int vx_stream_acquire();
    RenderPacket* vx_stream_packet(int idx);  // <-- ADD THIS BACK
    void vx_stream_commit(int idx);
    void vx_thread_kill();
]]

local function sys_sleep(ms)
    if jit.os == "Windows" then ffi.C.Sleep(ms) else ffi.C.usleep(ms * 1000) end
end

-- HIGH-RESOLUTION KERNEL TIMER SETUP
local get_time_hires
if jit.os == "Windows" then
    local kernel32 = ffi.load("kernel32")
    local freq = ffi.new("int64_t[1]")
    kernel32.QueryPerformanceFrequency(freq)
    local inv_freq = 1.0 / tonumber(freq[0])
    get_time_hires = function()
        local count = ffi.new("int64_t[1]")
        kernel32.QueryPerformanceCounter(count)
        return tonumber(count[0]) * inv_freq
    end
else
    local CLOCK_MONOTONIC = 1
    get_time_hires = function()
        local ts = ffi.new("timespec")
        ffi.C.clock_gettime(CLOCK_MONOTONIC, ts)
        return tonumber(ts.tv_sec) + (tonumber(ts.tv_nsec) * 1e-9)
    end
end

local function boot_weaver()
    local ctx = {}
    for i, stage in ipairs(bp.sequence) do
        print(string.format("[WEAVER] Executing Stage %d: %s", i, stage.name))
        local signal = stage.action(ctx, bp)
        if signal == "AWAIT_SURFACE" then
            print("[WEAVER] Yielding execution, waiting for C-Core Surface...")
            while ffi.C.vx_sys_get_surface() == nil do
                sys_sleep(10)
                coroutine.yield()
            end
        end
    end
    return ctx
end

local function main()
    print("[LUA IO] Booting Headless Weaver (LABORATORY)...")

    local co = coroutine.create(boot_weaver)
    local status, engine_ctx
    while coroutine.status(co) ~= "dead" do
        status, engine_ctx = coroutine.resume(co)
        if not status then error("Fatal Weaver Crash: " .. tostring(engine_ctx)) end
    end

    print("[LUA IO] Weaver sequence complete! Unpacking God Object...")

    -- 1. The Context Bridge
    local vk_rt = engine_ctx.vk_runtime
    local sc = engine_ctx.sc_state
    local desc = engine_ctx.desc_state
    local comp = engine_ctx.comp_state
    local gfx = engine_ctx.gfx_state
    local sync = engine_ctx.sync_state -- THE LEAK FIX!
    local memory = require("memory") -- We need this to allocate our CPU RAM

    print("[LUA CO] Forging Data-Driven Pizza World Tilemap...")

    local MAP_WIDTH = 256
    local MAP_HEIGHT = 256
    local total_tiles = MAP_WIDTH * MAP_HEIGHT

    memory.AllocateSoA("uint16_t", total_tiles, {"terrain_id", "elevation", "entity_id"})

    local rts_grid = {
        terrain = memory.AVX_Arrays["terrain_id"],
        elevation = memory.AVX_Arrays["elevation"],
        entity = memory.AVX_Arrays["entity_id"]
    }

    -- [NEW] Populate the Logical Grid SSoT!
    local spacing = 20.0
    local offset_x = (MAP_WIDTH * spacing) / 2.0
    local offset_z = (MAP_HEIGHT * spacing) / 2.0

    for z = 0, MAP_HEIGHT - 1 do
        for x = 0, MAP_WIDTH - 1 do
            local idx = z * MAP_WIDTH + x
            local world_x = (x * spacing) - offset_x
            local world_z = (z * spacing) - offset_z

            -- Gentle rolling hills
            local elevation = math.sin(world_x * 0.02) * math.cos(world_z * 0.02) * 50.0

            -- Checkerboard pattern (Alternating 0 and 255)
            local terrain_id = ((x + z) % 2 == 0) and 255 or 0

            rts_grid.elevation[idx] = elevation
            rts_grid.terrain[idx] = terrain_id
        end
    end

    -- 6. Runtime State Initialization
    local MAX_DRAW_COMMANDS = 1024
    local render_queues = ffi.new("DrawCommand[?]", MAX_DRAW_COMMANDS * bp.cfg.frame_slots)

    local frame_count = 0
    local vmath = require("vmath")

    local pc = ffi.new("PushConstants")
    pc.soa_upload_idx, pc.aos_current_idx, pc.aos_prev_idx = 0, 0, 0
    pc.particle_count = total_tiles
    pc.dt = 0.0

    local proj, view = ffi.new("mat4_t"), ffi.new("mat4_t")
    local ortho_zoom = 5000.0
    local cam_yaw, cam_pitch = 0.785398, 0.615472
    local cam_pos = {x = 0.0, y = 0.0, z = 0.0}
    local move_speed = 320000.0

    local last_time = get_time_hires()
    local total_time = 0.0
    local wants_hotswap = false

    local master_ptr = ffi.cast("float*", memory.Mapped["MASTER_GPU_BLOCK"])

    local active_render_mode = bp.mode.dual

    local is_resizing = false
    local last_resize_time = get_time_hires()
    local RESIZE_COOLDOWN = 0.25

    -- [NEW] Declare ortho_zoom outside the render loop
    local ortho_zoom = 5000.0

    print("[LUA CO] Entering Data-Driven Render Loop...")
    local gfx_pipeline_module = require("graphics_pipeline");
    local pump_deletion_queue = gfx_pipeline_module.PumpDeletionQueue;

    while ffi.C.vx_core_is_running() == 1 do

        if ffi.C.vx_sys_resize_flag() == 1 then
            is_resizing = true
            last_resize_time = get_time_hires()
        end

        if is_resizing then
            if (get_time_hires() - last_resize_time) > RESIZE_COOLDOWN then
                local new_w, new_h = ffi.new("int[1]"), ffi.new("int[1]")
                ffi.C.vx_sys_window_size(new_w, new_h)

                if new_w[0] > 0 and new_h[0] > 0 then
                    print("\n[LUA CO] Window Stable. Initiating Mini-Weaver Rebuild...")

                    -- 1. Halt the Async Overlord
                    ffi.C.vx_thread_kill()
                    vk_rt.vk.vkDeviceWaitIdle(vk_rt.device)

                    -- 2. Teardown old state (Wait to destroy swapchain until the new one is built)
                    require("graphics_pipeline").Destroy(vk_rt.vk, vk_rt, gfx)
                    require("renderer").Destroy(vk_rt.vk, vk_rt.device, sync, bp.cfg.frame_slots)

                    -- 3. Update the Boilerplate Policy with new dimensions
                    bp.win.w = new_w[0]
                    bp.win.h = new_h[0]

                    -- 4. Seed the Mini-Weaver Context
                    local mini_ctx = {
                        vk_runtime = vk_rt,
                        desc_state = desc,        -- Needed by Graphics Pipeline for layout
                        old_swapchain = sc.handle -- Vital for smooth Vulkan handoff!
                    }

                    -- 5. Execute the Mini-Weaver Coroutine
                    local resize_co = coroutine.create(function()
                        for _, stage in ipairs(bp.resize_sequence) do
                            print(string.format("[MINI-WEAVER] Executing: %s", stage.name))
                            stage.action(mini_ctx, bp)
                        end
                        return mini_ctx
                    end)

                    local status, new_ctx
                    while coroutine.status(resize_co) ~= "dead" do
                        status, new_ctx = coroutine.resume(resize_co)
                        if not status then error("Mini-Weaver Crash: " .. tostring(new_ctx)) end
                    end

                    -- 6. Clean up the old swapchain now that the driver has transitioned
                    require("swapchain").Destroy(vk_rt.vk, vk_rt, sc)

                    -- 7. Overwrite our hot-loop variables with the freshly woven state
                    sc = new_ctx.sc_state
                    gfx = new_ctx.gfx_state
                    sync = new_ctx.sync_state

                    -- 8. Fire the C-Core back up by explicitly invoking Stage 9!
                    bp.sequence[9].action(new_ctx, bp)

                    print("[LUA CO] Mini-Weaver Rebuild Complete.\n")

                    is_resizing = false
                    last_time = get_time_hires()
                else
                    last_resize_time = get_time_hires() - (RESIZE_COOLDOWN * 0.9)
                end
            end

        else

            local current_time = get_time_hires()
            local dt = math.max(0.001, math.min(current_time - last_time, 0.033))
            last_time = current_time

            local dx = ffi.C.vx_input_mouse_dx()
            local dy = ffi.C.vx_input_mouse_dy()
            local wasd = ffi.C.vx_input_wasd()

            -- 1. Strict Orthographic Zoom (Q/E)
            local zoom_speed = move_speed * dt * 0.05
            if bit.band(wasd, 16) ~= 0 then ortho_zoom = ortho_zoom - zoom_speed end
            if bit.band(wasd, 32) ~= 0 then ortho_zoom = ortho_zoom + zoom_speed end
            ortho_zoom = math.max(500.0, ortho_zoom)

            local aspect = sc.extent.width / math.max(1, sc.extent.height)
            vmath.ortho_vk(-ortho_zoom * aspect, ortho_zoom * aspect, -ortho_zoom, ortho_zoom, -10000.0, 10000.0, proj)

            -- 2. Locked Isometric Angles
            local cam_yaw = 0.785398   -- 45 degrees
            local cam_pitch = 0.615472 -- 35.264 degrees

            -- 3. Planar Movement Vectors (X/Z only)
            local fwd_x = math.sin(cam_yaw)
            local fwd_z = math.cos(cam_yaw)
            local right_x = math.cos(cam_yaw)
            local right_z = -math.sin(cam_yaw)

            local frame_speed = move_speed * dt
            if bit.band(wasd, 1) ~= 0 then cam_pos.x = cam_pos.x + fwd_x * frame_speed; cam_pos.z = cam_pos.z + fwd_z * frame_speed end
            if bit.band(wasd, 2) ~= 0 then cam_pos.x = cam_pos.x - fwd_x * frame_speed; cam_pos.z = cam_pos.z - fwd_z * frame_speed end
            if bit.band(wasd, 4) ~= 0 then cam_pos.x = cam_pos.x - right_x * frame_speed; cam_pos.z = cam_pos.z - right_z * frame_speed end
            if bit.band(wasd, 8) ~= 0 then cam_pos.x = cam_pos.x + right_x * frame_speed; cam_pos.z = cam_pos.z + right_z * frame_speed end

            -- 4. Locked Look Vector
            local look_x = math.sin(cam_yaw) * math.cos(cam_pitch)
            local look_y = -math.sin(cam_pitch)
            local look_z = math.cos(cam_yaw) * math.cos(cam_pitch)

            vmath.lookAt(cam_pos.x, cam_pos.y, cam_pos.z, cam_pos.x + look_x, cam_pos.y + look_y, cam_pos.z + look_z, view)

            -- Time & Matrix pushes
            pc.dt = pc.dt + dt
            total_time = total_time + dt
            pc.total_time = total_time

            vmath.multiply_mat4(proj, view, pc.viewProj)

            local last_key = ffi.C.vx_input_last_key()
            if last_key == bp.key.esc then ffi.C.vx_core_shutdown()
            elseif last_key == bp.key.f5 then wants_hotswap = true
            elseif last_key == bp.key.num1 then active_render_mode = bp.mode.dual
            elseif last_key == bp.key.num2 then active_render_mode = bp.mode.geom
            elseif last_key == bp.key.num3 then active_render_mode = bp.mode.points
            end

            local write_idx = ffi.C.vx_stream_acquire()
            if write_idx ~= -1 then
                -- 1. Calculate GPU memory offsets
                local FRAME_BYTES = total_tiles * ffi.sizeof("RtsTileInstance")
                local current_frame_offset = write_idx * FRAME_BYTES

                -- Point GLSL to this frame's memory
                pc.aos_current_idx = current_frame_offset / 4 -- index in uint32_t words
                pc.particle_count = total_tiles

                -- 2. Stream the RTS Logical Grid -> GPU AoS Buffer
                -- We do this in Lua for rapid prototyping, translating SoA to AoS
                local gpu_ptr = ffi.cast("float*", master_ptr + current_frame_offset)
                local gpu_u32 = ffi.cast("uint32_t*", gpu_ptr)

                local spacing = 20.0
                local offset_x = (MAP_WIDTH * spacing) / 2.0
                local offset_z = (MAP_HEIGHT * spacing) / 2.0

                for z = 0, MAP_HEIGHT - 1 do
                    for x = 0, MAP_WIDTH - 1 do
                        local i = z * MAP_WIDTH + x
                        local out_idx = i * 4 -- 4 words per RtsTileInstance

                        -- Write Position (px, py, pz)
                        gpu_ptr[out_idx + 0] = (x * spacing) - offset_x
                        gpu_ptr[out_idx + 1] = rts_grid.elevation[i] -- Height from our SSoT!
                        gpu_ptr[out_idx + 2] = (z * spacing) - offset_z

                        -- Pack Tile Data: [8-bit Terrain ID] [8-bit Variant] [16-bit Flags]
                        local terrain_id = rts_grid.terrain[i]
                        gpu_u32[out_idx + 3] = bit.lshift(terrain_id, 24)
                    end
                end

                local packet = ffi.C.vx_stream_packet(write_idx)
                local current_queue_ptr = render_queues + (write_idx * MAX_DRAW_COMMANDS)

                -- Bind graphics
                packet.gfx_layout = ffi.cast("uint64_t", gfx.pipelineLayout)
                packet.vertex_buffer = ffi.cast("uint64_t", memory.Buffers["MASTER_GPU_BLOCK"])
                packet.index_buffer = ffi.cast("uint64_t", memory.Buffers["MASTER_INDEX_BLOCK"])
                packet.depth_image = ffi.cast("uint64_t", gfx.depthImage)
                packet.depth_view = ffi.cast("uint64_t", gfx.depthImageView)
                packet.width = sc.extent.width
                packet.height = sc.extent.height

                -- Render Geometry Pass (From Boilerplate)
                local cmd0 = current_queue_ptr[0]
                local geom_cfg = bp.graphics_pipelines.geom
                cmd0.pipeline_id = ffi.cast("uint64_t", gfx.pipelines["geom"])
                cmd0.descriptor_set = ffi.cast("uint64_t", desc.set0)
                cmd0.index_count = 24
                cmd0.first_index = 0
                cmd0.vertex_offset = 0
                cmd0.instance_count = total_tiles
                cmd0.first_instance = 0
                cmd0.pc_offset = 0
                cmd0.pc_size = bp.cfg.pc_size
                ffi.copy(cmd0.push_constants, pc, bp.cfg.pc_size)
                cmd0.scissor_w = sc.extent.width
                cmd0.scissor_h = sc.extent.height
                cmd0.cull_mode = geom_cfg.cull_mode
                cmd0.front_face = 0
                cmd0.topology = geom_cfg.topology
                cmd0.depth_test = geom_cfg.depth_test
                cmd0.depth_write = geom_cfg.depth_write
                -- REPLACE cmd0.depth_compare_op = 4 WITH:
                cmd0.depth_compare_op = geom_cfg.depth_compare_op

                -- Render Points Pass (Now acts as a Topological Debug View!)
                local cmd1 = current_queue_ptr[1]
                local points_cfg = bp.graphics_pipelines.points
                cmd1.pipeline_id = ffi.cast("uint64_t", gfx.pipelines["points"])
                cmd1.descriptor_set = ffi.cast("uint64_t", desc.set0)
                cmd1.index_count = 1
                cmd1.first_index = 0
                cmd1.vertex_offset = 0
                cmd1.instance_count = total_tiles -- [EXPLICIT]
                cmd1.first_instance = 0
                cmd1.pc_offset = 0
                cmd1.pc_size = bp.cfg.pc_size
                ffi.copy(cmd1.push_constants, pc, bp.cfg.pc_size)

                local pc_points_ptr = ffi.cast("PushConstants*", cmd1.push_constants)
                pc_points_ptr.target_state = bp.mode.point_cloud_pass

                cmd1.scissor_w = sc.extent.width
                cmd1.scissor_h = sc.extent.height
                cmd1.cull_mode = points_cfg.cull_mode
                cmd1.front_face = 0
                cmd1.topology = points_cfg.topology
                cmd1.depth_test = points_cfg.depth_test
                cmd1.depth_write = points_cfg.depth_write
                cmd1.depth_compare_op = points_cfg.depth_compare_op

                -- Dynamic Render Mode Routing
                if active_render_mode == bp.mode.dual then
                    cmd0.first_instance = 0
                    cmd0.instance_count = total_tiles -- [EXPLICIT]
                    cmd1.first_instance = 0
                    cmd1.instance_count = total_tiles -- [EXPLICIT]

                    packet.draw_queue = current_queue_ptr
                    packet.draw_count = 2

                elseif active_render_mode == bp.mode.geom then
                    cmd0.first_instance = 0
                    cmd0.instance_count = total_tiles -- [EXPLICIT]

                    packet.draw_queue = current_queue_ptr
                    packet.draw_count = 1

                elseif active_render_mode == bp.mode.points then
                    cmd1.first_instance = 0
                    cmd1.instance_count = total_tiles -- [EXPLICIT]

                    -- Shift the C-pointer forward by 1 so the C-Core only reads cmd1
                    packet.draw_queue = current_queue_ptr + 1
                    packet.draw_count = 1
                end

                if wants_hotswap then
                    print("\n[LUA] Initiating Lock-Free Shader Hotswap...")
                    -- Recompile shaders and push old pipelines into the garbage collector ring
                    require("graphics_pipeline").HotReloadShaders(vk_rt.vk, vk_rt, gfx, frame_count)
                    wants_hotswap = false
                    print("[LUA] Hotswap Complete. New pipelines active.\n")
                end

                ffi.C.vx_stream_commit(write_idx)

                pump_deletion_queue(vk_rt.vk, vk_rt, frame_count)

                frame_count = frame_count + 1
            end -- End of if write_idx ~= -1
        end
        sys_sleep(10)
    end

    print("\n[LUA IO] Render Loop Terminated. Commencing Teardown...")

    -- 1. Halt the Async Overlord and Math Workers
    print("[TEARDOWN] Terminating Async Render Thread and Worker Pool...")
    ffi.C.vx_thread_kill()

    -- 2. Wait for the GPU to finish its current queue
    vk_rt.vk.vkDeviceWaitIdle(vk_rt.device)

    -- 3. Dismantle the Data-Driven Pipelines (Reverse Order of Creation)
    require("graphics_pipeline").Destroy(vk_rt.vk, vk_rt, gfx)
    require("descriptors").Destroy(vk_rt.vk, vk_rt.device, desc)
    require("swapchain").Destroy(vk_rt.vk, vk_rt, sc)
    require("renderer").Destroy(vk_rt.vk, vk_rt.device, sync, bp.cfg.frame_slots)

    -- 4. Free Memory Arenas (VRAM & CPU RAM)
    print("[TEARDOWN] Freeing VRAM and CPU Memory Arenas...")
    memory.DestroyBuffer("MASTER_GPU_BLOCK", vk_rt)
    memory.DestroyBuffer("MASTER_INDEX_BLOCK", vk_rt)

    -- 5. Nuke the Vulkan Instance
    require("vulkan_core").Destroy(vk_rt)

    print("[LUA IO] Teardown Complete. Safe Exit.")
end

main()
ffi.C.vx_core_mark_finished()
