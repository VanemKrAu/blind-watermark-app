cmake_minimum_required(VERSION 3.18)
project(flutter_blind_watermark VERSION 0.0.1 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)

# Get the parent directory (plugin root)
# CMAKE_CURRENT_SOURCE_DIR is android/src/main/cpp
# So we need to go up 4 levels to get to plugin root
get_filename_component(PLUGIN_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../.." ABSOLUTE)

message(STATUS "CMAKE_CURRENT_SOURCE_DIR: ${CMAKE_CURRENT_SOURCE_DIR}")
message(STATUS "PLUGIN_ROOT: ${PLUGIN_ROOT}")

# Verify source files exist
if(NOT EXISTS "${PLUGIN_ROOT}/src/image_io.cpp")
    message(FATAL_ERROR "Source file not found: ${PLUGIN_ROOT}/src/image_io.cpp")
endif()

# libwebp path
set(WEBP_ROOT "${PLUGIN_ROOT}/third_party/libwebp-1.3.2")

# libwebp decoder source files
file(GLOB WEBP_DEC_SOURCES "${WEBP_ROOT}/src/dec/*.c")
file(GLOB WEBP_DSP_SOURCES "${WEBP_ROOT}/src/dsp/*.c")
file(GLOB WEBP_UTILS_SOURCES "${WEBP_ROOT}/src/utils/*.c")
file(GLOB WEBP_ENC_SOURCES "${WEBP_ROOT}/src/enc/*.c")
file(GLOB SHARPYUV_SOURCES "${WEBP_ROOT}/sharpyuv/*.c")

# Source files
set(SOURCES
    "${PLUGIN_ROOT}/src/image_io.cpp"
    "${PLUGIN_ROOT}/src/color_convert.cpp"
    "${PLUGIN_ROOT}/src/dct.cpp"
    "${PLUGIN_ROOT}/src/dwt.cpp"
    "${PLUGIN_ROOT}/src/numpy_rng.cpp"
    "${PLUGIN_ROOT}/src/watermark_core.cpp"
    "${PLUGIN_ROOT}/src/blind_watermark_ffi.cpp"
    ${WEBP_DEC_SOURCES}
    ${WEBP_DSP_SOURCES}
    ${WEBP_UTILS_SOURCES}
    ${WEBP_ENC_SOURCES}
    ${SHARPYUV_SOURCES}
)

# Create shared library
add_library(flutter_blind_watermark SHARED ${SOURCES})

# Add WEBP_HAVE_NEON for ARM platforms
if(CMAKE_ANDROID_ARCH_ABI STREQUAL "arm64-v8a" OR CMAKE_ANDROID_ARCH_ABI STREQUAL "armeabi-v7a")
    target_compile_definitions(flutter_blind_watermark PRIVATE WEBP_HAVE_NEON)
endif()

# Enable WebP support macro
target_compile_definitions(flutter_blind_watermark PRIVATE BWM_HAVE_WEBP)

# Include directories
target_include_directories(flutter_blind_watermark PRIVATE
    "${PLUGIN_ROOT}/src"
    "${PLUGIN_ROOT}/third_party"
    "${PLUGIN_ROOT}/third_party/Eigen"
    "${WEBP_ROOT}"
    "${WEBP_ROOT}/src"
)

# Compiler flags - maximum optimization with NEON
target_compile_options(flutter_blind_watermark PRIVATE
    -O3
    -ffast-math
    -ftree-vectorize
    -fomit-frame-pointer
    -funroll-loops
    -fPIC
    -fvisibility=default
    -flto
    -Wall
    -Wextra
    -Wno-unused-parameter
)

# ARM64 specific optimizations (NOT for armeabi-v7a: armv8 instructions are
# illegal on 32-bit ARM and would crash on such devices)
if(CMAKE_ANDROID_ARCH_ABI STREQUAL "arm64-v8a")
    target_compile_options(flutter_blind_watermark PRIVATE
        -march=armv8-a+simd
    )
endif()

# Eigen optimizations - enable vectorization
target_compile_definitions(flutter_blind_watermark PRIVATE
    EIGEN_NO_DEBUG=1
    NDEBUG=1
    EIGEN_DONT_PARALLELIZE=0
)

# Linker flags - LTO and symbol export
target_link_options(flutter_blind_watermark PRIVATE
    -Wl,--no-undefined
    -flto
    -O3
)

# Link against Android log library
find_library(log-lib log)
target_link_libraries(flutter_blind_watermark ${log-lib})

# Set output name
set_target_properties(flutter_blind_watermark PROPERTIES
    OUTPUT_NAME "flutter_blind_watermark"
)
