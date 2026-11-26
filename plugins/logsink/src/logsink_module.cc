//
// Copyright (c) 2026, librime-xcframework contributors
// Distributed under the BSD 3-Clause License; see LICENSE.
//
// Module registration and the C API the host reaches through
// rime->find_module("logsink")->get_api().
//
#include <mutex>
#include <optional>

#include <rime/build_config.h>
#include <rime_logsink_api.h>

#include <rime/common.h>
#ifdef RIME_ENABLE_LOGGING
#include <rime/logging.h>
#endif
#include <rime/setup.h>  // for rime::LoadModules in RIME_REGISTER_MODULE_GROUP

#include "log_sink.h"

using namespace rime;

namespace {

bool rime_logsink_add_sink(void* context, rime_logsink_callback callback) {
#ifdef RIME_ENABLE_LOGGING
  return LogSinkFanout::Instance().Add(context, callback);
#else
  // The module still registers so its API exists, but a build without logging
  // has no backend to attach a sink to.
  (void)context;
  (void)callback;
  return false;
#endif
}

bool rime_logsink_remove_sink(void* context) {
#ifdef RIME_ENABLE_LOGGING
  return LogSinkFanout::Instance().Remove(context);
#else
  (void)context;
  return false;
#endif
}

bool rime_logsink_set_stderr_threshold(rime_logsink_threshold threshold) {
#ifdef RIME_ENABLE_LOGGING
  // The backend's threshold type has no "off" state: no severity value silences
  // stderr, so SILENT is represented by an empty optional. Translate here so
  // callers never deal in out-of-range values.
  std::optional<LogSeverity> level;
  switch (threshold) {
    case RIME_LOGSINK_SILENT:
      level = std::nullopt;
      break;
    case RIME_LOGSINK_AT_INFO:
      level = LogSeverity::Info;
      break;
    case RIME_LOGSINK_AT_WARNING:
      level = LogSeverity::Warning;
      break;
    case RIME_LOGSINK_AT_ERROR:
      level = LogSeverity::Error;
      break;
    case RIME_LOGSINK_AT_FATAL:
      level = LogSeverity::Fatal;
      break;
    default:
      return false;
  }
  return SetStderrLogSeverityThreshold(level);
#else
  (void)threshold;
  return false;
#endif
}

RimeLogSinkApi* rime_logsink_get_api() {
  // std::call_once rather than a data_size guard: a concurrent first call could
  // otherwise observe data_size set while the function pointers were still
  // null.
  static std::once_flag once;
  static RimeLogSinkApi api = {0};
  std::call_once(once, [] {
    RIME_STRUCT_INIT(RimeLogSinkApi, api);
    api.add_sink = &rime_logsink_add_sink;
    api.remove_sink = &rime_logsink_remove_sink;
    api.set_stderr_threshold = &rime_logsink_set_stderr_threshold;
  });
  return &api;
}

}  // namespace

static void rime_logsink_initialize() {}

static void rime_logsink_finalize() {}

RIME_REGISTER_CUSTOM_MODULE(logsink) {
  module->get_api = reinterpret_cast<RimeCustomApi* (*)()>(
      &rime_logsink_get_api);
}
