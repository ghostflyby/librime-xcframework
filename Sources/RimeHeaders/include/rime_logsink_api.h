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
 * Taking over completely (all verified against the shipped artifacts):
 *
 *   traits.modules       = the modules to load, including "logsink";
 *   traits.log_dir       = "";   // librime's own switch: never write files
 *   traits.min_log_level = 0;    // filtering here also drops records from
 *                                // sinks, so leave it at INFO
 *   rime->setup(&traits);
 *   api->set_stderr_threshold(RIME_LOGSINK_SILENT);   // after setup(), see below
 *   api->add_sink(context, callback);
 *   rime->initialize(&traits);
 *
 * That combination produced no files, no stderr output, and all 60 records
 * delivered to the sink in a session that loaded the default modules plus the
 * lua, octagram and predict plugins.
 *
 * Three things to know:
 *
 *  - The sink API is available as soon as the library is loaded, before
 *    rime->setup(): module registration runs from a constructor. Install early
 *    to capture the component-registration logging that setup() and
 *    initialize() produce. (Static linking is the exception: the host's
 *    earliest reliable call site is main(), because constructor order follows
 *    link order. Records emitted before that are structurally uncapturable by
 *    any in-process sink; in the current librime that window is empty, as its
 *    module constructors only register and do not log.)
 *
 *  - `traits.log_dir = ""` does two things: it stops file logging, and it
 *    raises glog's stderr threshold to INFO. Call set_stderr_threshold AFTER
 *    setup() so your value is not overwritten. Note also that log_dir is
 *    one-way at the glog level - there is no supported way to re-enable file
 *    logging afterwards, which is why this API offers no counterpart.
 *
 *  - SILENT is not "severity zero". Thresholds live in a separate enum whose
 *    values are deliberately offset from the severity values, because a
 *    threshold needs one more state ("off") than a record can have.
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

// swift_name and enum_extensibility are Clang attributes; GCC and other
// compilers do not know them and would warn "attribute directive ignored" under
// -Wattributes. Both are purely a Swift-facing annotation layer, so compiling
// them away costs C and C++ consumers nothing.
#if defined(__has_attribute)
#  if __has_attribute(swift_name)
#    define RIME_LOGSINK_SWIFT_NAME(x) __attribute__((swift_name(x)))
#  else
#    define RIME_LOGSINK_SWIFT_NAME(x)
#  endif
#  if __has_attribute(enum_extensibility)
#    define RIME_LOGSINK_ENUM_EXTENSIBILITY(x) \
      __attribute__((enum_extensibility(x)))
#  else
#    define RIME_LOGSINK_ENUM_EXTENSIBILITY(x)
#  endif
#else
#  define RIME_LOGSINK_SWIFT_NAME(x)
#  define RIME_LOGSINK_ENUM_EXTENSIBILITY(x)
#endif

// The fixed underlying type below is standard in C23 and in C++11 onwards, but
// an extension in earlier C modes. `__extension__` suppresses the resulting
// diagnostic there; it is a GCC/Clang keyword, so any other compiler gets an
// empty expansion rather than a syntax error.
#if defined(__GNUC__) || defined(__clang__)
#  define RIME_LOGSINK_EXTENSION __extension__
#else
#  define RIME_LOGSINK_EXTENSION
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Severity of a record. Values match glog's ordering, so they can be compared
// and used as an index directly. The underlying type is a fixed-width one so
// the ABI is pinned to 4 bytes on every platform rather than to whatever the
// compiler derives for the current value set.
//
// __extension__ marks the fixed underlying type as a deliberate extension: it
// is C23 syntax, so without this a -pedantic build in C99/C11 mode warns
// (-Wc23-extensions). The marker only silences that diagnostic - the
// representation, the values, and the Swift import are unchanged.
RIME_LOGSINK_EXTENSION typedef enum
    RIME_LOGSINK_SWIFT_NAME("RimeLogSinkSeverity")
    RIME_LOGSINK_ENUM_EXTENSIBILITY(closed) rime_logsink_severity : uint32_t {
  RIME_LOGSINK_INFO RIME_LOGSINK_SWIFT_NAME("info") = 0,
  RIME_LOGSINK_WARNING RIME_LOGSINK_SWIFT_NAME("warning") = 1,
  RIME_LOGSINK_ERROR RIME_LOGSINK_SWIFT_NAME("error") = 2,
  RIME_LOGSINK_FATAL RIME_LOGSINK_SWIFT_NAME("fatal") = 3,
} rime_logsink_severity;

