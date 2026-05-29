#version 460
#extension GL_GOOGLE_include_directive : require
#include "shared.glsl"

// RESTORED: Vertex shader gets read-only access!
layout(set = 0, binding = 0) readonly buffer MasterBuffer { uint data[]; } vram;

layout(location = 0) out vec3 fragColor;
layout(location = 1) out vec3 v_worldPos;
layout(location = 2) flat out uint v_shapeID;
layout(location = 3) flat out float v_colorIdx;

const vec3 SHAPE_LIBRARY[14] = vec3[](
    vec3(0.0,  1.5,  0.0), vec3(0.0, -0.5,  0.0), vec3(-1.0, 0.0,  1.0),
    vec3( 1.0, 0.0,  1.0), vec3( 1.0, 0.0, -1.0), vec3(-1.0, 0.0, -1.0),
    vec3(-1.0, -1.0,  1.0), vec3( 1.0, -1.0,  1.0), vec3( 1.0,  1.0,  1.0),
    vec3(-1.0,  1.0,  1.0), vec3(-1.0, -1.0, -1.0), vec3( 1.0, -1.0, -1.0),
    vec3( 1.0,  1.0, -1.0), vec3(-1.0,  1.0, -1.0)
);

float hash(uint n) {
    n = (n << 13U) ^ n;
    n = n * (n * n * 15731U + 789221U) + 1376312589U;
    return float(n & uvec3(0x7fffffffU)) / float(0x7fffffff);
}

mat3 rotate3D(float x, float y, float z) {
    float cx = cos(x), sx = sin(x); float cy = cos(y), sy = sin(y); float cz = cos(z), sz = sin(z);
    return mat3(cy*cz, -cx*sz + sx*sy*cz, sx*sz + cx*sy*cz, cy*sz, cx*cz + sx*sy*sz, -sx*cz + cx*sy*sz, -sy, sx*cy, cx*cy);
}

void main() {
    uint real_p_id = gl_InstanceIndex;
    uint sorted_p_id = vram.data[pc.sorted_idx + real_p_id];

    // ZERO MAGIC NUMBERS
    if (pc.bg_color_a == MODE_DUAL) {
        if (pc.target_state != MODE_POINT_CLOUD_PASS && (sorted_p_id % 2) != 0) {
            gl_Position = vec4(0.0, 0.0, 2.0, 1.0); return;
        }
        if (pc.target_state == MODE_POINT_CLOUD_PASS && (sorted_p_id % 2) == 0) {
            gl_Position = vec4(0.0, 0.0, 2.0, 1.0); return;
        }
    }

    uint aos_base = pc.aos_current_idx + (sorted_p_id * 4);
    vec3 anchor = vec3(
        uintBitsToFloat(vram.data[aos_base + 0]),
        uintBitsToFloat(vram.data[aos_base + 1]),
        uintBitsToFloat(vram.data[aos_base + 2])
    );

    float h1 = hash(sorted_p_id); float h2 = hash(sorted_p_id + 1337); float h3 = hash(sorted_p_id + 42069);

    vec3 local_pos = vec3(0.0);
    if (pc.target_state != MODE_POINT_CLOUD_PASS) {
        local_pos = SHAPE_LIBRARY[gl_VertexIndex];
        vec3 scale = vec3(0.5 + h1 * 1.5, 0.5 + h2 * 3.0, 0.5 + h3 * 1.5) * 1000.0;
        local_pos *= scale;

        float rx = (h1 * 6.28) + (pc.total_time * (h1 - 0.5) * 0.8);
        float ry = (h2 * 6.28) + (pc.total_time * (h2 - 0.5) * 0.8);
        float rz = (h3 * 6.28) + (pc.total_time * (h3 - 0.5) * 0.8);
        local_pos = rotate3D(rx, ry, rz) * local_pos;
    }

    vec3 final_pos = anchor + local_pos;
    vec4 clip_pos = pc.viewProj * vec4(final_pos, 1.0);
    float dist = max(clip_pos.w, 0.001);

    if (pc.target_state == MODE_POINT_CLOUD_PASS) {
        float base_size = 2.0 + (h2 * 8.0);
        
        // Detect if we are in Orthographic or Perspective mode based on W
        // In perspective, w is the distance to the camera. In ortho, w is exactly 1.0.
        if (abs(clip_pos.w - 1.0) < 0.001) {
            // Isometric Mode: Points don't scale by distance, but they should scale by zoom level.
            // pc.spread represents the zoom level in ortho mode (smaller spread = zoomed in)
            // We invert the relationship so points get bigger when zoomed in.
            float ortho_scale_factor = 20.0 / max(1.0, pc.spread); 
            gl_PointSize = max(2.0, base_size * ortho_scale_factor);
        } else {
            // 3D Free-Cam Mode: Standard perspective scaling
            float projected_size = (base_size * pc.spread * 60.0) / dist;
            gl_PointSize = max(2.0, projected_size);
        }
    }

    float normalized_y = clamp((anchor.y + 5000.0) / 10000.0, 0.0, 1.0);
    float meridian_curve = smoothstep(0.3, 0.7, normalized_y);

    vec3 c_algae = unpackUnorm4x8(pc.algae_color).rgb;
    vec3 c_water = unpackUnorm4x8(pc.water_color).rgb;
    vec3 base_color = mix(c_water, c_algae, meridian_curve);

    v_worldPos = final_pos;
    gl_Position = clip_pos;
    fragColor = base_color * (0.75 + 0.5 * h1);
    v_shapeID = pc.target_state;
    v_colorIdx = meridian_curve;
}
