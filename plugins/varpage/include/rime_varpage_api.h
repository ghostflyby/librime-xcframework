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
 * With no host registered, or when the host answers "unknown", the module falls
 * back to the built-in arithmetic, so it is a drop-in replacement.
 *
 * There is deliberately no configuration switch to turn it off. Whether pages
 * are variable is a rendering decision, so only the renderer may make it:
 * unregister the resolver, or answer false for the request at hand. A schema
 * author who disabled the module while the host still assumed variable-length
 * pages would get a silently misplaced highlight, which is the failure this
 * module exists to prevent.
 *
 * Only one thing is asked of the host: answer, for a candidate index, which page
 * contains it. Everything else the module does with page geometry is derived
 * from that, and everything the host does with pages it already knows - it is
 * the side computing the layout. In particular:
 *
 *   - Pages are not pushed in. The host owns the layout, so it holds the answer
 *     already; a copy of it inside the module would be a second source of truth
 *     to keep valid across rendering, filters and re-segmentation.
 *   - Page turns are not delegated. A host-driven turn is the host moving its
 *     own highlight with rime->highlight_candidate, which takes an absolute
 *     index and needs no help from here.
 *   - There is no index-to-page query. A host that computes pages can answer
 *     that question itself.
 *
 * What the module does not do is notice a highlight the host moved by itself:
 * see the note on the "paging" tag below.
 *
 * The resolver is called synchronously from inside key handling, so it must be
 * cheap and must not call back into librime's mutating entry points
 * (process_key, highlight, select, set_option, set_property, apply_schema);
 * reading the candidate list with candidate_list_from_index / candidate_list_next
 * is fine, including materializing the candidates it needs. Whether it
 * precomputes layout or computes on demand is the host's choice.
 *
 * The module asks rarely. Moving the highlight by one candidate never consults
 * the resolver, and neither do home and end. A page turn resolves the page the
 * highlight is on and the page being turned to, so it costs two calls; a select
 * key costs one.
 *
 * The module publishes the highlight as a session property, so a host and any
 * Lua script read the same answer:
 *
 *   varpage.index   absolute index of the highlighted candidate
 *   varpage.source  "client" when the host's pages determined the most recent
 *                   page move, "fallback" when the built-in page_size
 *                   arithmetic did
 *
 * Both are cleared when the composition ends. Publishing starts with the
 * registration, so a session that never registers sees no property traffic.
 *
 * Note that writing a property calls the host's notification handler
 * synchronously, from inside key handling, and that handler runs while librime
 * holds its service lock: it must not call back into librime at all, not even
 * set_resolver (that self-deadlocks), and not process_key.
 *
 * Indices are absolute throughout, and that is what the host should use for
 * highlighting and selecting too: rime->highlight_candidate and
 * rime->select_candidate take absolute indices and stay correct here, while
 * rime->change_page and the *_on_current_page functions are hard-wired to the
 * built-in page_size arithmetic and must not be used with this module.
 *
 * One consequence of that, worth knowing before relying on it: the segment's
 * "paging" tag, which is what makes key_binder's `when: paging` bindings fire,
 * is set by moves the module makes - the page keys and the candidate keys. A
 * move the host makes itself, with highlight_candidate, does not set it, and
 * neither did the built-in selector's candidate moves. So a configuration that
 * expects `-` and `,` to turn pages is driven by the keyboard; a host that moves
 * the highlight from its own UI should treat those keys as input. (The C API's
 * change_page does set the tag, so a host migrating off it is moving away from
 * that behaviour rather than onto it.)
 *
 * Registration is against the session, and it stays with the session: changing
 * schema rebuilds the processors but leaves the registration in place, and
 * registering while the schema switcher is open files against the composing
 * engine rather than the switcher, so the panel neither loses your registration
 * nor asks you about its own schema list.
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
// Called synchronously from inside key handling. Only ever called for indices
// known to hold a candidate. Return true and fill `page`, or return false to say
// "unknown" - the module then uses the built-in page_size arithmetic for that
// keystroke. `user_data` is what was passed to set_resolver.
//
// The returned page must contain `index`, and pages must tile the candidate
// list: the page after a given one begins where that one ends. Page Down relies
// on that, because it asks about the candidate just past the current page and
// carries the highlight's offset into whatever page comes back - an answer that
// starts earlier would move the highlight backwards, so such an answer is
// declined and the built-in arithmetic serves that keystroke instead. (Page Up
// asks about the candidate just before the current page, which already forces an
// answer that starts no later than that, so it needs no such check.)
//
// Do not call librime's mutating entry points from here (see the file comment);
// reading candidates is fine.
typedef bool (*RimeVarPageResolver)(void* user_data,
                                    RimeSessionId session_id,
                                    size_t index,
                                    RimeVarPage* page);

typedef struct rime_varpage_api_t {
  int data_size;

  // Install (or replace) the resolver for a session. Registration is what turns
  // the module on for that session. Returns false if the session has no context
  // yet, or if `resolver` is null.
  bool (*set_resolver)(RimeSessionId session_id,
                       RimeVarPageResolver resolver,
                       void* user_data);

  // Unregister a session's resolver. Works after the session is gone, so it is
  // safe to call from a session-destroyed callback. Returns false if the session
  // had no registration.
  bool (*clear_resolver)(RimeSessionId session_id);
} RimeVarPageApi;

#ifdef __cplusplus
}
#endif

#endif  // RIME_VARPAGE_API_H_
