package.path = "./lua/?.lua;" .. package.path
local ffi = require("ffi")
local math = require("math")

-- DECOUPLED IMPORTS
local seq = require("sequence")
local cfg = require("config_engine")
local manifest = require("pipeline_manifest")

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
    RenderPacket* vx_stream_packet(int idx);
    void vx_stream_commit(int idx);
    void vx_thread_kill();
]]

local function sys_sleep(ms)
    if jit.os == "Windows" then ffi.C.Sleep(ms) else ffi.C.usleep(ms * 1000) end
end

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
    for i, stage in ipairs(seq.boot) do
        print(string.format("[WEAVER] Executing Stage %d: %s", i, stage.name))
        local signal = stage.action(ctx)
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
    print("      WEAVER NETWORK INITIALIZATION")
    print("Press [ENTER] to boot as HOST.")
    print("Type any key then [ENTER] to boot as CLIENT.")
    io.write("> ")
    local user_input = io.read("*l")

    local is_host = (user_input == "")
    local my_port = is_host and 27015 or 27016
    local target_port = is_host and 27016 or 27015

    local net = require("network")
    assert(net.Host(my_port), "FATAL: Failed to bind local network port!")
    assert(net.Connect("127.0.0.1", target_port), "FATAL: Failed to set remote target!")

    print(string.format("[NET] Socket Online. Role: %s | Port: %d -> Target: %d\n",
          is_host and "HOST" or "CLIENT", my_port, target_port))

    print("[LUA IO] Booting Headless Weaver (LABORATORY)...")
    local co = coroutine.create(boot_weaver)
    local status, engine_ctx
    while coroutine.status(co) ~= "dead" do
        status, engine_ctx = coroutine.resume(co)
        if not status then error("Fatal Weaver Crash: " .. tostring(engine_ctx)) end
    end

    print("[LUA IO] Weaver sequence complete! Unpacking Context...")

    local vk_rt = engine_ctx.vk_runtime
    local sc = engine_ctx.sc_state
    local desc = engine_ctx.desc_state
    local gfx = engine_ctx.gfx_state
    local sync = engine_ctx.sync_state
    local memory = require("memory")

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

    local spacing = 20.0
    local offset_x = (MAP_WIDTH * spacing) / 2.0
    local offset_z = (MAP_HEIGHT * spacing) / 2.0

    for z = 0, MAP_HEIGHT - 1 do
        for x = 0, MAP_WIDTH - 1 do
            local idx = z * MAP_WIDTH + x
            local world_x = (x * spacing) - offset_x
            local world_z = (z * spacing) - offset_z

            local elevation = math.sin(world_x * 0.02) * math.cos(world_z * 0.02) * 50.0
            local terrain_id = ((x + z) % 2 == 0) and 255 or 0

            rts_grid.elevation[idx] = elevation
            rts_grid.terrain[idx] = terrain_id
        end
    end

    print("[LUA CO] Initializing VRAM Index Buffer with Strict Topology...")
    local index_ptr = ffi.cast("uint32_t*", memory.Mapped["MASTER_INDEX_BLOCK"])

    -- The 24 indices required to construct the 3 visible faces of an isometric block
    -- using the 14-vertex SHAPE_LIBRARY. (Clockwise winding order for front-face culling)
    local iso_indices = ffi.new("uint32_t[24]", {
        -- TOP FACE (Y+)
        0, 2, 3,
        0, 3, 4,
        0, 4, 5,
        0, 5, 2,

        -- LEFT FACE (X-)
        2, 6, 7,
        2, 7, 3,

        -- RIGHT FACE (Z-)
        3, 7, 8,
        3, 8, 4
    })

    -- Instantly copy the correct topological map into VRAM
    ffi.copy(index_ptr, iso_indices, 24 * 4)

    local MAX_DRAW_COMMANDS = 1024
    local render_queues = ffi.new("DrawCommand[?]", MAX_DRAW_COMMANDS * cfg.cfg.frame_slots)

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
    local move_speed = 4000.0

    local total_time = 0.0
    local wants_hotswap = false

    local master_ptr = ffi.cast("float*", memory.Mapped["MASTER_GPU_BLOCK"])
    local active_render_mode = cfg.mode.dual

    local is_resizing = false
    local last_resize_time = get_time_hires()
    local RESIZE_COOLDOWN = 0.25

    local last_time = get_time_hires()
    local accumulator = 0.0
    local TICK_RATE = 60
    local FIXED_DT = 1.0 / TICK_RATE
    local sim_tick_count = 0

    -- DIRECTIVE ZETA: ASYNC TRANSFER DISPATCH
    print("[LUA CO] Packing Data-Driven Color Palette...")

    -- 1. Grab the mapped CPU pointer for the Staging Arena
    local staging_ptr = ffi.cast("float*", memory.Mapped["PALETTE_STAGING"])

    -- 2. Write the Palette (RGBA Floats)
    -- Terrain ID 0: Grass (Green)
    staging_ptr[0] = 0.2; staging_ptr[1] = 0.8; staging_ptr[2] = 0.2; staging_ptr[3] = 1.0;
    -- Terrain ID 255: Stone (Grey)
    staging_ptr[4] = 0.5; staging_ptr[5] = 0.5; staging_ptr[6] = 0.5; staging_ptr[7] = 1.0;

    -- 3. Fire the DMA Transfer (16 KB payload)
    local palette_job_id = memory.TransferAsync("PALETTE_STAGING", "PALETTE_HAVEN", 16384)
    local palette_ready = false

    print("[LUA CO] Entering Deterministic Lockstep Render Loop...")

    -- We define a function for the simulation tick to isolate state logic
    local function update_simulation(grid, dt, tick_count)
        -- In the future, this is where you call ffi.C.vx_math_dispatch_avx2()
        -- For now, we animate the elevation based strictly on the tick_count
        local spacing = 20.0
        local offset_x = (MAP_WIDTH * spacing) / 2.0
        local offset_z = (MAP_HEIGHT * spacing) / 2.0

        -- The terrain animation is now driven by deterministic ticks, NOT frame render time
        local wave_time = tick_count * dt

        for z = 0, MAP_HEIGHT - 1 do
            for x = 0, MAP_WIDTH - 1 do
                local idx = z * MAP_WIDTH + x
                local world_x = (x * spacing) - offset_x
                local world_z = (z * spacing) - offset_z

                grid.elevation[idx] = math.sin(world_x * 0.02 + wave_time) * math.cos(world_z * 0.02 + wave_time) * 50.0
            end
        end
    end

    local gfx_pipeline_module = require("graphics_pipeline");
    local pump_deletion_queue = gfx_pipeline_module.PumpDeletionQueue;

    -- [NEW] Data-Driven Network Payloads
    local PACKET_SIZE = ffi.sizeof("LockstepPacket")
    local in_packet = ffi.new("LockstepPacket")
    local out_packet = ffi.new("LockstepPacket")

    print("[LUA CO] Priming the UDP Lockstep Pump...")
    out_packet.frame_tick = sim_tick_count
    out_packet.player_input = ffi.C.vx_input_wasd()
    net.Send(out_packet, PACKET_SIZE)

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

                    ffi.C.vx_thread_kill()
                    vk_rt.vk.vkDeviceWaitIdle(vk_rt.device)

                    require("graphics_pipeline").Destroy(vk_rt.vk, vk_rt, gfx)
                    require("renderer").Destroy(vk_rt.vk, vk_rt.device, sync, cfg.cfg.frame_slots)

                    cfg.win.w = new_w[0]
                    cfg.win.h = new_h[0]

                    local mini_ctx = {
                        vk_runtime = vk_rt,
                        desc_state = desc,
                        old_swapchain = sc.handle
                    }

                    local resize_co = coroutine.create(function()
                        for _, stage in ipairs(seq.resize) do
                            print(string.format("[MINI-WEAVER] Executing: %s", stage.name))
                            stage.action(mini_ctx)
                        end
                        return mini_ctx
                    end)

                    local status, new_ctx
                    while coroutine.status(resize_co) ~= "dead" do
                        status, new_ctx = coroutine.resume(resize_co)
                        if not status then error("Mini-Weaver Crash: " .. tostring(new_ctx)) end
                    end

                    require("swapchain").Destroy(vk_rt.vk, vk_rt, sc)

                    sc = new_ctx.sc_state
                    gfx = new_ctx.gfx_state
                    sync = new_ctx.sync_state

                    seq.boot[10].action(new_ctx)

                    print("[LUA CO] Mini-Weaver Rebuild Complete.\n")

                    is_resizing = false
                    last_time = get_time_hires()
                else
                    last_resize_time = get_time_hires() - (RESIZE_COOLDOWN * 0.9)
                end
            end
        else
            -- Asynchronous Job Polling
            if not palette_ready and palette_job_id ~= -1 then
                if memory.IsTransferComplete(vk_rt, palette_job_id) then
                    print("[LUA CO] Async Transfer Complete! Palette Haven Online.")
                    palette_ready = true
                    -- In the future, this is where you flip a bit in PushConstants
                    -- to tell the shader: "Hey, the colors are ready, stop using defaults!"
                end
            end

            local current_time = get_time_hires()
            -- Cap frame_time to prevent the "Spiral of Death" if a window drags
            local frame_time = math.max(0.001, math.min(current_time - last_time, 0.25))
            last_time = current_time
            accumulator = accumulator + frame_time

            -- 1. SIMULATION DOMAIN (Strict Determinism)
            while accumulator >= FIXED_DT do

                -- [LOCKSTEP STALL MECHANIC]
                if not net.Poll(in_packet, PACKET_SIZE) then
                    break -- STALL THE ENGINE! Leave accumulator >= FIXED_DT for next frame.
                end

                -- Optional UDP Sanity Check: Ensure we didn't receive an out-of-order packet
                -- if in_packet.frame_tick ~= sim_tick_count then print("UDP Desync!") end

                -- (Future) Apply in_packet.player_input to the opponent's units here

                -- Run your simulation logic
                update_simulation(rts_grid, FIXED_DT, sim_tick_count)

                sim_tick_count = sim_tick_count + 1

                -- Fire off our local state for the NEXT tick to the opponent
                out_packet.frame_tick = sim_tick_count
                out_packet.player_input = ffi.C.vx_input_wasd()
                net.Send(out_packet, PACKET_SIZE)

                accumulator = accumulator - FIXED_DT
            end

            -- [RESTORED] INPUT & CAMERA DOMAIN (Visual Only)
            local last_key = ffi.C.vx_input_last_key()
            if last_key == cfg.key.esc then ffi.C.vx_core_shutdown()
            elseif last_key == cfg.key.f5 then wants_hotswap = true
            elseif last_key == cfg.key.num1 then active_render_mode = cfg.mode.dual
            elseif last_key == cfg.key.num2 then active_render_mode = cfg.mode.geom
            elseif last_key == cfg.key.num3 then active_render_mode = cfg.mode.points
            end

            local wasd = ffi.C.vx_input_wasd()

            -- Use frame_time here for uncapped, smooth local camera movement
            local zoom_speed = move_speed * frame_time * 0.05
            if bit.band(wasd, 16) ~= 0 then ortho_zoom = ortho_zoom - zoom_speed end
            if bit.band(wasd, 32) ~= 0 then ortho_zoom = ortho_zoom + zoom_speed end
            ortho_zoom = math.max(500.0, ortho_zoom)

            local fwd_x = math.sin(cam_yaw)
            local fwd_z = math.cos(cam_yaw)
            local right_x = math.cos(cam_yaw)
            local right_z = -math.sin(cam_yaw)

            local frame_speed = move_speed * frame_time
            if bit.band(wasd, 1) ~= 0 then cam_pos.x = cam_pos.x + fwd_x * frame_speed; cam_pos.z = cam_pos.z + fwd_z * frame_speed end
            if bit.band(wasd, 2) ~= 0 then cam_pos.x = cam_pos.x - fwd_x * frame_speed; cam_pos.z = cam_pos.z - fwd_z * frame_speed end
            if bit.band(wasd, 4) ~= 0 then cam_pos.x = cam_pos.x - right_x * frame_speed; cam_pos.z = cam_pos.z - right_z * frame_speed end
            if bit.band(wasd, 8) ~= 0 then cam_pos.x = cam_pos.x + right_x * frame_speed; cam_pos.z = cam_pos.z + right_z * frame_speed end

            total_time = total_time + frame_time
            pc.total_time = total_time

            -- Camera logic belongs in the render domain for maximum smoothness
            local aspect = sc.extent.width / math.max(1, sc.extent.height)
            vmath.ortho_vk(-ortho_zoom * aspect, ortho_zoom * aspect, -ortho_zoom, ortho_zoom, -10000.0, 10000.0, proj)

            local look_x = math.sin(cam_yaw) * math.cos(cam_pitch)
            local look_y = -math.sin(cam_pitch)
            local look_z = math.cos(cam_yaw) * math.cos(cam_pitch)
            vmath.lookAt(cam_pos.x, cam_pos.y, cam_pos.z, cam_pos.x + look_x, cam_pos.y + look_y, cam_pos.z + look_z, view)

            vmath.multiply_mat4(proj, view, pc.viewProj)

            local write_idx = ffi.C.vx_stream_acquire()

            if write_idx ~= -1 then
                -- Pass alpha to the GPU. The Vertex Shader can use this to lerp
                -- between the previous grid state and current grid state for silky smooth 144hz+ visuals!
                -- RENDER DOMAIN (Interpolated Handoff)
                local alpha = accumulator / FIXED_DT
                -- Pass alpha to the GPU for grid vertex interpolation
                pc.dt = alpha

                local FRAME_BYTES = total_tiles * ffi.sizeof("RtsTileInstance")
                local current_frame_offset = write_idx * FRAME_BYTES
                pc.aos_current_idx = current_frame_offset / 4
                pc.particle_count = total_tiles

                local gpu_ptr = master_ptr + (current_frame_offset / 4)
                local gpu_u32 = ffi.cast("uint32_t*", gpu_ptr)

                local spacing = 20.0
                local offset_x = (MAP_WIDTH * spacing) / 2.0
                local offset_z = (MAP_HEIGHT * spacing) / 2.0

                for z = 0, MAP_HEIGHT - 1 do
                    for x = 0, MAP_WIDTH - 1 do
                        local i = z * MAP_WIDTH + x
                        local out_idx = i * 4

                        gpu_ptr[out_idx + 0] = (x * spacing) - offset_x
                        gpu_ptr[out_idx + 1] = rts_grid.elevation[i]
                        gpu_ptr[out_idx + 2] = (z * spacing) - offset_z

                        local terrain_id = rts_grid.terrain[i]
                        gpu_u32[out_idx + 3] = bit.lshift(terrain_id, 24)
                    end
                end

                local packet = ffi.C.vx_stream_packet(write_idx)
                local current_queue_ptr = render_queues + (write_idx * MAX_DRAW_COMMANDS)

                packet.gfx_layout = ffi.cast("uint64_t", gfx.pipelineLayout)
                packet.vertex_buffer = ffi.cast("uint64_t", memory.Buffers["MASTER_GPU_BLOCK"])
                packet.index_buffer = ffi.cast("uint64_t", memory.Buffers["MASTER_INDEX_BLOCK"])
                packet.depth_image = ffi.cast("uint64_t", gfx.depthImage)
                packet.depth_view = ffi.cast("uint64_t", gfx.depthImageView)
                packet.width = sc.extent.width
                packet.height = sc.extent.height

                local cmd0 = current_queue_ptr[0]
                local geom_cfg = manifest.graphics.geom
                cmd0.pipeline_id = ffi.cast("uint64_t", gfx.pipelines["geom"])
                cmd0.descriptor_set = ffi.cast("uint64_t", desc.set0)
                cmd0.index_count = 24
                cmd0.first_index = 0
                cmd0.vertex_offset = 0
                cmd0.instance_count = total_tiles
                cmd0.first_instance = 0
                cmd0.pc_offset = 0
                cmd0.pc_size = cfg.cfg.pc_size
                ffi.copy(cmd0.push_constants, pc, cfg.cfg.pc_size)
                cmd0.scissor_w = sc.extent.width
                cmd0.scissor_h = sc.extent.height
                cmd0.cull_mode = geom_cfg.cull_mode
                cmd0.front_face = 0
                cmd0.topology = geom_cfg.topology
                cmd0.depth_test = geom_cfg.depth_test
                cmd0.depth_write = geom_cfg.depth_write
                cmd0.depth_compare_op = geom_cfg.depth_compare_op

                local cmd1 = current_queue_ptr[1]
                local points_cfg = manifest.graphics.points
                cmd1.pipeline_id = ffi.cast("uint64_t", gfx.pipelines["points"])
                cmd1.descriptor_set = ffi.cast("uint64_t", desc.set0)
                cmd1.index_count = 1
                cmd1.first_index = 0
                cmd1.vertex_offset = 0
                cmd1.instance_count = total_tiles
                cmd1.first_instance = 0
                cmd1.pc_offset = 0
                cmd1.pc_size = cfg.cfg.pc_size
                ffi.copy(cmd1.push_constants, pc, cfg.cfg.pc_size)

                local pc_points_ptr = ffi.cast("PushConstants*", cmd1.push_constants)
                pc_points_ptr.target_state = cfg.mode.point_cloud_pass

                cmd1.scissor_w = sc.extent.width
                cmd1.scissor_h = sc.extent.height
                cmd1.cull_mode = points_cfg.cull_mode
                cmd1.front_face = 0
                cmd1.topology = points_cfg.topology
                cmd1.depth_test = points_cfg.depth_test
                cmd1.depth_write = points_cfg.depth_write
                cmd1.depth_compare_op = points_cfg.depth_compare_op

                if active_render_mode == cfg.mode.dual then
                    cmd0.first_instance = 0; cmd0.instance_count = total_tiles
                    cmd1.first_instance = 0; cmd1.instance_count = total_tiles
                    packet.draw_queue = current_queue_ptr; packet.draw_count = 2
                elseif active_render_mode == cfg.mode.geom then
                    cmd0.first_instance = 0; cmd0.instance_count = total_tiles
                    packet.draw_queue = current_queue_ptr; packet.draw_count = 1
                elseif active_render_mode == cfg.mode.points then
                    cmd1.first_instance = 0; cmd1.instance_count = total_tiles
                    packet.draw_queue = current_queue_ptr + 1; packet.draw_count = 1
                end

                if wants_hotswap then
                    print("\n[LUA] Initiating Lock-Free Shader Hotswap...")
                    require("graphics_pipeline").HotReloadShaders(vk_rt.vk, vk_rt, gfx, frame_count)
                    wants_hotswap = false
                    print("[LUA] Hotswap Complete. New pipelines active.\n")
                end

                ffi.C.vx_stream_commit(write_idx)
                pump_deletion_queue(vk_rt.vk, vk_rt, frame_count)
                frame_count = frame_count + 1
            end
        end
        sys_sleep(1)
    end

    print("\n[LUA IO] Render Loop Terminated. Commencing Teardown...")
    print("[TEARDOWN] Terminating Async Render Thread and Worker Pool...")
    ffi.C.vx_thread_kill()
    vk_rt.vk.vkDeviceWaitIdle(vk_rt.device)

    require("graphics_pipeline").Destroy(vk_rt.vk, vk_rt, gfx)
    require("compute_pipeline").Destroy(vk_rt.vk, vk_rt, comp)
    require("descriptors").Destroy(vk_rt.vk, vk_rt.device, desc)
    require("swapchain").Destroy(vk_rt.vk, vk_rt, sc)
    require("renderer").Destroy(vk_rt.vk, vk_rt.device, sync, cfg.cfg.frame_slots)

    print("[TEARDOWN] Freeing VRAM and CPU Memory Arenas...")
    memory.DestroyBuffer("MASTER_GPU_BLOCK", vk_rt)
    memory.DestroyBuffer("MASTER_INDEX_BLOCK", vk_rt)

    memory.DestroyBuffer("PALETTE_STAGING", vk_rt)
    memory.DestroyBuffer("PALETTE_HAVEN", vk_rt)
    net.Shutdown() -- [NEW] Close the socket gracefully
    memory.DestroyTransferSubsystem(vk_rt)

    require("vulkan_core").Destroy(vk_rt)

    print("[LUA IO] Teardown Complete. Safe Exit.")
end

main()
ffi.C.vx_core_mark_finished()
