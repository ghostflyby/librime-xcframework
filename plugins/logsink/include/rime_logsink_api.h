/*
 * Copyright (c) 2026, librime-xcframework contributors
 * Distributed under the BSD 3-Clause License; see LICENSE.
 *
 * rime_logsink_api.h - a neutral log sink interface for librime.
 *
 * librime logs through glog. glog's sinks are additive: any number of sinks can
 * be registered, every sink receives every record, and glog's own file/stderr
 * logging keeps working alongside them. This module exposes that as a plain C
 * callback, so a host application can forward librime's diagnostics into
 * whatever logging system it already uses - os.Logger, a ring buffer, a
 * file - without linking glog itself, without depending on librime's private
 * headers, and without this library choosing a destination or a privacy policy
 * on the host's behalf.
 *
 * One flavor only: plain stdbool `bool`, no RIME_FLAVORED variant. This header
 * is C and C++ compatible and is safe to import from Swift.
 */
#ifndef RIME_LOGSINK_API_H_
#define RIME_LOGSINK_API_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "rime_api.h"  // for RimeCustomApi / RimeModule

#ifdef __cplusplus
extern "C" {
#endif

// Severity levels, aligned with glog's ordering.
enum rime_logsink_severity {
  RIME_LOGSINK_INFO = 0,
  RIME_LOGSINK_WARNING = 1,
  RIME_LOGSINK_ERROR = 2,
  RIME_LOGSINK_FATAL = 3,
};

// One log record. Pointers are valid only for the duration of the callback;
// copy anything you need to keep.
typedef struct rime_logsink_record {
  int severity;  // rime_logsink_severity

  // Message text. `message_length` excludes the trailing newline, but the text
  // may contain embedded newlines. There is no terminating NUL guarantee for
  // arbitrary content, so treat it as a counted buffer.
  const char* message;
  size_t message_length;

  const char* base_filename;  // e.g. "selector.cc"
  const char* full_filename;  // path as written at the call site
  int line;

  // Milliseconds since the Unix epoch, UTC.
  int64_t unix_time_millis;
  // Local timezone offset in seconds at the moment of the log call.
  int utc_offset_seconds;
} rime_logsink_record;

// Invoked for every record, in the context of the logging call.
//
// Thread-safety: callbacks run on whichever thread executed the log statement,
// and may run concurrently on several threads, so a callback must synchronize
// its own state. It must also not call back into librime's logging (a
// synchronous LOG() would re-enter glog while it holds its lock and deadlock),
// nor call `disable_file_logging`/`set_stderr_severity`, which take glog's
// non-recursive log mutex. Keep it short: glog holds a lock for the duration of
// every callback, so slow work delays the logging thread and other sinks; hand
// anything non-trivial to your own queue.
typedef void (*rime_logsink_callback)(void* context,
                                      const rime_logsink_record* record);

typedef struct rime_logsink_api_t {
  int data_size;

  // Append a sink. `context` identifies it for removal and is passed through to
  // the callback; it must stay valid until remove_sink returns (glog's sink
  // lock makes that a lifetime barrier, so nothing is in flight afterwards).
  // Installing the same context twice is refused. Sinks are additive: existing
  // sinks, and glog's own file/stderr logging, keep working.
  //
  // Note what this implies for the host: records may contain user input (typed
  // keys, dictionary entries), and deciding what to persist, what to redact and
  // where to send it is the callback's job, not this module's.
  bool (*add_sink)(void* context, rime_logsink_callback callback);

  // Remove the sink registered with `context`. Other sinks are untouched.
  // Returns false if no sink used that context.
  bool (*remove_sink)(void* context);

  // Suppress glog's own file logging for all severities. Process-wide: glog
  // state is global, so this also affects the host's own glog usage.
  void (*disable_file_logging)(void);

  // Set the minimum severity glog writes to stderr. RIME_LOGSINK_FATAL keeps
  // only fatal messages. Process-wide, as above. Useful when forwarding to a
  // log system that also collects stderr, where glog's stderr copy of every
  // ERROR would otherwise appear twice.
  void (*set_stderr_severity)(int severity);
} RimeLogSinkApi;

#ifdef __cplusplus
}
#endif

#endif  // RIME_LOGSINK_API_H_
