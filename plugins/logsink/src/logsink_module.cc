//
// Copyright (c) 2026, librime-xcframework contributors
// Distributed under the BSD 3-Clause License; see LICENSE.
//
// Module registration and the C API the host reaches through
// rime->find_module("logsink")->get_api().
//
#include <glog/logging.h>

#include <mutex>

#include <rime_logsink_api.h>

#include <rime/common.h>
#include <rime/setup.h>  // for rime::LoadModules in RIME_REGISTER_MODULE_GROUP

#include "log_sink.h"

using namespace rime;

namespace {

bool rime_logsink_add_sink(void* context, rime_logsink_callback callback) {
  return LogSink::Instance().Add(context, callback);
}

bool rime_logsink_remove_sink(void* context) {
  return LogSink::Instance().Remove(context);
}

bool rime_logsink_set_stderr_threshold(rime_logsink_threshold threshold) {
  // glog's threshold is a plain int global, and it has no "off" state: a value
  // above FATAL is what silences it, because the comparison is
  // `severity >= threshold`. Translate our enum here so callers never deal in
  // out-of-range values.
  int glog_threshold;
  switch (threshold) {
    case RIME_LOGSINK_SILENT:
      glog_threshold = google::NUM_SEVERITIES;  // above FATAL
      break;
    case RIME_LOGSINK_AT_INFO:
      glog_threshold = google::GLOG_INFO;
      break;
    case RIME_LOGSINK_AT_WARNING:
      glog_threshold = google::GLOG_WARNING;
      break;
    case RIME_LOGSINK_AT_ERROR:
      glog_threshold = google::GLOG_ERROR;
      break;
    case RIME_LOGSINK_AT_FATAL:
      glog_threshold = google::GLOG_FATAL;
      break;
    default:
      return false;
  }
  google::SetStderrLogging(static_cast<google::LogSeverity>(glog_threshold));
  return true;
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
