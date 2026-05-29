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

    // Math & Thread Interfaces
    void vmath_init_workers(int num_threads);
    void vmath_destroy_workers();
    void vmath_dispatch_swarm(int count, float* px, float* py, float* pz, float* vx, float* vy, float* vz, float* seed, const SwarmCommand* cmd, float time, float dt, float gravity, float blend_metal, float blend_paradox);
    void vx_math_stream_pos(int count, float* c_px, float* c_py, float* c_pz, float* g_px, float* g_py, float* g_pz);

    // Ring Buffer Interfaces
    int vx_stream_acquire();
    RenderPacket* vx_stream_packet(int idx);
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

    print("[LUA IO] Initializing CPU Data Structures...")

    -- 2. Allocate Fast AVX2 CPU RAM (SoA)
    local requested_count = bp.cfg.pcount
    local padded_capacity = math.ceil(requested_count / 8) * 8
    memory.AllocateSoA("float", padded_capacity, {"px", "py", "pz", "vx", "vy", "vz", "seed"})

    local cpu_soa = {
        px = memory.AVX_Arrays["px"], py = memory.AVX_Arrays["py"], pz = memory.AVX_Arrays["pz"],
        vx = memory.AVX_Arrays["vx"], vy = memory.AVX_Arrays["vy"], vz = memory.AVX_Arrays["vz"],
        seed = memory.AVX_Arrays["seed"]
    }

    -- 3. Populate Initial Particle State
    for p = 0, requested_count - 1 do
        cpu_soa.seed[p] = math.random()
        cpu_soa.px[p] = (math.random() - 0.5) * 20000.0
        cpu_soa.py[p] = (math.random() - 0.5) * 10000.0 + 5000.0
        cpu_soa.pz[p] = (math.random() - 0.5) * 20000.0
        cpu_soa.vx[p] = 0.0
        cpu_soa.vy[p] = 0.0
        cpu_soa.vz[p] = 0.0
    end

    -- 4. Compile Geometry Indices into VRAM
    print("[LUA CO] Compiling Geometry Indices to mapped VRAM...")
    local idx_ptr = ffi.cast("uint32_t*", memory.Mapped["MASTER_INDEX_BLOCK"])
    local indices = {
        0,2,3, 0,3,4, 0,4,5, 0,5,2,
        1,3,2, 1,4,3, 1,5,4, 1,2,5,
        6,7,8, 6,8,9, 7,11,12, 7,12,8,
        11,10,13, 11,13,12, 10,6,9, 10,9,13,
        9,8,12, 9,12,13, 10,11,7, 10,7,6
    }
    for i, idx in ipairs(indices) do idx_ptr[i - 1] = idx end

    -- 5. Boot the AVX2 Math Pool
    local vmath_lib = ffi.load(jit.os == "Windows" and "bin/vx_math.dll" or "bin/libvx_math.so")
    vmath_lib.vmath_init_workers(8)

    -- 6. Runtime State Initialization
    local MAX_DRAW_COMMANDS = 1024
    local render_queues = ffi.new("DrawCommand[?]", MAX_DRAW_COMMANDS * bp.cfg.frame_slots)
    local MAX_COMPUTE_COMMANDS = 16
    local compute_queues = ffi.new("ComputeCommand[?]", MAX_COMPUTE_COMMANDS * bp.cfg.frame_slots)

    local frame_count = 0
    local pc = ffi.new("PushConstants")
    pc.soa_upload_idx, pc.aos_current_idx, pc.aos_prev_idx = 0, 0, 0
    pc.particle_count = bp.cfg.pcount
    pc.dt = 0.0

    local proj, view = ffi.new("mat4_t"), ffi.new("mat4_t")
    local aspect = sc.extent.width / sc.extent.height
    local vmath = require("vmath")
    vmath.perspective_inf_revz(70.0, aspect, 0.1, proj)

    local cam_pos = {x = 0.0, y = 0.0, z = -600.0}
    local cam_yaw, cam_pitch = 0.0, 0.0
    local sensitivity, move_speed = 0.002, 320000.0

    local last_time = get_time_hires()
    local total_time = 0.0
    local current_swarm_state = 1
    local swarm_cmd = ffi.new("SwarmCommand")
    local space_was_pressed = false
    local wants_hotswap = false

    local master_ptr = ffi.cast("float*", memory.Mapped["MASTER_GPU_BLOCK"])
    local c_px, c_py, c_pz = cpu_soa.px, cpu_soa.py, cpu_soa.pz
    local c_vx, c_vy, c_vz = cpu_soa.vx, cpu_soa.vy, cpu_soa.vz
    local c_seed = cpu_soa.seed
    local active_render_mode = bp.mode.dual

    local is_resizing = false
    local last_resize_time = get_time_hires()
    local RESIZE_COOLDOWN = 0.25

    print("[LUA CO] Entering Data-Driven Render Loop...")

    -- Shader Hot-Reloading
    local gfx_pipeline_module = require("graphics_pipeline")
    local pump_deletion_queue = gfx_pipeline_module.PumpDeletionQueue

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

                    -- 8. Fire the C-Core back up by explicitly invoking Stage 10!
                    bp.sequence[10].action(new_ctx, bp)

                    print("[LUA CO] Mini-Weaver Rebuild Complete.\n")

                    -- Update aspect ratio for projection matrix
                    aspect = sc.extent.width / math.max(1, sc.extent.height)
                    vmath.perspective_inf_revz(70.0, aspect, 0.1, proj)

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

            -- [NEW] Camera Mode Toggle State
            local is_isometric = pc.bg_color_b == 0xFF00AAFF -- We can use an unused push constant to hold state, or just a local var
            
            local last_key = ffi.C.vx_input_last_key()
            if last_key == bp.key.esc then ffi.C.vx_core_shutdown()
            elseif last_key == bp.key.f5 then wants_hotswap = true
            elseif last_key == bp.key.num1 then active_render_mode = bp.mode.dual
            elseif last_key == bp.key.num2 then active_render_mode = bp.mode.geom
            elseif last_key == bp.key.num3 then active_render_mode = bp.mode.points
            elseif last_key == bp.key.num4 then 
                is_isometric = not is_isometric 
                print(is_isometric and "\n[LUA CO] Snap: ISOMETRIC PIZZA WORLD" or "\n[LUA CO] Snap: 3D FREE-CAM")
            end

            -- Store the state in the unused push constant to persist across frames
            pc.bg_color_b = is_isometric and 0xFF00AAFF or 0xFF442211
            pc.bg_color_a = active_render_mode

            -- [NEW] Dynamic Projection Routing
            local ortho_zoom = pc.spread * 100.0 -- Repurpose spread for zoom memory
            local aspect = sc.extent.width / math.max(1, sc.extent.height)

            if is_isometric then
                -- Lock to pure isometric angles
                cam_pitch = -0.6154 -- approx -35.264 degrees
                cam_yaw = 0.7853    -- approx 45 degrees

                -- Map Q/E to Orthographic Zoom instead of Y-Axis height
                local zoom_speed = move_speed * dt * 0.05
                if bit.band(wasd, 16) ~= 0 then ortho_zoom = ortho_zoom - zoom_speed end
                if bit.band(wasd, 32) ~= 0 then ortho_zoom = ortho_zoom + zoom_speed end
                ortho_zoom = math.max(500.0, ortho_zoom)
                pc.spread = ortho_zoom / 100.0

                vmath.ortho_revz(-ortho_zoom * aspect, ortho_zoom * aspect, -ortho_zoom, ortho_zoom, -20000.0, 20000.0, proj)
            else
                -- 3D Free-Cam Input
                cam_yaw = cam_yaw + (dx * sensitivity)
                cam_pitch = math.max(-1.5, math.min(1.5, cam_pitch + (dy * sensitivity)))
                vmath.perspective_inf_revz(70.0, aspect, 0.1, proj)
            end

            -- Base directional vectors
            local fwd_x = math.sin(cam_yaw) * math.cos(cam_pitch)
            local fwd_y = -math.sin(cam_pitch)
            local fwd_z = math.cos(cam_yaw) * math.cos(cam_pitch)
            local right_x = math.cos(cam_yaw)
            local right_z = -math.sin(cam_yaw)

            -- [NEW] Flatten Movement Vector for Isometric Panning
            if is_isometric then
                fwd_x = math.sin(cam_yaw)
                fwd_y = 0.0
                fwd_z = math.cos(cam_yaw)
            end

            local frame_speed = move_speed * dt
            if bit.band(wasd, 1) ~= 0 then cam_pos.x = cam_pos.x + fwd_x * frame_speed; cam_pos.y = cam_pos.y + fwd_y * frame_speed; cam_pos.z = cam_pos.z + fwd_z * frame_speed end
            if bit.band(wasd, 2) ~= 0 then cam_pos.x = cam_pos.x - fwd_x * frame_speed; cam_pos.y = cam_pos.y - fwd_y * frame_speed; cam_pos.z = cam_pos.z - fwd_z * frame_speed end
            if bit.band(wasd, 4) ~= 0 then cam_pos.x = cam_pos.x - right_x * frame_speed; cam_pos.z = cam_pos.z - right_z * frame_speed end
            if bit.band(wasd, 8) ~= 0 then cam_pos.x = cam_pos.x + right_x * frame_speed; cam_pos.z = cam_pos.z + right_z * frame_speed end

            -- Only allow free Y-axis translation in 3D mode
            if not is_isometric then
                if bit.band(wasd, 16) ~= 0 then cam_pos.y = cam_pos.y + frame_speed end
                if bit.band(wasd, 32) ~= 0 then cam_pos.y = cam_pos.y - frame_speed end
            end

            vmath.lookAt(cam_pos.x, cam_pos.y, cam_pos.z, cam_pos.x + fwd_x, cam_pos.y + fwd_y, cam_pos.z + fwd_z, view)

            -- Time & Matrix pushes
            pc.dt = pc.dt + dt
            total_time = total_time + dt
            pc.total_time = total_time
            pc.highlight_power = 64.0
            pc.algae_color = 0xFF22AA44
            pc.water_color = 0xFFFF8800

            vmath.multiply_mat4(proj, view, pc.viewProj)

            local space_is_down = (ffi.C.vx_input_spacebar() == 1)
            if space_is_down then
                if not space_was_pressed then
                    current_swarm_state = (current_swarm_state % bp.cfg.swarm_states) + 1
                    space_was_pressed = true
                end
            else
                space_was_pressed = false
            end

            local last_key = ffi.C.vx_input_last_key()
            if last_key == bp.key.esc then ffi.C.vx_core_shutdown()
            elseif last_key == bp.key.f5 then wants_hotswap = true
            elseif last_key == bp.key.num1 then active_render_mode = bp.mode.dual
            elseif last_key == bp.key.num2 then active_render_mode = bp.mode.geom
            elseif last_key == bp.key.num3 then active_render_mode = bp.mode.points
            end

            pc.bg_color_a = active_render_mode
            swarm_cmd.target_state = current_swarm_state - 1
            swarm_cmd.push_active = ffi.C.vx_input_mouse_btn(0)
            swarm_cmd.pull_active = ffi.C.vx_input_mouse_btn(1)
            swarm_cmd.mouse_x = 0.0
            swarm_cmd.mouse_y = 5000.0

            -- Synchronous CPU Math execution
            vmath_lib.vmath_dispatch_swarm(
                pc.particle_count, c_px, c_py, c_pz, c_vx, c_vy, c_vz, c_seed,
                swarm_cmd, pc.dt, dt, 9.81, 1.0, 1.0
            )

            -- 1. Acquire Ring Buffer Slot
            local write_idx = ffi.C.vx_stream_acquire()

            if write_idx ~= -1 then
                local prev_idx = (write_idx - 1 + bp.cfg.frame_slots) % bp.cfg.frame_slots
                local padded_capacity = math.ceil(pc.particle_count / 8) * 8

                -- Memory Offsets (Reconstructed from your old logic)
                local FRAME_TOTAL_WORDS = math.ceil(((padded_capacity * 3) + (padded_capacity * 4) + padded_capacity + (bp.cfg.grid_cells * 2) + 128) / 16) * 16
                local current_frame_offset = write_idx * FRAME_TOTAL_WORDS
                local prev_frame_offset = prev_idx * FRAME_TOTAL_WORDS

                local gpu_px = master_ptr + current_frame_offset
                local gpu_py = master_ptr + (current_frame_offset + padded_capacity)
                local gpu_pz = master_ptr + (current_frame_offset + (padded_capacity * 2))

                vmath_lib.vx_math_stream_pos(padded_capacity, c_px, c_py, c_pz, gpu_px, gpu_py, gpu_pz)

                local aos_local_offset = padded_capacity * 3
                pc.soa_upload_idx = current_frame_offset
                pc.aos_current_idx = current_frame_offset + aos_local_offset
                pc.aos_prev_idx = prev_frame_offset + aos_local_offset
                pc.sorted_idx = current_frame_offset + aos_local_offset + (padded_capacity * 4)
                pc.cell_counters_idx = pc.sorted_idx + padded_capacity
                pc.cell_offsets_idx = pc.cell_counters_idx + bp.cfg.grid_cells

                local packet = ffi.C.vx_stream_packet(write_idx)
                local current_queue_ptr = render_queues + (write_idx * MAX_DRAW_COMMANDS)
                local current_comp_queue = compute_queues + (write_idx * MAX_COMPUTE_COMMANDS)

                -- ==========================================
                -- DATA-DRIVEN COMPUTE GRAPH
                -- ==========================================
                packet.comp_queue = current_comp_queue
                packet.comp_count = #bp.compute_pipelines

                for i, cfg in ipairs(bp.compute_pipelines) do
                    local cmd = current_comp_queue[i - 1]

                    cmd.pipeline_id = ffi.cast("uint64_t", comp.pipelines[cfg.name])
                    cmd.layout_id = ffi.cast("uint64_t", comp.pipelineLayout)
                    cmd.descriptor_set = ffi.cast("uint64_t", desc.set0)
                    cmd.group_y = 1
                    cmd.group_z = 1
                    cmd.pc_offset = 0
                    cmd.pc_size = bp.cfg.pc_size
                    ffi.copy(cmd.push_constants, pc, bp.cfg.pc_size)

                    -- Dispatch Logic
                    if cfg.dispatch == "grid" then cmd.group_x = math.ceil(bp.cfg.grid_cells / 256)
                    elseif cfg.dispatch == "particle" then cmd.group_x = math.ceil(pc.particle_count / 256)
                    elseif cfg.dispatch == "groups" then cmd.group_x = math.ceil(bp.cfg.grid_cells / (1024 * 2))
                    elseif cfg.dispatch == "single" then cmd.group_x = 1
                    end

                    -- Barrier Logic
                    cmd.barrier_src_stage = cfg.b_src_stage
                    cmd.barrier_dst_stage = cfg.b_dst_stage
                    cmd.barrier_src_access = cfg.b_src_access
                    cmd.barrier_dst_access = cfg.b_dst_access
                end

                -- ==========================================
                -- DATA-DRIVEN GRAPHICS GRAPH
                -- ==========================================
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
                cmd0.instance_count = pc.particle_count
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
                cmd0.depth_compare_op = 4

                -- Render Points Pass (From Boilerplate)
                local cmd1 = current_queue_ptr[1]
                local points_cfg = bp.graphics_pipelines.points
                cmd1.pipeline_id = ffi.cast("uint64_t", gfx.pipelines["points"])
                cmd1.descriptor_set = ffi.cast("uint64_t", desc.set0)
                cmd1.index_count = 1
                cmd1.first_index = 0
                cmd1.vertex_offset = 0
                cmd1.instance_count = pc.particle_count
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
                cmd1.depth_compare_op = 4

                if active_render_mode == bp.mode.dual then
                    cmd0.first_instance = 0
                   cmd0.instance_count = pc.particle_count
                    cmd1.first_instance = 0
                    cmd1.instance_count = pc.particle_count

                    packet.draw_queue = current_queue_ptr
                    packet.draw_count = 2

                elseif active_render_mode == bp.mode.geom then
                    cmd0.first_instance = 0
                    cmd0.instance_count = pc.particle_count

                    packet.draw_queue = current_queue_ptr
                    packet.draw_count = 1

                elseif active_render_mode == bp.mode.points then
                    cmd1.first_instance = 0
                    cmd1.instance_count = pc.particle_count

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
    vmath_lib.vmath_destroy_workers()

    -- 2. Wait for the GPU to finish its current queue
    vk_rt.vk.vkDeviceWaitIdle(vk_rt.device)

    -- 3. Dismantle the Data-Driven Pipelines (Reverse Order of Creation)
    require("graphics_pipeline").Destroy(vk_rt.vk, vk_rt, gfx)
    require("compute_pipeline").Destroy(vk_rt.vk, vk_rt, comp)
    require("descriptors").Destroy(vk_rt.vk, vk_rt.device, desc)
    require("swapchain").Destroy(vk_rt.vk, vk_rt, sc)
    require("renderer").Destroy(vk_rt.vk, vk_rt.device, sync, bp.cfg.frame_slots)

    -- 4. Free Memory Arenas (VRAM & CPU RAM)
    print("[TEARDOWN] Freeing VRAM and CPU Memory Arenas...")
    memory.DestroyBuffer("MASTER_GPU_BLOCK", vk_rt)
    memory.DestroyBuffer("MASTER_INDEX_BLOCK", vk_rt)
    memory.FreeSoA({"px", "py", "pz", "vx", "vy", "vz", "seed"})

    -- 5. Nuke the Vulkan Instance
    require("vulkan_core").Destroy(vk_rt)

    print("[LUA IO] Teardown Complete. Safe Exit.")
end

main()
ffi.C.vx_core_mark_finished()
