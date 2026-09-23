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
