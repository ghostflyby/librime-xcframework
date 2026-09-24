//
// Copyright (c) 2026, librime-xcframework contributors
// Distributed under the BSD 3-Clause License; see LICENSE.
//
#ifndef RIME_VARPAGE_SELECTOR_H_
#define RIME_VARPAGE_SELECTOR_H_

#include <rime/common.h>
#include <rime/gear/selector.h>

namespace rime {

// Drop-in replacement for the built-in selector. Same configuration surface,
// same action vocabulary, same keymap defaults and fallback rules, all
// inherited unchanged from Selector; the only difference is where page
// boundaries come from - the host, or the built-in menu/page_size arithmetic
// when the host has nothing to say.
class VarPageSelector : public Selector {
 public:
  explicit VarPageSelector(const Ticket& ticket);
  ~VarPageSelector() override;

  ProcessResult ProcessKeyEvent(const KeyEvent& key_event) override;

 private:
  // Deliberately not named PreviousPage/NextPage/SelectCandidateAt: those are
  // the built-in members this class replaces for two of the three entry points
  // only (previous_candidate, next_candidate, home and end never read the page
  // size). Sharing the names would hide the base versions and invite the reader
  // to assume the whole action set moved.
  bool TurnPreviousPage(Context* ctx) const;
  bool TurnNextPage(Context* ctx) const;
  bool SelectSlot(Context* ctx, int slot) const;

  // Keeps the published highlight in step with the context.
  connection update_connection_;
  connection select_connection_;

  // The context this instance serves, and whether it belongs to a schema
  // switcher. A switcher creates its own selector for the schema-list menu, and
  // that instance must not consult the host: the panel is the switcher's own
  // composition, which the host has not laid out and knows nothing about.
  //
  // Both are captured at construction rather than read later. The context is
  // also what the destructor uses to withdraw the switcher's registration, and
  // by then the Engine base subobject this instance was handed is being torn
  // down.
  Context* own_context_ = nullptr;
  bool switcher_instance_ = false;
};

}  // namespace rime

#endif  // RIME_VARPAGE_SELECTOR_H_
