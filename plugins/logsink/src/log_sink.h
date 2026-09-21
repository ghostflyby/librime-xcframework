//
// Copyright (c) 2026, librime-xcframework contributors
// Distributed under the BSD 3-Clause License; see LICENSE.
//
#ifndef RIME_LOGSINK_LOG_SINK_H_
#define RIME_LOGSINK_LOG_SINK_H_

#include <memory>

#include <rime_logsink_api.h>

namespace rime {

// Owns the single glog sink that fans records out to registered callbacks.
// Process-wide, like glog itself.
class LogSink {
 public:
  static LogSink& Instance();

  bool Add(void* context, rime_logsink_callback callback);
  bool Remove(void* context);

 private:
  LogSink();
  ~LogSink();

  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace rime

#endif  // RIME_LOGSINK_LOG_SINK_H_
