#version 460
#extension GL_GOOGLE_include_directive : require
#include "shared.glsl"

// RESTORED: Vertex shader gets read-only access (Aliased as raw uints for bit-casting)
layout(set = 0, binding = 0) readonly buffer MasterBuffer { uint data[]; } vram;

// MODIFIED: We now pass vec4 (v_color) instead of vec3 (fragColor) and drop v_colorIdx
layout(location = 0) out vec4 v_color;
layout(location = 1) out vec3 v_worldPos;
layout(location = 2) flat out uint v_shapeID;

const vec3 SHAPE_LIBRARY[14] = vec3[](
    vec3(0.0,  1.5,  0.0), vec3(0.0, -0.5,  0.0), vec3(-1.0, 0.0,  1.0),
    vec3( 1.0, 0.0,  1.0), vec3( 1.0, 0.0, -1.0), vec3(-1.0, 0.0, -1.0),
    vec3(-1.0, -1.0,  1.0), vec3( 1.0, -1.0,  1.0), vec3( 1.0,  1.0,  1.0),
    vec3(-1.0,  1.0,  1.0), vec3(-1.0, -1.0, -1.0), vec3( 1.0, -1.0, -1.0),
    vec3( 1.0,  1.0, -1.0), vec3(-1.0,  1.0, -1.0)
);

void main() {
    uint base_idx = pc.aos_current_idx + (gl_InstanceIndex * 4);

    vec3 tile_pos = vec3(
        uintBitsToFloat(vram.data[base_idx + 0]),
        uintBitsToFloat(vram.data[base_idx + 1]),
        uintBitsToFloat(vram.data[base_idx + 2])
    );

    uint tile_data = vram.data[base_idx + 3];
    uint terrain_id = (tile_data >> 24) & 0xFF;

    vec3 local_pos = SHAPE_LIBRARY[gl_VertexIndex];
    // UNIT MANIFESTO SCALING: 1 unit = 1 tile width. (was 10.0, 5.0, 10.0)
    local_pos *= vec3(0.5, 0.25, 0.5);

    vec3 final_pos = tile_pos + local_pos;

    gl_Position = pc.viewProj * vec4(final_pos, 1.0);
    v_worldPos = final_pos;

    v_shapeID = pc.target_state;

    // NEW: Fetch directly from the Palette SSBO (which was added to shared.glsl)
    v_color = palette.colors[terrain_id];

    gl_PointSize = 3.0;
}
