//
// Copyright (c) 2026, librime-xcframework contributors
// Distributed under the BSD 3-Clause License; see LICENSE.
//
// Page geometry, the per-session host resolver table, and the page actions the
// replacement selector delegates to. Every index here is absolute; see
// rime_varpage_api.h for the host-facing contract.
//
#ifndef RIME_VARPAGE_PAGES_H_
#define RIME_VARPAGE_PAGES_H_

#include "rime_varpage_api.h"

namespace rime {

class Context;
class Schema;

namespace varpage {

struct PageGeometry {
  size_t start = 0;
  size_t length = 0;

  size_t end() const { return start + length; }
  bool Contains(const size_t index) const {
    return index >= start && index - start < length;
  }
};

// Host-facing entry points, called by the module's C API.
bool SetResolver(RimeSessionId session_id,
                 RimeVarPageResolver resolver,
                 void* user_data);
bool ClearResolver(RimeSessionId session_id);

// Records that `switcher_context` belongs to a schema switcher and that the
// engine it was opened over uses `attached_context`. Called by the selector
// instance a switcher creates, and undone by its destructor.
//
// Registration needs this because while the panel is open Session::context()
// reports the panel's own context: filing the host's resolver there would put
// it where only panel keys can reach it, and the composing engine would
// silently fall back to fixed pages for the rest of the session.
void PublishSwitcherContext(Context* switcher_context,
                            Context* attached_context);
void UnpublishSwitcherContext(Context* switcher_context);

// Action entry points. `allow_host` is false for the selector instance a schema
// switcher owns: the panel has its own menu, the host has not laid it out, and
// asking would hand back geometry for a composition the host does not know
// about.
//
// Filing registrations against the composing engine (see
// PublishSwitcherContext) is what keeps the panel from having anything to ask
// in the first place, so this is a second line of defense rather than the fix -
// no test isolates it. It is kept because the cost is a flag and the failure it
// prevents is a host being asked about a menu it never laid out.
bool PreviousPage(const Schema* schema, Context* ctx, bool allow_host);
bool NextPage(const Schema* schema, Context* ctx, bool allow_host);
bool SelectCandidateAt(const Schema* schema,
                       Context* ctx,
                       int slot,
                       bool allow_host);

// Keeps the published highlight in step with the context. Connected to the
// context's update and select notifiers; never calls the host.
void OnContextChanged(Context* ctx);

// Drops every registration. Called from the module's finalize.
void Reset();

}  // namespace varpage
}  // namespace rime

#endif  // RIME_VARPAGE_PAGES_H_
