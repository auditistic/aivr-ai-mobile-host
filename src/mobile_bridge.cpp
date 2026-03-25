#include <spdlog/spdlog.h>
#include <nlohmann/json.hpp>
#include <string>
#include <mutex>
#include <atomic>
#include <chrono>
#include <cstring>

using json = nlohmann::json;

// ---------------------------------------------------------------------------
// AIVR Core Bridge — FFI surface for Flutter (Platform Channels / dart:ffi)
//
// This module exposes a C ABI that the Flutter host calls to:
//   1. Register / deregister this node with the AIVR mesh (Port 12000).
//   2. Report token usage so the Orchestrator can credit the node.
//   3. Relay available model metadata to the mesh for discovery.
//   4. Provide a health heartbeat for the Service-Relay (Port 9800).
// ---------------------------------------------------------------------------

namespace {

// --- Node state -----------------------------------------------------------
struct NodeState {
    std::string node_id;           // UUID assigned at registration
    std::string mesh_host;         // AIVR mesh endpoint (IP:port)
    std::string relay_host;        // Service-Relay endpoint
    std::atomic<bool> registered{false};
    std::atomic<int64_t> tokens_in{0};
    std::atomic<int64_t> tokens_out{0};
    std::atomic<int64_t> requests_served{0};
    std::chrono::steady_clock::time_point boot_time;
    json active_models = json::array();
    std::mutex models_mtx;
};

static NodeState g_state;

// Thread-safe scratch buffer for returning strings across FFI.
static std::mutex g_buf_mtx;
static std::string g_buf;

const char* return_string(const std::string& s) {
    std::lock_guard<std::mutex> lock(g_buf_mtx);
    g_buf = s;
    return g_buf.c_str();
}

} // anonymous namespace

// ---------------------------------------------------------------------------
// FFI entry points
// ---------------------------------------------------------------------------
extern "C" {

// --- Lifecycle ------------------------------------------------------------

/// Returns a human-readable status string (kept for backward compat).
const char* get_mobile_status() {
    if (g_state.registered.load()) {
        return "AIVR Mobile Node REGISTERED on mesh";
    }
    return "AIVR Mobile Backend (C++ Native) Active — not registered";
}

/// One-time initialisation.  Call before any other function.
///   config_json: `{ "mesh_host": "...", "relay_host": "..." }`
/// Returns 0 on success, -1 on error.
int initialize_mobile_service(const char* config_json) {
    try {
        g_state.boot_time = std::chrono::steady_clock::now();

        if (config_json && std::strlen(config_json) > 0) {
            auto cfg = json::parse(config_json);
            g_state.mesh_host  = cfg.value("mesh_host",  "127.0.0.1:12000");
            g_state.relay_host = cfg.value("relay_host", "127.0.0.1:9800");
        } else {
            g_state.mesh_host  = "127.0.0.1:12000";
            g_state.relay_host = "127.0.0.1:9800";
        }

        spdlog::info("AIVR Mobile Bridge initialised  mesh={} relay={}",
                      g_state.mesh_host, g_state.relay_host);
        return 0;
    } catch (const std::exception& e) {
        spdlog::error("initialize_mobile_service failed: {}", e.what());
        return -1;
    }
}

// --- Mesh registration ----------------------------------------------------

/// Register this node on the AIVR mesh.
///   node_json: `{ "node_id": "...", "ip": "...", "port": 8080,
///                  "models": [ { "id": "...", "name": "...", ... } ] }`
/// Returns the registration payload (JSON string) or error JSON.
const char* aivr_register_node(const char* node_json) {
    try {
        auto payload = json::parse(node_json);
        g_state.node_id = payload.value("node_id", "unknown");

        {
            std::lock_guard<std::mutex> lock(g_state.models_mtx);
            if (payload.contains("models")) {
                g_state.active_models = payload["models"];
            }
        }

        g_state.registered.store(true);

        json response = {
            {"status",  "registered"},
            {"node_id", g_state.node_id},
            {"mesh",    g_state.mesh_host},
            {"relay",   g_state.relay_host},
            {"model_count", g_state.active_models.size()},
        };

        spdlog::info("Node {} registered with {} model(s)",
                      g_state.node_id, g_state.active_models.size());
        return return_string(response.dump());
    } catch (const std::exception& e) {
        json err = {{"status", "error"}, {"message", e.what()}};
        spdlog::error("aivr_register_node: {}", e.what());
        return return_string(err.dump());
    }
}

/// Deregister this node (e.g. server stop / app background).
const char* aivr_deregister_node() {
    g_state.registered.store(false);
    spdlog::info("Node {} deregistered", g_state.node_id);

    json response = {{"status", "deregistered"}, {"node_id", g_state.node_id}};
    return return_string(response.dump());
}

// --- Token reporting ------------------------------------------------------

/// Report token usage for a single request so AIVR Core can credit the node.
///   usage_json: `{ "tokens_in": N, "tokens_out": N, "model_id": "..." }`
void aivr_report_tokens(const char* usage_json) {
    try {
        auto u = json::parse(usage_json);
        int64_t tin  = u.value("tokens_in",  0);
        int64_t tout = u.value("tokens_out", 0);

        g_state.tokens_in.fetch_add(tin);
        g_state.tokens_out.fetch_add(tout);
        g_state.requests_served.fetch_add(1);

        spdlog::debug("Token report: in={} out={} model={}",
                       tin, tout, u.value("model_id", "unknown"));
    } catch (const std::exception& e) {
        spdlog::error("aivr_report_tokens: {}", e.what());
    }
}

// --- Model relay ----------------------------------------------------------

/// Update the list of models this node advertises to the mesh.
///   models_json: JSON array of model objects.
void aivr_update_models(const char* models_json) {
    try {
        auto models = json::parse(models_json);
        std::lock_guard<std::mutex> lock(g_state.models_mtx);
        g_state.active_models = models;
        spdlog::info("Model list updated: {} model(s)", models.size());
    } catch (const std::exception& e) {
        spdlog::error("aivr_update_models: {}", e.what());
    }
}

/// Return the current model list as a JSON string.
const char* aivr_get_models() {
    try {
        std::lock_guard<std::mutex> lock(g_state.models_mtx);
        return return_string(g_state.active_models.dump());
    } catch (const std::exception& e) {
        return return_string("[]");
    }
}

// --- Heartbeat / stats ----------------------------------------------------

/// Return a JSON blob with node health for the Service-Relay heartbeat.
const char* aivr_get_node_health() {
    try {
        auto now = std::chrono::steady_clock::now();
        auto uptime_s = std::chrono::duration_cast<std::chrono::seconds>(
                            now - g_state.boot_time).count();

        json health = {
            {"node_id",         g_state.node_id},
            {"registered",      g_state.registered.load()},
            {"uptime_seconds",  uptime_s},
            {"tokens_in",       g_state.tokens_in.load()},
            {"tokens_out",      g_state.tokens_out.load()},
            {"requests_served", g_state.requests_served.load()},
            {"mesh_host",       g_state.mesh_host},
            {"relay_host",      g_state.relay_host},
        };

        {
            std::lock_guard<std::mutex> lock(g_state.models_mtx);
            health["model_count"] = g_state.active_models.size();
        }

        return return_string(health.dump());
    } catch (const std::exception& e) {
        json err = {{"status", "error"}, {"message", e.what()}};
        return return_string(err.dump());
    }
}

} // extern "C"
