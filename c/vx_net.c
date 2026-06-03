/* c/vx_net.c - Non-blocking UDP bridge for Deterministic Lockstep */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <stdatomic.h>

#include "shared_structs.h" // Brings in all the CFG_ and FRAME_STATE_ defines

// Quick macro to turn the size into a bitmask (128 -> 127)
#define NET_RING_MASK (CFG_ROLLBACK_BUFFER_SIZE - 1)

#if defined(_WIN32)
    #define EXPORT __declspec(dllexport)
    #include <winsock2.h>
    #include <ws2tcpip.h>
    #pragma comment(lib, "ws2_32.lib")
    typedef int socklen_t;
    typedef SSIZE_T ssize_t;
    typedef SOCKET vx_socket_t; /* [NEW] Native Windows socket type */
    static int net_wsa_initialized = 0;
    #define NET_CLOSE closesocket
    #define NET_ERROR SOCKET_ERROR
    #define NET_INVALID INVALID_SOCKET
    #define NET_WOULDBLOCK WSAEWOULDBLOCK
    #define NET_LASTERR WSAGetLastError()
#else
    #define EXPORT __attribute__((visibility("default")))
    #include <sys/socket.h>
    #include <netinet/in.h>
    #include <arpa/inet.h>
    #include <netdb.h>
    #include <fcntl.h>
    #include <unistd.h>
    #include <errno.h>
    typedef int vx_socket_t; /* [NEW] Native POSIX socket type */
    #define NET_CLOSE close
    #define NET_ERROR -1
    #define NET_INVALID -1
    #define NET_WOULDBLOCK EWOULDBLOCK
    #define NET_LASTERR errno
#endif

// Internal Network State (lock-free for single-threaded Lua access)
static struct {
    vx_socket_t sock; /* [FIXED] Now properly scales to 64-bit on Windows */
    int is_bound;
    int is_connected;
    struct sockaddr_in remote_addr;
    socklen_t remote_addr_len;
    _Atomic(int) last_error;
} g_net = {
    .sock = NET_INVALID,
    .is_bound = 0,
    .is_connected = 0,
    .remote_addr_len = sizeof(struct sockaddr_in)
};

// Platform Abstraction: Non-blocking socket setup
static inline int net_set_nonblocking(int sock) {
#if defined(_WIN32)
    u_long mode = 1;
    return ioctlsocket(sock, FIONBIO, &mode) == 0 ? 0 : -1;
#else
    int flags = fcntl(sock, F_GETFL, 0);
    return (flags < 0) ? -1 : fcntl(sock, F_SETFL, flags | O_NONBLOCK);
#endif
}

static inline void net_cleanup_platform(void) {
#if defined(_WIN32)
    if (net_wsa_initialized) {
        WSACleanup();
        net_wsa_initialized = 0;
    }
#endif
}

static inline int net_init_platform(void) {
#if defined(_WIN32)
    if (!net_wsa_initialized) {
        WSADATA wsa;
        if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return -1;
        net_wsa_initialized = 1;
    }
#endif
    return 0;
}

/**
 * vx_net_host(int port)
 * Bind a UDP socket to port for receiving/sending.
 * Returns: 0 on success, -1 on failure.
 */
EXPORT int vx_net_host(int port) {
    if (g_net.sock != NET_INVALID) {
        NET_CLOSE(g_net.sock);
        g_net.sock = NET_INVALID;
        g_net.is_bound = 0;
        g_net.is_connected = 0;
    }

    if (net_init_platform() < 0) {
        atomic_store_explicit(&g_net.last_error, -100, memory_order_release);
        return -1;
    }

    /* [FIXED] Use the cross-platform type instead of int */
    vx_socket_t sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);

    if (sock == NET_INVALID) {
        atomic_store_explicit(&g_net.last_error, NET_LASTERR, memory_order_release);
        return -1;
    }

    /* SO_REUSEADDR for rapid restarts */
    int opt = 1;
#if defined(_WIN32)
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, (const char*)&opt, sizeof(opt));
#else
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
#endif

    if (net_set_nonblocking(sock) < 0) {
        NET_CLOSE(sock);
        atomic_store_explicit(&g_net.last_error, NET_LASTERR, memory_order_release);
        return -1;
    }

    struct sockaddr_in local = {0};
    local.sin_family = AF_INET;
    local.sin_addr.s_addr = htonl(INADDR_ANY);
    local.sin_port = htons((uint16_t)port);

    if (bind(sock, (struct sockaddr*)&local, sizeof(local)) == NET_ERROR) {
        NET_CLOSE(sock);
        atomic_store_explicit(&g_net.last_error, NET_LASTERR, memory_order_release);
        return -1;
    }

    g_net.sock = sock;
    g_net.is_bound = 1;
    g_net.is_connected = 0;
    atomic_store_explicit(&g_net.last_error, 0, memory_order_release);

    fprintf(stderr, "[NET] UDP socket bound to port %d (fd=%d)\n", port, sock);
    return 0;
}

/**
 * vx_net_connect(const char* ip, int port)
 * Set remote destination for send_command(). Does NOT establish TCP-like connection.
 * Returns: 0 on success, -1 on failure.
 */
