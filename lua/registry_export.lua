local cfg = require("config_engine")
local reg = require("registry_vk")

local function get_sorted_keys(t)
    local keys = {}
    for k in pairs(t) do table.insert(keys, k) end
    table.sort(keys)
    return keys
end

local function get_base_size(type_str)
    if string.find(type_str, "64") or string.find(type_str, "*") then return 8 end
    if string.find(type_str, "32") or type_str == "float" then return 4 end
    if string.find(type_str, "16") then return 2 end
    if string.find(type_str, "8") then return 1 end
    return 64 -- mat4_t fallback
end

local function map_glsl_type(type_str)
    if type_str == "float" then return "float" end
    if string.find(type_str, "mat4") then return "mat4" end
    return "uint" -- Default mapping for ints in our pipeline
end

local function generate_ssot(glsl_path, c_header_path)
    local glsl = io.open(glsl_path, "w")
    local c_hdr = io.open(c_header_path, "w")

    -- 1. HEADER SETUP
    glsl:write("// AUTO-GENERATED SSoT - DO NOT MODIFY\n")
    glsl:write("#ifndef REGISTRY_GLSL\n#define REGISTRY_GLSL\n\n")
    c_hdr:write("// AUTO-GENERATED SSoT - DO NOT MODIFY\n")
    c_hdr:write("#pragma once\n#include <stdint.h>\n\n")

    -- 2. ENUMS & CONSTANTS
    glsl:write("// --- CONSTANTS ---\n")
    local mode_keys = get_sorted_keys(cfg.mode)
    for _, k in ipairs(mode_keys) do
        glsl:write(string.format("const uint MODE_%s = %dU;\n", string.upper(k), cfg.mode[k]))
    end

    local cfg_keys = get_sorted_keys(cfg.cfg)
    for _, k in ipairs(cfg_keys) do
        glsl:write(string.format("const uint CFG_%s = %dU;\n", string.upper(k), cfg.cfg[k]))
    end

    -- 3. ALIGNMENT MANIFESTO: DYNAMIC STRUCT GENERATION
    glsl:write("\n// --- std430 SSBO DEFINITIONS ---\n")

    for _, struct in ipairs(reg.structs) do
        -- C-Side Generation
        local attr = struct.force_align and "__attribute__((packed, aligned("..struct.align..")))" or "__attribute__((packed))"
        c_hdr:write(string.format("typedef struct %s {\n", attr))

        -- GLSL-Side Generation
        if not struct.c_only then
            glsl:write(string.format("struct %s {\n", struct.name))
        end

        local offset = 0
        local pad_id = 0

        for _, m in ipairs(struct.members) do
            local m_size = get_base_size(m.type)

            -- Detect Alignment Fracture & Force Padding
            local rem = offset % m_size
            if rem ~= 0 then
                local pad_bytes = m_size - rem
                c_hdr:write(string.format("    uint8_t _pad_auto_%d[%d];\n", pad_id, pad_bytes))
                if not struct.c_only then
                    -- In GLSL, pad with an array of uints (or raw floats) to consume the bytes
                    -- Since padding here is strictly for catching odd bytes, std430 handles it naturally
                    -- But we explicitly comment it to track layout parity.
                    glsl:write(string.format("    // Engine injected %d pad bytes for std430\n", pad_bytes))
                end
                offset = offset + pad_bytes
                pad_id = pad_id + 1
            end

            -- Write Member
            local c_arr = m.count and string.format("[%d]", m.count) or ""
            c_hdr:write(string.format("    %s %s%s;\n", m.type, m.name, c_arr))

            if not struct.c_only then
                local glsl_type = map_glsl_type(m.type)
                local glsl_arr = m.count and string.format("[%d]", m.count) or ""
                glsl:write(string.format("    %s %s%s;\n", glsl_type, m.name, glsl_arr))
            end

            offset = offset + (m_size * (m.count or 1))
        end

        -- Tail Padding Enforcement
        local tail_rem = offset % struct.align
        if tail_rem ~= 0 then
            local tail_pad = struct.align - tail_rem
            c_hdr:write(string.format("    uint8_t _pad_tail[%d];\n", tail_pad))
            if not struct.c_only then
                glsl:write(string.format("    // Tail padded by %d bytes\n", tail_pad))
            end
        end

        c_hdr:write("} " .. struct.name .. ";\n\n")
        if not struct.c_only then
            glsl:write("};\n\n")
        end
    end

    -- [NEW] Inject Vulkan Host Interfaces
    c_hdr:write("\n// --- VULKAN HOST INTERFACES ---\n")
    c_hdr:write("#ifdef VX_ENABLE_VULKAN_STRUCTS\n")
    c_hdr:write(reg.c_vk_structs)
    c_hdr:write("\n#endif // VX_ENABLE_VULKAN_STRUCTS\n")

    glsl:write("#endif // REGISTRY_GLSL\n")
    glsl:close()
    c_hdr:close()

    print("[LUA SSOT] Alignment Manifesto Enforced. Header and GLSL Generated.")
end

return { generate = generate_ssot }
