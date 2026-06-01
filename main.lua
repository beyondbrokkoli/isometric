package.path = "./lua/?.lua;" .. package.path
local ffi = require("ffi")
local math = require("math")
local bit = require("bit")

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

    float vx_input_mouse_x();
    float vx_input_mouse_y();
    float vx_input_click_x();
    float vx_input_click_y();
    int vx_input_is_captured();

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

    -- Subtractive Cleanup: Flatten the Pizza World into a true testing tabletop
    for z = 0, MAP_HEIGHT - 1 do
        for x = 0, MAP_WIDTH - 1 do
            local idx = z * MAP_WIDTH + x
            rts_grid.elevation[idx] = 0.0 -- Perfect flat baseline
            rts_grid.terrain[idx] = 0     -- Uniform grass canvas
        end
    end

    print("[LUA CO] Initializing VRAM Index Buffer with Strict Topology...")
    local index_ptr = ffi.cast("uint32_t*", memory.Mapped["MASTER_INDEX_BLOCK"])

    -- Expanded from 24 to 36 indices to close the back walls
    local iso_indices = ffi.new("uint32_t[36]", {
        -- TOP PYRAMID ROOF
        0, 2, 3,
        0, 3, 4,
        0, 4, 5,
        0, 5, 2,
        -- WALL 1 (South-West)
        2, 6, 7,
        2, 7, 3,
        -- WALL 2 (South-East)  <-- FIX: Index 8 replaced with 11
        3, 7, 11,
        3, 11, 4,
        -- WALL 3 (North-East)  <-- NEW: Encloses the back
        4, 11, 10,
        4, 10, 5,
        -- WALL 4 (North-West)  <-- NEW: Encloses the back
        5, 10, 6,
        5, 6, 2
    })

    -- Increase the copy size to match 36 indices (36 * 4 bytes)
    ffi.copy(index_ptr, iso_indices, 36 * 4)

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

    -- Terrain ID 1: Local Player (Blue)
    staging_ptr[4] = 0.2; staging_ptr[5] = 0.5; staging_ptr[6] = 1.0; staging_ptr[7] = 1.0;

    -- Terrain ID 2: Remote Player (Red)
    staging_ptr[8] = 1.0; staging_ptr[9] = 0.2; staging_ptr[10] = 0.2; staging_ptr[11] = 1.0;

    -- Terrain ID 255: Stone (Grey) -> Note: ID 255 is offset 255 * 4 = 1020
    staging_ptr[1020] = 0.5; staging_ptr[1021] = 0.5; staging_ptr[1022] = 0.5; staging_ptr[1023] = 1.0;
    -- 3. Fire the DMA Transfer (16 KB payload)
    local palette_job_id = memory.TransferAsync("PALETTE_STAGING", "PALETTE_HAVEN", 16384)
    local palette_ready = false

    -- [NEW] Map the ID Harvesting Mailbox
    local pick_ptr = ffi.cast("uint32_t*", memory.Mapped["PICK_BUFFER"])
    pick_ptr[0] = 0xFFFFFFFF
    local pick_countdown = 0 -- [NEW]

    print("[LUA CO] Entering Deterministic Lockstep Render Loop...")

    -- Replace your old function with this to turn the grid into a static canvas
    local function update_simulation(grid, dt, tick_count)
        -- No more sine waves or terrain overwrites!
        -- The terrain is entirely driven by player input now.
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

    -- Spawn coordinates for our lockstep entities
    local local_avatar = {
        x = is_host and 64 or 192,
        z = is_host and 64 or 192,
        id = 1 -- Always Blue locally
    }

    local remote_avatar = {
        x = is_host and 192 or 64,
        z = is_host and 192 or 64,
        id = 2 -- Always Red remotely
    }

    local function apply_locomotion(grid, avatar, input_mask, tick_count)
        -- Throttle movement to 10 tiles per second
        if tick_count % 6 ~= 0 then return end
        if input_mask == 0 then return end

        -- 1. Erase the old footprint (Restore to Grass)
        local old_idx = avatar.z * MAP_WIDTH + avatar.x
        grid.terrain[old_idx] = 0
        grid.elevation[old_idx] = 0.0 -- FIX: Smashes the old tile back flat

        -- 2. Decode the Bitmask (W=1, S=2, A=4, D=8)
        if bit.band(input_mask, 1) ~= 0 then avatar.z = avatar.z - 1 end
        if bit.band(input_mask, 2) ~= 0 then avatar.z = avatar.z + 1 end
        if bit.band(input_mask, 4) ~= 0 then avatar.x = avatar.x - 1 end
        if bit.band(input_mask, 8) ~= 0 then avatar.x = avatar.x + 1 end

        -- 3. Strict Deterministic Bounds Checking
        avatar.x = math.max(0, math.min(MAP_WIDTH - 1, avatar.x))
        avatar.z = math.max(0, math.min(MAP_HEIGHT - 1, avatar.z))

        -- 4. Engrave the new physical presence
        local new_idx = avatar.z * MAP_WIDTH + avatar.x
        grid.terrain[new_idx] = avatar.id
        grid.elevation[new_idx] = 80.0 -- Spike the elevation so they literally stand out
    end

    local prev_mouse_left = 0
    local pending_click = -1
    local pick_countdown = 0
    local latched_pick_x, latched_pick_y = -1, -1

    out_packet.click_grid_idx = -1

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
            local frame_time = math.max(0.001, math.min(current_time - last_time, 0.25))
            last_time = current_time
            accumulator = accumulator + frame_time

            local req_pick_x, req_pick_y = -1, -1
            local harvested_id = pick_ptr[0]

            if harvested_id ~= 0xFFFFFFFF then
                pending_click = harvested_id
                pick_ptr[0] = 0xFFFFFFFF
                pick_countdown = 0 -- Instantly abort the countdown once we get our answer!
            end

            local mouse_left = ffi.C.vx_input_mouse_btn(0)
            -- RESTORE THESE TWO LINES: The camera still needs live coordinates for edge-panning!
            local mouse_x = ffi.C.vx_input_mouse_x()
            local mouse_y = ffi.C.vx_input_mouse_y()

            if mouse_left == 1 and prev_mouse_left == 0 then
                -- 1. HARDWARE LATCH: Get exact click coordinates
                latched_pick_x = math.floor(ffi.C.vx_input_click_x())
                latched_pick_y = math.floor(ffi.C.vx_input_click_y())

                -- 2. MULTI-FRAME INJECTION: Spam it into the ring buffer
                pick_countdown = 5 -- Boosted to 5 to be bulletproof against high Lua FPS
            end
            prev_mouse_left = mouse_left

            if pick_countdown > 0 then
                -- Safely feed the exact same latched coordinate every frame
                req_pick_x = latched_pick_x
                req_pick_y = latched_pick_y
                pick_countdown = pick_countdown - 1
            end

            -- 2. DETERMINISTIC LOCKSTEP LOOP
            while accumulator >= FIXED_DT do
                if not net.Poll(in_packet, PACKET_SIZE) then break end

                local current_local_input = ffi.C.vx_input_wasd()

                -- Consume local click for this tick
                local local_click = pending_click
                pending_click = -1

                -- Apply Standard Locomotion
                apply_locomotion(rts_grid, local_avatar, current_local_input, sim_tick_count)
                apply_locomotion(rts_grid, remote_avatar, in_packet.player_input, sim_tick_count)

                -- Apply Deterministic Mouse Picking
                if local_click ~= -1 then
                    if rts_grid.terrain[local_click] == 0 then
                        rts_grid.terrain[local_click] = local_avatar.id
                        rts_grid.elevation[local_click] = 50.0 -- Visual feedback pop
                    else
                        rts_grid.terrain[local_click] = 0
                        rts_grid.elevation[local_click] = 0.0  -- FIX: Flatten when toggled off
                    end
                end

                if in_packet.click_grid_idx ~= -1 then
                    local r_idx = in_packet.click_grid_idx
                    if rts_grid.terrain[r_idx] == 0 then
                        rts_grid.terrain[r_idx] = remote_avatar.id
                        rts_grid.elevation[r_idx] = 50.0
                    else
                        rts_grid.terrain[r_idx] = 0
                        rts_grid.elevation[r_idx] = 0.0
                    end
                end

                update_simulation(rts_grid, FIXED_DT, sim_tick_count)
                sim_tick_count = sim_tick_count + 1

                -- Broadcast State
                out_packet.frame_tick = sim_tick_count
                out_packet.player_input = current_local_input
                out_packet.click_grid_idx = local_click
                net.Send(out_packet, PACKET_SIZE)

                accumulator = accumulator - FIXED_DT
            end

            -- This handles the Escape key, the Window 'X' button, and mode toggles
            local last_key = ffi.C.vx_input_last_key()
            if last_key == cfg.key.esc then ffi.C.vx_core_shutdown()
            elseif last_key == cfg.key.f5 then wants_hotswap = true
            elseif last_key == cfg.key.num1 then active_render_mode = cfg.mode.dual
            elseif last_key == cfg.key.num2 then active_render_mode = cfg.mode.geom
            elseif last_key == cfg.key.num3 then active_render_mode = cfg.mode.points
            end

            -- 3. CAMERA OVERHAUL: EDGE PANNING & EXPONENTIAL ZOOM
            local EDGE_THRESHOLD = 40.0
            local pan_x, pan_z = 0.0, 0.0

            -- Query the C-Core Mailbox for the F10 state
            local is_captured = ffi.C.vx_input_is_captured() == 1

            -- ONLY calculate edge panning if the mouse is clamped to the game window!
            if is_captured then
                if mouse_x < EDGE_THRESHOLD then pan_x = -1.0
                elseif mouse_x > sc.extent.width - EDGE_THRESHOLD then pan_x = 1.0 end

                if mouse_y < EDGE_THRESHOLD then pan_z = -1.0
                elseif mouse_y > sc.extent.height - EDGE_THRESHOLD then pan_z = 1.0 end
            end

            local fwd_x = math.sin(cam_yaw)
            local fwd_z = math.cos(cam_yaw)
            local right_x = math.cos(cam_yaw)
            local right_z = -math.sin(cam_yaw)

            local frame_speed = move_speed * frame_time
            -- Remap 2D screen edges to isometric 3D space
            cam_pos.x = cam_pos.x + (right_x * pan_x + fwd_x * -pan_z) * frame_speed
            cam_pos.z = cam_pos.z + (right_z * pan_x + fwd_z * -pan_z) * frame_speed

            -- Snappy Exponential Zoom (Q and E keys)
            local wasd = ffi.C.vx_input_wasd()
            local zoom_dir = 0
            if bit.band(wasd, 16) ~= 0 then zoom_dir = -1 end -- Q
            if bit.band(wasd, 32) ~= 0 then zoom_dir = 1 end  -- E

            if zoom_dir ~= 0 then
                -- Math.exp scales much faster at higher altitudes, fixing the sluggish limit
                ortho_zoom = ortho_zoom * math.exp(zoom_dir * frame_time * 3.0)
                ortho_zoom = math.max(200.0, math.min(25000.0, ortho_zoom))
            end

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

                -- [NEW] Wire up the ID Buffer and the Mouse Intent
                packet.id_image = ffi.cast("uint64_t", gfx.idImage)
                packet.id_view = ffi.cast("uint64_t", gfx.idImageView)
                packet.picking_buffer = ffi.cast("uint64_t", memory.Buffers["PICK_BUFFER"])
                packet.pick_x = req_pick_x
                packet.pick_y = req_pick_y

                local cmd0 = current_queue_ptr[0]
                local geom_cfg = manifest.graphics.geom
                cmd0.pipeline_id = ffi.cast("uint64_t", gfx.pipelines["geom"])
                cmd0.descriptor_set = ffi.cast("uint64_t", desc.set0)
                cmd0.index_count = 36
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
    memory.DestroyBuffer("PICK_BUFFER", vk_rt) -- [NEW] Destroy the mailbox

    net.Shutdown() -- [NEW] Close the socket gracefully
    memory.DestroyTransferSubsystem(vk_rt)

    require("vulkan_core").Destroy(vk_rt)

    print("[LUA IO] Teardown Complete. Safe Exit.")
end

main()
ffi.C.vx_core_mark_finished()
