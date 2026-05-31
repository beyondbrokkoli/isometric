local ffi = require("ffi")

ffi.cdef[[
    int vx_net_host(int port);
    int vx_net_connect(const char* ip, int port);
    void vx_net_send(const void* payload, size_t len); // [FIXED] generic name and size_t
    int vx_net_poll(void* out_buffer, size_t expected_len); // [FIXED] generic name and size_t
    int vx_net_get_last_error(void);
    void vx_net_shutdown(void);
]]

-- Dynamically load the backend based on OS
local success, net_lib = pcall(ffi.load, "./bin/libvx_net.so")
if not success then
    success, net_lib = pcall(ffi.load, "./bin/vx_net.dll")
end
assert(success, "FATAL: Could not load Networking Backend!")

local Network = {}

function Network.Host(port)
    return net_lib.vx_net_host(port) == 0
end

function Network.Connect(ip, port)
    return net_lib.vx_net_connect(ip, port) == 0
end

-- [FIXED] Pass the length parameter down to the C-Core
function Network.Send(cmd_ptr, len)
    net_lib.vx_net_send(cmd_ptr, len)
end

-- [FIXED] Pass the expected length down to the C-Core
function Network.Poll(cmd_ptr, expected_len)
    return net_lib.vx_net_poll(cmd_ptr, expected_len) == 1
end

function Network.Shutdown()
    net_lib.vx_net_shutdown()
end

return Network
