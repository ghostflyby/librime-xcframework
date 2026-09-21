# Copyright (c) 2026, librime-xcframework contributors
# Distributed under the BSD 3-Clause License; see LICENSE.
#
# Follows librime's plugin contract (see rime-new-plugin.sh / sample/): this
# directory defines plugin_name, plugin_objs, plugin_deps and plugin_modules for
# the parent plugins/CMakeLists.txt. With BUILD_MERGED_PLUGINS=ON the objects are
# merged into librime itself, which is what lets the sink reach glog: glog's
# symbols are hidden in the dynamic artifacts, so only code compiled into the
# library can register a LogSink.
project(rime-logsink)
cmake_minimum_required(VERSION 3.10)

aux_source_directory(src logsink_src)

add_library(rime-logsink-objs OBJECT ${logsink_src})
if(BUILD_SHARED_LIBS)
  set_target_properties(rime-logsink-objs
    PROPERTIES
    POSITION_INDEPENDENT_CODE ON)
endif()

target_include_directories(rime-logsink-objs
  PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/include")

set(plugin_name rime-logsink PARENT_SCOPE)
set(plugin_objs $<TARGET_OBJECTS:rime-logsink-objs> PARENT_SCOPE)
set(plugin_deps ${rime_library} PARENT_SCOPE)
set(plugin_modules "logsink" PARENT_SCOPE)
