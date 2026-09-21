//
// Copyright (c) 2026, librime-xcframework contributors
// Distributed under the BSD 3-Clause License; see LICENSE.
//
// The sink itself: a glog LogSink that fans records out to the registered C
// callbacks. It owns no destination of its own - deciding where records go is
// the host's business.
//
// It must be compiled into librime (a merged plugin). glog sets
// CMAKE_CXX_VISIBILITY_PRESET hidden and GLOG_EXPORT expands empty outside DLL
// builds, so AddLogSink is a local symbol in the dynamic artifacts: code inside
// the library can reach it, code outside cannot.
//
#include "log_sink.h"

#include <glog/logging.h>

#include <chrono>
#include <map>
#include <mutex>
#include <shared_mutex>

namespace rime {

class LogSink::Impl : public google::LogSink {
 public:
  Impl() {
    // Registered for the lifetime of the process. The LogMessageTime-based
    // send() overload is used rather than the deprecated std::tm one: the tm in
    // the deprecated overload is local time (or UTC under FLAGS_log_utc_time),
    // so reconstructing an instant from it was ambiguous across DST boundaries.
    google::AddLogSink(this);
  }

  ~Impl() override { google::RemoveLogSink(this); }

  bool Add(void* context, rime_logsink_callback callback) {
    if (!callback) {
      return false;
    }
    std::unique_lock<std::shared_mutex> lock(mutex_);
    return callbacks_.emplace(context, callback).second;
  }

  bool Remove(void* context) {
    std::unique_lock<std::shared_mutex> lock(mutex_);
    return callbacks_.erase(context) > 0;
  }

  void send(google::LogSeverity severity, const char* full_filename,
            const char* base_filename, int line,
            const google::LogMessageTime& time, const char* message,
            size_t message_len) override {
    rime_logsink_record record;
    record.severity = static_cast<int>(severity);
    record.message = message;
    record.message_length = message_len;
    record.base_filename = base_filename;
    record.full_filename = full_filename;
    record.line = line;
    record.unix_time_millis = static_cast<int64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(
            time.when().time_since_epoch())
            .count());
    record.utc_offset_seconds = static_cast<int>(time.gmtoffset().count());

    // Held across delivery (shared, so concurrent logging threads still run in
    // parallel) to match glog's own discipline: glog takes its sink lock shared
    // across send() and exclusively for Add/RemoveLogSink, which is what makes
    // removal a lifetime barrier. Delivering after unlocking instead would let a
    // host free its context while a callback for it was still in flight.
    std::shared_lock<std::shared_mutex> lock(mutex_);
    for (const auto& entry : callbacks_) {
      entry.second(entry.first, &record);
    }
  }

 private:
  std::shared_mutex mutex_;
  std::map<void*, rime_logsink_callback> callbacks_;
};

LogSink& LogSink::Instance() {
  // Deliberately leaked: glog keeps a raw pointer to the sink, and glog's own
  // statics may outlive a function-local static, so destroying this at exit
  // would leave a dangling entry that any late LOG() (a static destructor, an
  // atexit handler, a detached worker) would dereference.
  static LogSink* instance = new LogSink;
  return *instance;
}

bool LogSink::Add(void* context, rime_logsink_callback callback) {
  return impl_->Add(context, callback);
}

bool LogSink::Remove(void* context) {
  return impl_->Remove(context);
}

LogSink::LogSink() : impl_(new Impl) {}

LogSink::~LogSink() = default;

}  // namespace rime
