#ifndef SHARED_GLSL
#define SHARED_GLSL
#extension GL_GOOGLE_include_directive : require
#include "registry.glsl"

layout(push_constant) uniform PushConstants {
    mat4 viewProj;
    uint soa_upload_idx;
    uint aos_current_idx;
    uint aos_prev_idx;
    uint particle_count;
    float dt;
    float total_time;
    uint target_state;
} pc;

#endif
