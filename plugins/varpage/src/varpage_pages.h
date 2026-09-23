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

#include <stddef.h>

#include "rime_varpage_api.h"

namespace rime {

class Context;
class Schema;

namespace varpage {

struct PageGeometry {
  size_t start = 0;
  size_t length = 0;

  size_t end() const { return start + length; }
  bool Contains(size_t index) const {
    return index >= start && index - start < length;
  }
};

// Host-facing entry points, called by the module's C API.
bool SetResolver(RimeSessionId session_id,
                 RimeVarPageResolver resolver,
                 void* user_data);
bool ClearResolver(RimeSessionId session_id);

// Action entry points, each of which falls back to the built-in page_size
// arithmetic when the host does not answer.
bool PreviousPage(Schema* schema, Context* ctx);
bool NextPage(Schema* schema, Context* ctx);
bool SelectCandidateAt(Schema* schema, Context* ctx, int slot);

// Keeps the published highlight in step with the context. Connected to the
// context's update and select notifiers; never calls the host.
void OnContextChanged(Context* ctx);

// Drops every registration. Called from the module's finalize.
void Reset();

}  // namespace varpage
}  // namespace rime

#endif  // RIME_VARPAGE_PAGES_H_
