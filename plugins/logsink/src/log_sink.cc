//
// Copyright (c) 2026, librime-xcframework contributors
// Distributed under the BSD 3-Clause License; see LICENSE.
//
// The sink itself: the LogSink this module registers with librime's logging
// backend, fanning records out to the registered C callbacks. It owns no
// destination of its own - deciding where records go is the host's business.
//
// It must be compiled into librime (a merged plugin): the logging header is
// internal to the library, so only code compiled into it can register a sink.
//
#include "log_sink.h"

#include <rime/build_config.h>

#include <chrono>
#include <ctime>

namespace rime {
namespace {

int64_t UnixTimeMillis() {
  using namespace std::chrono;
  return duration_cast<milliseconds>(system_clock::now().time_since_epoch())
      .count();
}

// Seconds east of UTC at `now`. The packaged spdlog is built with vcpkg's
// tz-offset feature, which compiles its %z support out, so the offset comes
// from the C library instead.
int UtcOffsetSeconds(std::time_t now) {
  std::tm local = {};
  localtime_r(&now, &local);
  return static_cast<int>(local.tm_gmtoff);
}

const char* BaseFilename(const char* file) {
  const char* base = file;
  for (const char* p = file; *p != '\0'; ++p) {
    if (*p == '/' || *p == '\\') {
      base = p + 1;
    }
  }
  return base;
}

}  // namespace

LogSinkFanout& LogSinkFanout::Instance() {
  // Deliberately leaked: the logging backend keeps a raw pointer to the sink,
  // and its own statics may outlive a function-local static, so destroying this
  // at exit would leave a dangling entry that any late LOG() (a static
  // destructor, an atexit handler, a detached worker) would dereference.
  static LogSinkFanout* instance = new LogSinkFanout;
  return *instance;
}

LogSinkFanout::LogSinkFanout() {
  // The hook symbols exist only when logging is compiled in. A tree built with
  // ENABLE_LOGGING=OFF still gets the module and its callback map, but there is
  // no backend to attach to.
#ifdef RIME_ENABLE_LOGGING
  AddLogSink(this);
#endif
}

LogSinkFanout::~LogSinkFanout() {
#ifdef RIME_ENABLE_LOGGING
  RemoveLogSink(this);
#endif
}

bool LogSinkFanout::Add(void* context, rime_logsink_callback callback) {
  if (!callback) {
    return false;
  }
  std::unique_lock<std::shared_mutex> lock(mutex_);
  return callbacks_.emplace(context, callback).second;
}

bool LogSinkFanout::Remove(void* context) {
  std::unique_lock<std::shared_mutex> lock(mutex_);
  return callbacks_.erase(context) > 0;
}

void LogSinkFanout::Send(LogSeverity severity,
                         const char* file,
                         int line,
                         const std::string& message) {
  const char* source_file = file != nullptr ? file : "";
  rime_logsink_record record;
  // LogSeverity and rime_logsink_severity share the same ordering, so this maps
  // directly. The intermediate cast is explicit because both are distinct enum
  // types.
  record.severity = static_cast<rime_logsink_severity>(
      static_cast<int>(severity));
  record.message = message.data();
  record.message_length = message.size();
  record.base_filename = BaseFilename(source_file);
  record.full_filename = source_file;
  record.line = line;
  const std::time_t now = std::time(nullptr);
  record.unix_time_millis = UnixTimeMillis();
  record.utc_offset_seconds = UtcOffsetSeconds(now);

  // Held across delivery (shared, so concurrent logging threads still run in
  // parallel) so that Remove is a lifetime barrier: once it returns, no
  // callback for that context is in flight. The backend holds its own lock
  // across Send for the same reason.
  std::shared_lock<std::shared_mutex> lock(mutex_);
  for (const auto& entry : callbacks_) {
    entry.second(entry.first, &record);
  }
}

}  // namespace rime
