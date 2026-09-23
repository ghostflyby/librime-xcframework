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
  bool TurnPreviousPage(Context* ctx);
  bool TurnNextPage(Context* ctx);
  bool SelectSlot(Context* ctx, int slot);

  // Kept connected so a highlight moved by something other than a page action -
  // an arrow key, a filter pass, a script - invalidates the page the host
  // reported, rather than leaving it to be trusted for a position it never
  // described.
  connection update_connection_;
  connection select_connection_;
};

}  // namespace rime

#endif  // RIME_VARPAGE_SELECTOR_H_
