#ifndef SHARED_GLSL
#define SHARED_GLSL
#extension GL_GOOGLE_include_directive : require

// 1. Pull in the generated Single Source of Truth
#include "registry.glsl"

// 2. The Push Constant Wrapper
// We define a uniform block (PushBlock) and place the generated struct inside it.
// Naming the instance 'pc' ensures pc.viewProj and pc.dt continue working flawlessly.
layout(push_constant) uniform PushBlock {
    PushConstants pc;
};

// 3. The SSBO Wrapper
// Since you are streaming RtsTileInstance from Lua, we must define the GPU-side arena.
// Using std430 enforces the Alignment Manifesto, perfectly matching your C padding.
layout(std430, binding = 0) readonly buffer MasterGpuArena {
    RtsTileInstance tiles[];
} master_grid;

#endif
