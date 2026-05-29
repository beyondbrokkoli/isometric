-- registry_export.lua
local reg = require("boilerplate")

-- Helper to sort table keys alphabetically
local function get_sorted_keys(t)
    local keys = {}
    for k in pairs(t) do table.insert(keys, k) end
    table.sort(keys)
    return keys
end

local function generate_ssot(glsl_path, c_header_path)
    -- 1. Generate GLSL Constants
    local glsl = io.open(glsl_path, "w")
    glsl:write("// AUTO-GENERATED FROM registry_export.lua\n")
    glsl:write("#ifndef REGISTRY_GLSL\n#define REGISTRY_GLSL\n\n")

    glsl:write("// --- RENDER MODES ---\n")
    local mode_keys = get_sorted_keys(reg.mode)
    for _, k in ipairs(mode_keys) do
        glsl:write(string.format("const uint MODE_%s = %dU;\n", string.upper(k), reg.mode[k]))
    end
    glsl:write("\n// --- ENGINE CONSTANTS ---\n")
    local cfg_keys = get_sorted_keys(reg.cfg)
    for _, k in ipairs(cfg_keys) do
        glsl:write(string.format("const uint CFG_%s = %dU;\n", string.upper(k), reg.cfg[k]))
    end

    glsl:write("\n#endif // REGISTRY_GLSL\n")
    glsl:close()
    print("[LUA SSOT] Wrote " .. glsl_path)

    -- 2. Generate C Shared Structs Header
    local c_hdr = io.open(c_header_path, "w")
    c_hdr:write("// AUTO-GENERATED FROM registry_export.lua\n")
    c_hdr:write("#pragma once\n#include <stdint.h>\n\n")

    -- Write the universal math and command structures
    c_hdr:write(reg.c_math_structs)

    -- Inject the C macro to protect vx_math.c from Vulkan types!
    c_hdr:write("\n\n#ifdef VX_ENABLE_VULKAN_STRUCTS\n")
    c_hdr:write(reg.c_vk_structs)
    c_hdr:write("\n#endif // VX_ENABLE_VULKAN_STRUCTS\n")

    c_hdr:close()
    print("[LUA SSOT] Wrote " .. c_header_path)
end

return { generate = generate_ssot }
