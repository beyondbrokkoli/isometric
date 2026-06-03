local ffi = require("ffi")

ffi.cdef[[
    int vx_net_host(int port);
    int vx_net_connect(const char* ip, int port);
    void vx_net_send(const void* payload, size_t len);
    int vx_net_poll(void* out_buffer, size_t expected_len);
    int vx_net_get_last_error(void);
    void vx_net_shutdown(void);

    // [NEW] Rollback Interfaces
    RollbackBuffer* vx_net_get_arena(void);
    void vx_net_commit_frame(uint32_t tick, uint32_t local_wasd, int32_t local_click);
]]

local net_lib

-- Route the loader strictly by OS to avoid Windows 'Bad Image' popups
if jit.os == "Windows" then
    net_lib = ffi.load("./bin/vx_net.dll")
else
    net_lib = ffi.load("./bin/libvx_net.so")
end

-- We can still assert in case the correct file is genuinely missing
assert(net_lib, "FATAL: Could not load Networking Backend for " .. jit.os .. "!")

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

function Network.GetArena()
    return net_lib.vx_net_get_arena()
end

function Network.CommitFrame(tick, wasd, click)
    net_lib.vx_net_commit_frame(tick, wasd, click)
end

function Network.Shutdown()
    net_lib.vx_net_shutdown()
end

return Network
