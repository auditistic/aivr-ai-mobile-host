#include <spdlog/spdlog.h>
#include <nlohmann/json.hpp>

#ifdef _WIN32
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default")))
#endif

extern "C" {
    // FFI entry point for Flutter
    EXPORT const char* get_mobile_status() {
        return "AIVR Mobile Backend (C++ Native) Active";
    }

    EXPORT void initialize_mobile_service() {
        spdlog::info("Mobile Host Service initializing...");
    }
}
