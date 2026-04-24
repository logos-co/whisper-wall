cmake_minimum_required(VERSION 3.20)
project(whisper-wall-ui LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ── Framework build (Basecamp plugin builder) ─────────────────────────────────
if(DEFINED ENV{LOGOS_MODULE_BUILDER_ROOT})
    include($ENV{LOGOS_MODULE_BUILDER_ROOT}/cmake/LogosModule.cmake)

    logos_module(
        NAME whisper_wall
        SOURCES
            src/WhisperWallPlugin.h
            src/WhisperWallPlugin.cpp
            src/WhisperWallBackend.h
            src/WhisperWallBackend.cpp
        EXTERNAL_LIBS whisper_wall_ffi
    )

# ── Manual build (development / standalone) ───────────────────────────────────
else()
    set(CMAKE_AUTOMOC ON)

    find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets Quick QuickWidgets Qml Concurrent)

    # Location of the compiled Rust cdylib (build with: cargo build --release in ui/ffi/).
    # Override via -DWHISPER_WALL_FFI_LIB_DIR=... or set env var of same name.
    if(DEFINED ENV{WHISPER_WALL_FFI_LIB_DIR})
        set(WHISPER_WALL_FFI_LIB_DIR "$ENV{WHISPER_WALL_FFI_LIB_DIR}")
    elseif(NOT DEFINED WHISPER_WALL_FFI_LIB_DIR)
        set(WHISPER_WALL_FFI_LIB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/ffi/target/release")
    endif()

    set(PLUGIN_TARGET whisper_wall_plugin)

    qt_add_plugin(${PLUGIN_TARGET} CLASS_NAME WhisperWallPlugin)

    target_sources(${PLUGIN_TARGET} PRIVATE
        src/WhisperWallPlugin.cpp
        src/WhisperWallBackend.cpp
    )

    qt_add_resources(${PLUGIN_TARGET} "whisper_wall_qml"
        PREFIX "/qml"
        BASE "qml"
        FILES qml/Main.qml
    )

    if(NOT LOGOS_CPP_SDK_ROOT)
        set(LOGOS_CPP_SDK_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../logos-cpp-sdk")
    endif()

    target_include_directories(${PLUGIN_TARGET} PRIVATE
        ${LOGOS_CPP_SDK_ROOT}/include
        ${LOGOS_CPP_SDK_ROOT}/include/cpp
        ${LOGOS_CPP_SDK_ROOT}/include/core
        ${CMAKE_CURRENT_SOURCE_DIR}/src
    )

    target_link_directories(${PLUGIN_TARGET} PRIVATE "${WHISPER_WALL_FFI_LIB_DIR}")

    target_link_libraries(${PLUGIN_TARGET} PRIVATE
        Qt6::Core Qt6::Gui Qt6::Widgets Qt6::Quick Qt6::QuickWidgets
        Qt6::Qml Qt6::Concurrent
        whisper_wall_ffi
    )

    if(APPLE)
        set_target_properties(${PLUGIN_TARGET} PROPERTIES
            BUILD_RPATH   "@loader_path"
            INSTALL_RPATH "@loader_path"
        )
    elseif(UNIX)
        set_target_properties(${PLUGIN_TARGET} PROPERTIES
            BUILD_RPATH   "$ORIGIN"
            INSTALL_RPATH "$ORIGIN"
        )
    endif()

    install(TARGETS ${PLUGIN_TARGET}
        LIBRARY DESTINATION lib
    )
    install(FILES "${WHISPER_WALL_FFI_LIB_DIR}/libwhisper_wall_ffi.so"
        DESTINATION lib
    )
endif()