// Threshold for an output: the lowest severity it will emit. Distinct from
// rime_logsink_severity because "off" is a state an output can be in and a
// record can never be. The numeric values are offset by one from the severity
// values on purpose - do not cast between the two types.
// __extension__ here for the same reason as above.
RIME_LOGSINK_EXTENSION typedef enum
    RIME_LOGSINK_SWIFT_NAME("RimeLogSinkThreshold")
    RIME_LOGSINK_ENUM_EXTENSIBILITY(closed) rime_logsink_threshold : uint32_t {
  // Emit nothing at this output, whatever the severity.
  RIME_LOGSINK_SILENT RIME_LOGSINK_SWIFT_NAME("silent") = 0,
  // Emit this severity and above. In C the AT_ prefix is required because
  // enumerators share one namespace, and it doubles as a reminder that a
  // threshold is "at this level and above"; Swift cases are namespaced by their
  // type, so there the names are simply .info/.warning/.error/.fatal.
  RIME_LOGSINK_AT_INFO RIME_LOGSINK_SWIFT_NAME("info") = 1,
  RIME_LOGSINK_AT_WARNING RIME_LOGSINK_SWIFT_NAME("warning") = 2,
  RIME_LOGSINK_AT_ERROR RIME_LOGSINK_SWIFT_NAME("error") = 3,
  RIME_LOGSINK_AT_FATAL RIME_LOGSINK_SWIFT_NAME("fatal") = 4,
} rime_logsink_threshold;

// One log record. Pointers are valid only for the duration of the callback;
// copy anything you need to keep.
typedef struct rime_logsink_record {
  rime_logsink_severity severity;

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
// nor call set_stderr_threshold, which takes glog's non-recursive log mutex.
// Keep it short: glog holds a lock for the duration of every callback, so slow
// work delays the logging thread and other sinks; hand anything non-trivial to
// your own queue.
typedef void (*rime_logsink_callback)(void* context,
                                      const rime_logsink_record* record);

typedef struct rime_logsink_api_t {
  int data_size;

  // Append a sink. `context` identifies it for removal and is passed through to
  // the callback; it must stay valid until remove_sink returns (glog's sink
  // lock makes that a lifetime barrier, so nothing is in flight afterwards).
  // Returns false for a null callback or a context that is already installed.
  // Sinks are additive: existing sinks, and any built-in output that is still
  // enabled, keep working.
  //
  // Note what this implies for the host: records may contain user input (typed
  // keys, dictionary entries), and deciding what to persist, what to redact and
  // where to send it is the callback's job, not this module's.
  bool (*add_sink)(void* context, rime_logsink_callback callback);

  // Remove the sink registered with `context`. Other sinks are untouched.
  // Returns false if no sink used that context.
  bool (*remove_sink)(void* context);

  // Set the lowest severity glog writes to stderr, or SILENT for none at all.
  // Process-wide: glog's threshold is a global, so this also affects the host's
  // own glog usage. Useful when the host collects stderr too, where glog's
  // stderr copy of every message would otherwise be recorded twice.
  //
  // Call this after rime->setup(): `traits.log_dir = ""` raises the threshold
  // to INFO as a side effect, which would overwrite a value set earlier.
  bool (*set_stderr_threshold)(rime_logsink_threshold threshold);
} RimeLogSinkApi;

#ifdef __cplusplus
}
#endif

#endif  // RIME_LOGSINK_API_H_
