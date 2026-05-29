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
    // 4 uints per RtsTileInstance (px, py, pz, tile_data)
    uint base_idx = pc.aos_current_idx + (gl_InstanceIndex * 4); 
    
    vec3 tile_pos = vec3(
        uintBitsToFloat(vram.data[base_idx + 0]),
        uintBitsToFloat(vram.data[base_idx + 1]),
        uintBitsToFloat(vram.data[base_idx + 2])
    );
    
    uint tile_data = vram.data[base_idx + 3];
    uint terrain_id = (tile_data >> 24) & 0xFF; // Unpack the top 8 bits
    
    // Instead of random local_pos scaling, extrude mathematically satisfying cubes/slabs
    vec3 local_pos = SHAPE_LIBRARY[gl_VertexIndex];
    local_pos *= vec3(10.0, 5.0, 10.0); // Strict tile dimensions
    
    vec3 final_pos = tile_pos + local_pos;
    gl_Position = pc.viewProj * vec4(final_pos, 1.0);
    
    // Pass color based on deterministic terrain_id, not random hashes!
    v_colorIdx = float(terrain_id) / 255.0; 
}