EXPORT int vx_net_connect(const char* ip, int port) {
    if (g_net.sock == NET_INVALID) {
        atomic_store_explicit(&g_net.last_error, -101, memory_order_release);
        return -1;
    }
    if (!ip || port < 1 || port > 65535) {
        atomic_store_explicit(&g_net.last_error, -102, memory_order_release);
        return -1;
    }

    g_net.remote_addr.sin_family = AF_INET;
    g_net.remote_addr.sin_port = htons((uint16_t)port);

    if (inet_pton(AF_INET, ip, &g_net.remote_addr.sin_addr) <= 0) {
        /* Fallback: try as hostname */
        struct hostent* he = gethostbyname(ip);
        if (!he || he->h_addrtype != AF_INET) {
            atomic_store_explicit(&g_net.last_error, NET_LASTERR, memory_order_release);
            return -1;
        }
        memcpy(&g_net.remote_addr.sin_addr, he->h_addr_list[0], he->h_length);
    }

    g_net.is_connected = 1;
    atomic_store_explicit(&g_net.last_error, 0, memory_order_release);

    fprintf(stderr, "[NET] Remote target set: %s:%d\n", ip, port);
    return 0;
}

// Send exactly 'len' bytes from the pointer
EXPORT void vx_net_send(const void* payload, size_t len) {
    if (g_net.sock == NET_INVALID || !payload) return;
    if (!g_net.is_connected) return;

    sendto(g_net.sock, (const char*)payload, len, 0,
           (struct sockaddr*)&g_net.remote_addr, g_net.remote_addr_len);
}

// Read exactly 'expected_len' bytes into the pointer
EXPORT int vx_net_poll(void* out_buffer, size_t expected_len) {
    if (g_net.sock == NET_INVALID || !out_buffer) return 0;

    struct sockaddr_in from;
    socklen_t from_len = sizeof(from);
    ssize_t recvd = recvfrom(g_net.sock, (char*)out_buffer, expected_len, 0, (struct sockaddr*)&from, &from_len);

    if (recvd == expected_len) {
        // [ATTACK VECTOR: LATCH DESTROYED]
        // We no longer overwrite g_net.remote_addr.
        // We trust the explicit connection made at boot.
        g_net.is_connected = 1;
        return 1;
    }

    return 0;
}

/**
 * vx_net_get_last_error(void)
 * Retrieve last socket error code for debugging.
 * Returns platform-specific error code or 0 if none.
 */
EXPORT int vx_net_get_last_error(void) {
    return atomic_load_explicit(&g_net.last_error, memory_order_acquire);
}

// The SSoT Rollback Arena
static RollbackBuffer g_rollback_arena = {0};

EXPORT RollbackBuffer* vx_net_get_arena(void) {
    return &g_rollback_arena;
}

// The core temporal pump. Lua calls this every fixed tick.
EXPORT void vx_net_commit_frame(uint32_t tick, uint32_t local_wasd, int32_t local_click) {
    uint32_t idx = tick & NET_RING_MASK;

    // 1. Log local reality
    g_rollback_arena.frames[idx].tick = tick;
    g_rollback_arena.frames[idx].local_input = local_wasd;
    g_rollback_arena.frames[idx].local_click = local_click; // [UPDATED]
    g_rollback_arena.head_tick = tick;

    // 2. Broadcast local reality over UDP
    LockstepPacket out_pkt = { tick, local_wasd, local_click };
    vx_net_send(&out_pkt, sizeof(LockstepPacket));

    // 3. Drain incoming network packets and collapse the quantum state
    LockstepPacket in_pkt;
    while (vx_net_poll(&in_pkt, sizeof(LockstepPacket))) {
        uint32_t r_idx = in_pkt.frame_tick & NET_RING_MASK;
        RollbackFrame* r_frame = &g_rollback_arena.frames[r_idx];

        // Temporal Fracture Check: Did they move OR click differently than we predicted?
        if (r_frame->state == FRAME_STATE_PREDICTED && r_frame->tick == in_pkt.frame_tick) {
            if (r_frame->remote_input != in_pkt.player_input || r_frame->remote_click != in_pkt.click_grid_idx) { // [UPDATED]
                if (!g_rollback_arena.is_rollback_active || in_pkt.frame_tick < g_rollback_arena.rollback_target) {
                    g_rollback_arena.is_rollback_active = 1;
                    g_rollback_arena.rollback_target = in_pkt.frame_tick; 
                }
            }
        }

        // Overwrite with confirmed reality
        r_frame->remote_input = in_pkt.player_input;
        r_frame->remote_click = in_pkt.click_grid_idx; // [NEW] Save the network click!
        r_frame->state = FRAME_STATE_CONFIRMED;

        if (in_pkt.frame_tick > g_rollback_arena.confirmed_tick) {
            g_rollback_arena.confirmed_tick = in_pkt.frame_tick;
        }
    }

    // 4. Predict the missing remote input for the CURRENT tick if it hasn't arrived
    if (g_rollback_arena.frames[idx].state != FRAME_STATE_CONFIRMED) {
        uint32_t prev_idx = (tick - 1) & NET_RING_MASK;
        g_rollback_arena.frames[idx].remote_input = g_rollback_arena.frames[prev_idx].remote_input;
        g_rollback_arena.frames[idx].remote_click = -1; // [NEW] Safest prediction: they didn't click.
        g_rollback_arena.frames[idx].state = FRAME_STATE_PREDICTED;
    }
}

EXPORT void vx_net_shutdown(void) {
    if (g_net.sock != NET_INVALID) {
        NET_CLOSE(g_net.sock);
        g_net.sock = NET_INVALID;
    }
    g_net.is_bound = 0;
    g_net.is_connected = 0;
    net_cleanup_platform();
    fprintf(stderr, "[NET] Socket shutdown complete.\n");
}
