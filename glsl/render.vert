#version 460
#extension GL_GOOGLE_include_directive : require
#include "shared.glsl"

// RESTORED: Vertex shader gets read-only access!
layout(set = 0, binding = 0) readonly buffer MasterBuffer { uint data[]; } vram;

layout(location = 0) out vec3 fragColor;
layout(location = 1) out vec3 v_worldPos;
layout(location = 2) flat out uint v_shapeID;
layout(location = 3) flat out float v_colorIdx;
layout(location = 4) flat out uint v_instanceID; // [NEW] Pass the raw ID

const vec3 SHAPE_LIBRARY[14] = vec3[](
    vec3(0.0,  1.5,  0.0), vec3(0.0, -0.5,  0.0), vec3(-1.0, 0.0,  1.0),
    vec3( 1.0, 0.0,  1.0), vec3( 1.0, 0.0, -1.0), vec3(-1.0, 0.0, -1.0),
    vec3(-1.0, -1.0,  1.0), vec3( 1.0, -1.0,  1.0), vec3( 1.0,  1.0,  1.0),
    vec3(-1.0,  1.0,  1.0), vec3(-1.0, -1.0, -1.0), vec3( 1.0, -1.0, -1.0),
    vec3( 1.0,  1.0, -1.0), vec3(-1.0,  1.0, -1.0)
);

void main() {
    v_instanceID = gl_InstanceIndex; // Maps 1:1 to your Lua grid index

    uint base_idx = pc.aos_current_idx + (gl_InstanceIndex * 4); 
    
    vec3 tile_pos = vec3(
        uintBitsToFloat(vram.data[base_idx + 0]),
        uintBitsToFloat(vram.data[base_idx + 1]),
        uintBitsToFloat(vram.data[base_idx + 2])
    );
    
    uint tile_data = vram.data[base_idx + 3];
    uint terrain_id = (tile_data >> 24) & 0xFF; 

    vec3 local_pos = SHAPE_LIBRARY[gl_VertexIndex];
    local_pos *= vec3(10.0, 5.0, 10.0);
    
    vec3 final_pos = tile_pos + local_pos;

    gl_Position = pc.viewProj * vec4(final_pos, 1.0);
    v_worldPos = final_pos;
    
    v_shapeID = pc.target_state; 
    v_colorIdx = float(terrain_id) / 255.0; 
    
    // Create a base color mapped to the terrain_id (e.g. 0 = dark green, 255 = light green)
    vec3 base_color = mix(vec3(0.1, 0.4, 0.1), vec3(0.5, 0.8, 0.3), v_colorIdx);
    fragColor = base_color;
    
    gl_PointSize = 3.0; 
}
