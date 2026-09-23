/*
 * Copyright (c) 2026, librime-xcframework contributors
 * Distributed under the BSD 3-Clause License; see LICENSE.
 *
 * rime_varpage_api.h - variable-length candidate pages for librime.
 *
 * librime's built-in selector assumes every page holds menu/page_size
 * candidates: previous_page / next_page move by whole page_size steps, and the
 * select keys pick page_size-relative slots. That assumption cannot hold for a
 * candidate window laid out against the screen, where how many candidates fit
 * depends on how wide they are.
 *
 * This module replaces the component registered as "selector", so an existing
 * `engine/processors: - selector` entry picks it up unchanged, and asks the host
 * where the page boundaries are instead of deriving them from page_size.
 * Everything shaped by configuration is kept:
 *
 *   - the four binding sections (selector, selector/vertical, selector/linear,
 *     selector/vertical/linear), their defaults, and the action vocabulary
 *     previous_candidate, next_candidate, previous_page, next_page, home, end,
 *     noop - with noop still the way to unbind a default key;
 *   - menu/alternative_select_keys (read at key time, so a script rewriting it
 *     at runtime is honored), the digit and keypad fallback, and the quirk that
 *     a select key past the end of a page is still consumed;
 *   - menu/page_down_cycle, the _vertical / _linear / _horizontal options, and
 *     the "paging" tag the segment carries after a page turn or a candidate
 *     move, which is what enables key_binder's `when: paging` bindings.
 *
 * With no host involved, or when the host answers "unknown", the module falls
 * back to the built-in arithmetic, so it is a drop-in replacement.
 *
 * There is deliberately no configuration switch to turn it off. Whether pages
 * are variable is a rendering decision, so only the renderer may make it:
 * unregister the resolver, or answer false for the request at hand. A schema
 * author who disabled the module while the host still assumed variable-length
 * pages would get a silently misplaced highlight, which is the failure this
 * module exists to prevent.
 *
 * Getting the page boundaries in - the host either answers when asked, or
 * reports after rendering, or both:
 *
 *   - `set_resolver` installs a callback. It is called synchronously from
 *     inside key handling, so it must be cheap and must not call back into
 *     librime's mutating entry points (process_key, highlight, select,
 *     set_option, set_property, apply_schema); reading the candidate list with
 *     candidate_list_from_index / candidate_list_next is fine, including
 *     materializing the candidates it needs.
 *   - `set_page` reports the page currently on screen after a render. It is
 *     only used while the highlighted candidate lies inside the reported range,
 *     so a stale report is ignored rather than obeyed.
 *
 * A page must contain the index it is asked about, and pages should tile the
 * candidate list (each page starting where the previous one ended); the module
 * relies on that tiling to treat the end of a page as the start of the next.
 *
 * The module asks rarely. Moving the highlight by one candidate never consults
 * the resolver, and neither do home and end. A page turn resolves the page the
 * highlight is on and the page being turned to, so it costs one call when the
 * host has reported the current page as it renders - the recommended flow - and
 * two on a cold cache, such as the first page key after a retranslation.
 *
 * One model serves a whole keystroke: either both ends of the turn come from
 * the resolver, or the built-in menu/page_size arithmetic does. When a host
 * cannot place the page being turned to, that keystroke falls back; a host
 * should therefore answer for every page it has laid out, not only the visible
 * one.
 *
 * The module publishes the geometry it is using as session properties, so hosts
 * and Lua scripts read the same answer:
 *
 *   varpage.index   absolute index of the highlighted candidate
 *   varpage.start   first candidate of the page the highlight is on
 *   varpage.length  how many candidates that page holds
 *   varpage.source  "client" (host-reported) | "fallback" (built-in page) |
 *                   "stale"  (the highlight left the reported page; start and
 *                            length are the last published values)
 *
 * Publishing is active per session, from the first set_resolver or set_page
 * call: a session that never registered sees no property traffic at all.
 *
 * Note that writing a property calls the host's notification handler
 * synchronously, from inside key handling, and that handler runs while librime
 * holds its service lock: it must not call back into librime at all, not even
 * set_page or set_resolver (that self-deadlocks), and not process_key.
 *
 * Indices are absolute throughout, and that is what the host should use for
 * highlighting and selecting too: rime->highlight_candidate and
 * rime->select_candidate take absolute indices and stay correct here, while
 * rime->change_page and the *_on_current_page functions are hard-wired to the
 * built-in page_size arithmetic and must not be used with this module - use
 * turn_page for a page turn driven by the UI, so it goes through the same code
 * path as a page key and carries the same "paging" tag.
 *
 * Lifecycle: call clear_resolver before destroying the session. Without it a
 * registration outlives its session, and a later session whose context lands on
 * the same address could inherit it.
 */
#ifndef RIME_VARPAGE_API_H_
#define RIME_VARPAGE_API_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "rime_api.h"  // for RimeCustomApi / RimeModule / RimeSessionId

#ifdef __cplusplus
extern "C" {
#endif

// A page: `length` candidates starting at absolute index `start`. Must satisfy
// length > 0 and start <= index < start + length for the index it was resolved
// for.
typedef struct rime_varpage_page {
  size_t start;
  size_t length;
} RimeVarPage;

// Resolve the page holding the candidate at absolute index `index`.
//
// Called synchronously from inside key handling, only for indices known to hold
// a candidate. Return true and fill `page`, or return false to say "unknown" -
// the module then uses the built-in page_size arithmetic for that keystroke.
// `user_data` is what was passed to set_resolver.
//
// Do not call librime's mutating entry points from here (see the file comment);
// reading candidates is fine.
typedef bool (*RimeVarPageResolver)(void* user_data,
                                    RimeSessionId session_id,
                                    size_t index,
                                    RimeVarPage* page);

typedef struct rime_varpage_api_t {
  int data_size;

  // Install (or replace) the resolver for a session. Registration is what
  // turns the module on for that session. Returns false if the session has no
  // context yet, or if `resolver` is null.
  bool (*set_resolver)(RimeSessionId session_id,
                       RimeVarPageResolver resolver,
                       void* user_data);

  // Unregister a session's resolver and forget its reported page. Works after
  // the session is gone, so it is safe to call from a session-destroyed
  // callback. Returns false if the session had no registration.
  bool (*clear_resolver)(RimeSessionId session_id);

  // Report the page currently on screen for the highlighted candidate, after a
  // render. Also enables property publishing for a session that uses no
  // resolver (push-only mode). Returns false if `length` is zero or the session
  // has no candidate list.
  bool (*set_page)(RimeSessionId session_id, size_t start, size_t length);

  // Turn the page the way the page keys do, including page_down_cycle and the
  // "paging" tag. Returns true if the keystroke would have been consumed; the
  // resulting position is in the varpage.* properties.
  bool (*turn_page)(RimeSessionId session_id, bool backward);

  // Page holding `index`, resolved the same way key handling resolves it (that
  // is, the resolver may be called). Useful for laying out a render before any
  // key has arrived.
  bool (*query_page)(RimeSessionId session_id, size_t index, RimeVarPage* out);
} RimeVarPageApi;

#ifdef __cplusplus
}
#endif

#endif  // RIME_VARPAGE_API_H_
