cmake_minimum_required(VERSION 3.20)
project(aivr-ai-mobile-host VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

find_package(Crow CONFIG REQUIRED)
find_package(nlohmann_json CONFIG REQUIRED)
find_package(spdlog CONFIG REQUIRED)

# For Mobile (FFI), we will likely export a C API
add_library(${PROJECT_NAME} SHARED
    src/mobile_bridge.cpp
)

target_include_directories(${PROJECT_NAME} PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_link_libraries(${PROJECT_NAME} PRIVATE
    nlohmann_json::nlohmann_json
    spdlog::spdlog
)

# Testing
enable_testing()

add_executable(test_mobile_bridge tests/test_mobile_bridge.cpp)
target_link_libraries(test_mobile_bridge PRIVATE ${PROJECT_NAME})

add_test(NAME MobileStatusTest COMMAND test_mobile_bridge)

install(TARGETS ${PROJECT_NAME} DESTINATION lib)
