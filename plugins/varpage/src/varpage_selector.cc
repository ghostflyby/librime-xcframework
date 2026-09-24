//
// Copyright (c) 2026, librime-xcframework contributors
// Distributed under the BSD 3-Clause License; see LICENSE.
//
#include "varpage_selector.h"

#include <rime/composition.h>
#include <rime/context.h>
#include <rime/engine.h>
#include <rime/key_event.h>
#include <rime/key_table.h>
#include <rime/schema.h>
#include <rime/switcher.h>

#include "varpage_pages.h"

namespace rime {

namespace {

// The two options that pick one of the four keymaps, as in the built-in selector.
bool IsVerticalText(Context* ctx) {
  return ctx->get_option("_vertical");
}

bool IsLinearLayout(Context* ctx) {
  return ctx->get_option("_linear") ||
         // Deprecated. equivalent to {_linear: true, _vertical: false}
         ctx->get_option("_horizontal");
}

}  // namespace

VarPageSelector::VarPageSelector(const Ticket& ticket) : Selector(ticket) {
  // A schema switcher is itself an Engine and builds its own processors with
  // Ticket(this), so this instance's engine is the switcher and its context is the
  // panel's. Upstream identifies a switcher the same way, in the two translators
  // that drive the schema list.
  if (auto* switcher = dynamic_cast<Switcher*>(engine_)) {
    switcher_instance_ = true;
    // Record which composing engine the panel was opened over, so a host that
    // registers while the panel is up is filed against the engine it will be
    // asking about rather than against the panel.
    varpage::PublishSwitcherContext(engine_->context(),
                                    switcher->attached_engine()
                                        ? switcher->attached_engine()->context()
                                        : nullptr);
  }

  own_context_ = engine_->context();
  if (own_context_) {
    update_connection_ = own_context_->update_notifier().connect(
        [](Context* ctx) { varpage::OnContextChanged(ctx); });
    select_connection_ = own_context_->select_notifier().connect(
        [](Context* ctx) { varpage::OnContextChanged(ctx); });
  }
}

VarPageSelector::~VarPageSelector() {
  update_connection_.disconnect();
  select_connection_.disconnect();
  if (switcher_instance_)
    varpage::UnpublishSwitcherContext(own_context_);
}

ProcessResult VarPageSelector::ProcessKeyEvent(const KeyEvent& key_event) {
  // The same gates the built-in selector applies before it looks at the keymaps.
  // They are repeated here rather than inherited because the page actions have to
  // be intercepted before the base impl can reach its page_size arithmetic; the
  // other actions, which never read the page size, fall through to the base impl
  // below.
  if (key_event.release() || key_event.alt() || key_event.super())
    return kNoop;
  Context* ctx = engine_->context();
  if (ctx->composition().empty())
    return kNoop;
  Segment& current_segment(ctx->composition().back());
  if (!current_segment.menu || current_segment.HasTag("raw"))
    return kNoop;

  TextOrientation text_orientation = IsVerticalText(ctx) ? Vertical : Horizontal;
  CandidateListLayout candidate_list_layout =
      IsLinearLayout(ctx) ? Linear : Stacked;
  auto& keymap = get_keymap(text_orientation | candidate_list_layout);

  // A binding the config pointed at a page action is ours to serve. When the
  // action declines - as the built-in one does for some states - the key keeps
  // falling through to the select keys and then to the base impl, exactly as it
  // would have without the interception.
  auto binding = keymap.find(key_event);
  if (binding != keymap.end()) {
    if (binding->second == &Selector::PreviousPage) {
      if (TurnPreviousPage(ctx))
        return kAccepted;
    } else if (binding->second == &Selector::NextPage) {
      if (TurnNextPage(ctx))
        return kAccepted;
    } else {
      // Any other action - previous_candidate, next_candidate, home, end - is the
      // base's to run, and handing the key over reproduces the built-in exactly:
      // the base runs keymap bindings *before* the select keys, so a key bound to
      // one of these behaves as it always did, including falling back to the
      // built-in slot arithmetic if the action declines.
      //
      // Computing the slot here instead would shadow the binding: a key bound to,
      // say, next_candidate would select a candidate rather than move.
      return Selector::ProcessKeyEvent(key_event);
    }
  }
  // A key the config unbound with `noop` is not in the keymap at all, so it
  // reaches the select keys, as it does in the built-in.

  // The select keys. Their slot arithmetic is page-relative, so this is the third
  // and last page-dependent entry point and has to be computed here; the base impl
  // would resolve the slot against a fixed page.
  int ch = key_event.keycode();
  int slot = -1;
  // Read at key time, not cached at construction: a script is allowed to swap the
  // select keys for the duration of one keystroke.
  const string& select_keys(engine_->schema()->select_keys());
  if (!select_keys.empty() && !key_event.ctrl() && ch >= 0x20 && ch < 0x7f) {
    size_t pos = select_keys.find((char)ch);
    if (pos != string::npos)
      slot = static_cast<int>(pos);
  } else if (ch >= XK_0 && ch <= XK_9) {
    slot = ((ch - XK_0) + 9) % 10;
  } else if (ch >= XK_KP_0 && ch <= XK_KP_9) {
    slot = ((ch - XK_KP_0) + 9) % 10;
  }
  if (slot >= 0) {
    SelectSlot(ctx, slot);
    // Consumed whether or not anything was selected: a slot past the end of the
    // page does not fall through to the application.
    return kAccepted;
  }

  return Selector::ProcessKeyEvent(key_event);
}

bool VarPageSelector::TurnPreviousPage(Context* ctx) {
  return varpage::PreviousPage(engine_->schema(), ctx, !switcher_instance_);
}

bool VarPageSelector::TurnNextPage(Context* ctx) {
  return varpage::NextPage(engine_->schema(), ctx, !switcher_instance_);
}

bool VarPageSelector::SelectSlot(Context* ctx, int slot) {
  return varpage::SelectCandidateAt(engine_->schema(), ctx, slot,
                                    !switcher_instance_);
}

}  // namespace rime
