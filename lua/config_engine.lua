local bit = require("bit")
-- OTHER_API = 4202603
return {
    sys = { idle = 0, boot = 1, kill = 2 },
    win = { w = 1280, h = 720, min_w = 640, min_h = 360 },
    move  = { fwd = 1, back = 2, left = 4, right = 8, up = 16, down = 32 },
    mouse = { left = 0, right = 1 },
    key   = { space = 32, num1 = 49, num2 = 50, num3 = 51, num4 = 52, esc = 256, f11 = 290, f5 = 294 },
    cfg = { use_validation = 1, vk_api_version = 4206592, pcount = 1000000, grid_cells = 262144, pc_size = 128, frame_slots = 10, swap_slots = 10, swarm_states = 7 },
    mode = { dual = 0, geom = 1, points = 2, point_cloud_pass = 88 },
    memory_arenas = {
        { name = "MASTER_INDEX_BLOCK", cdef_type = "uint32_t", count = 256, usage = bit.bor(64, 256) },
        { name = "MASTER_GPU_BLOCK", cdef_type = "uint8_t", count = 12582912, usage = bit.bor(32, 128, 256) }
    }
}
