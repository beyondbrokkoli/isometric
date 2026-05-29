#ifndef SHARED_GLSL
#define SHARED_GLSL

#extension GL_GOOGLE_include_directive : require
#include "registry.glsl"

layout(push_constant) uniform PushConstants {
    mat4 viewProj;                    // 0-63: 64 bytes
    uint soa_upload_idx;              // 64-67
    uint aos_current_idx;             // 68-71
    uint aos_prev_idx;                // 72-75
    uint particle_count;              // 76-79
    float dt;                         // 80-83
    float total_time;                 // 84-87
    float spread;                     // 88-91
    float highlight_power;            // 92-95
    uint algae_color;                 // 96-99
    uint water_color;                 // 100-103
    uint bg_color_a;                  // 104-107
    uint bg_color_b;                  // 108-111
    uint target_state;                // 112-115
    uint sorted_idx;                  // 116-119
    uint cell_counters_idx;           // 120-123
    uint cell_offsets_idx;            // 124-127
} pc;

// Helper function shared across Compute and Vertex shaders!
uint get_cell_id(vec3 pos) {
    ivec3 p = ivec3(pos * 0.005);
    uint h = (uint(p.x) * 73856093U) ^ (uint(p.y) * 19349663U) ^ (uint(p.z) * 83492791U);
    return h % CFG_GRID_CELLS; // <--- Uses the auto-generated SSoT constant!
}

#endif // SHARED_GLSL
