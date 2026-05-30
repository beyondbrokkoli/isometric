-- LEGACY PROXY: Merges decoupled registries for old subsystems
local reg = require("registry_vk")
local cfg = require("config_engine")
local manifest = require("pipeline_manifest")

local bp = {}

-- Merge Enums
for k, v in pairs(reg) do bp[k] = v end

-- Merge Configs
for k, v in pairs(cfg) do bp[k] = v end

-- Merge Manifest
bp.graphics_pipelines = manifest

return bp
