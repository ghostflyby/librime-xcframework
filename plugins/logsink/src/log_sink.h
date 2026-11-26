//
// Copyright (c) 2026, librime-xcframework contributors
// Distributed under the BSD 3-Clause License; see LICENSE.
//
#ifndef RIME_LOGSINK_LOG_SINK_H_
#define RIME_LOGSINK_LOG_SINK_H_

#include <map>
#include <shared_mutex>

#include <rime/build_config.h>
#include <rime_logsink_api.h>

#ifdef RIME_ENABLE_LOGGING
#include <rime/logging.h>
#endif

namespace rime {

#ifdef RIME_ENABLE_LOGGING

// The single sink registered with librime's logging backend, fanning records
// out to the callbacks hosts register through the C API. Process-wide.
class LogSinkFanout : public LogSink {
 public:
  static LogSinkFanout& Instance();

  bool Add(void* context, rime_logsink_callback callback);
  bool Remove(void* context);

  // LogSink:
  void Send(LogSeverity severity,
            const char* file,
            int line,
            const std::string& message) override;

 private:
  LogSinkFanout();
  ~LogSinkFanout() override;

  std::shared_mutex mutex_;
  std::map<void*, rime_logsink_callback> callbacks_;
};

#endif  // RIME_ENABLE_LOGGING

}  // namespace rime

#endif  // RIME_LOGSINK_LOG_SINK_H_
