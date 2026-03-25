cmake_minimum_required(VERSION 3.20)
project(aivr-ai-mobile-host VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

find_package(Crow CONFIG REQUIRED)
find_package(nlohmann_json CONFIG REQUIRED)
find_package(spdlog CONFIG REQUIRED)

# AIVR Core Bridge — Shared library exposing C ABI for Flutter FFI.
# Exports: node registration, token reporting, model relay, health heartbeat.
add_library(${PROJECT_NAME} SHARED
    src/mobile_bridge.cpp
)

# Platform-specific export macros (no __declspec on non-Windows)
if(NOT WIN32)
    target_compile_definitions(${PROJECT_NAME} PRIVATE
        "AIVR_EXPORT=__attribute__((visibility(\"default\")))"
    )
    set_target_properties(${PROJECT_NAME} PROPERTIES
        CXX_VISIBILITY_PRESET hidden
    )
else()
    target_compile_definitions(${PROJECT_NAME} PRIVATE
        "AIVR_EXPORT=__declspec(dllexport)"
    )
endif()

target_include_directories(${PROJECT_NAME} PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_link_libraries(${PROJECT_NAME} PRIVATE
    nlohmann_json::nlohmann_json
    spdlog::spdlog
)

install(TARGETS ${PROJECT_NAME} DESTINATION lib)
