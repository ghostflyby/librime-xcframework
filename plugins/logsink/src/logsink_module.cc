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

void rime_logsink_disable_file_logging() {
  // An empty destination means "do not log this severity to a file".
  for (int severity = google::GLOG_INFO; severity < google::NUM_SEVERITIES;
       ++severity) {
    google::SetLogDestination(static_cast<google::LogSeverity>(severity), "");
  }
}

void rime_logsink_set_stderr_severity(int severity) {
  if (severity < 0) {
    severity = 0;
  }
  // glog treats a threshold above FATAL as "nothing to stderr".
  if (severity > google::GLOG_FATAL) {
    severity = google::GLOG_FATAL + 1;
  }
  google::SetStderrLogging(static_cast<google::LogSeverity>(severity));
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
    api.disable_file_logging = &rime_logsink_disable_file_logging;
    api.set_stderr_severity = &rime_logsink_set_stderr_severity;
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
