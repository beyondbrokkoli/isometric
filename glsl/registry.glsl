// AUTO-GENERATED SSoT - DO NOT MODIFY
#ifndef REGISTRY_GLSL
#define REGISTRY_GLSL

// --- CONSTANTS ---
const uint MODE_DUAL = 0U;
const uint MODE_GEOM = 1U;
const uint MODE_POINT_CLOUD_PASS = 88U;
const uint MODE_POINTS = 2U;
const uint CFG_FRAME_SLOTS = 10U;
const uint CFG_GRID_CELLS = 262144U;
const uint CFG_PC_SIZE = 128U;
const uint CFG_PCOUNT = 1000000U;
const uint CFG_SWAP_SLOTS = 10U;
const uint CFG_SWARM_STATES = 7U;
const uint CFG_USE_VALIDATION = 1U;
const uint CFG_VK_API_VERSION = 4206592U;

// --- std430 SSBO DEFINITIONS ---
struct mat4_t {
    float m[16];
};

struct RtsTileInstance {
    float px;
    float py;
    float pz;
    uint tile_data;
};

struct PushConstants {
    mat4 viewProj;
    uint soa_upload_idx;
    uint aos_current_idx;
    uint aos_prev_idx;
    uint particle_count;
    float dt;
    float total_time;
    uint target_state;
    // Tail padded by 4 bytes
};

#endif // REGISTRY_GLSL
