# Copyright (c) 2026, librime-xcframework contributors
# Distributed under the BSD 3-Clause License; see LICENSE.
#
# Follows librime's plugin contract (see rime-new-plugin.sh / sample/): this
# directory defines plugin_name, plugin_objs, plugin_deps and plugin_modules for
# the parent plugins/CMakeLists.txt. With BUILD_MERGED_PLUGINS=ON the objects are
# merged into librime itself, which is what lets the module replace the built-in
# "selector" component registered by gears.
project(rime-varpage)
cmake_minimum_required(VERSION 3.10)

aux_source_directory(src varpage_src)

add_library(rime-varpage-objs OBJECT ${varpage_src})
if(BUILD_SHARED_LIBS)
  set_target_properties(rime-varpage-objs
    PROPERTIES
    POSITION_INDEPENDENT_CODE ON)
endif()

target_include_directories(rime-varpage-objs
  PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/include")

# rime_gears_library, not just rime_library: this module subclasses the built-in
# Selector, which lives in the gears library when BUILD_SEPARATE_LIBS is on.
set(plugin_name rime-varpage PARENT_SCOPE)
set(plugin_objs $<TARGET_OBJECTS:rime-varpage-objs> PARENT_SCOPE)
set(plugin_deps ${rime_library} ${rime_gears_library} PARENT_SCOPE)
set(plugin_modules "varpage" PARENT_SCOPE)

# The behavioral test joins the same ctest run as upstream's suite, so "run the
# tests" is one command and one report rather than two mechanisms.
#
# It is registered as a test *command* rather than built as a target here
# because of an ordering constraint: this file is processed from
# add_subdirectory(plugins), which upstream does before add_subdirectory(src)
# creates the rime target - so an executable here could not link it. The test
# therefore compiles itself when ctest runs it, linking the library that was just
# built. That is also why it is not a gtest binary: gtest is for fixtures and
# assertions in-process, while this one needs a built library and a live session,
# which is exactly what the runner gives it.
#
# BUILD_TEST is set only by the repository's test mode, so an artifact build
# neither builds nor registers anything here; BUILD_SHARED_LIBS because the test
# links the shared library rather than the static archive.
if(BUILD_TEST AND BUILD_SHARED_LIBS)
  add_test(NAME varpage_behavioral
    COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/tests/run.sh"
            --build-dir "${CMAKE_BINARY_DIR}")
endif()
