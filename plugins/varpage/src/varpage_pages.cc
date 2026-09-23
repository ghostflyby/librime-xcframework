//
// Copyright (c) 2026, librime-xcframework contributors
// Distributed under the BSD 3-Clause License; see LICENSE.
//
#include "varpage_pages.h"

#include <algorithm>
#include <map>
#include <mutex>
#include <string>

#include <rime/common.h>
#include <rime/composition.h>
#include <rime/context.h>
#include <rime/menu.h>
#include <rime/schema.h>
#include <rime/service.h>

namespace rime {
namespace varpage {

namespace {

const char kIndexProperty[] = "varpage.index";
const char kSourceProperty[] = "varpage.source";

const char kSourceClient[] = "client";
const char kSourceFallback[] = "fallback";

struct Entry {
  RimeSessionId session_id = 0;
  RimeVarPageResolver resolver = nullptr;
  void* user_data = nullptr;
};

struct Table {
  std::mutex mutex;
  std::map<Context*, Entry> by_context;
  std::map<RimeSessionId, Context*> by_session;
};

// Deliberately never destroyed: registrations outlive any teardown order the
// host picks, and a static destructor would only create a race with it.
Table& table() {
  static Table* instance = new Table;
  return *instance;
}

size_t PageSize(Schema* schema) {
  const int page_size = schema ? schema->page_size() : 0;
  return page_size > 0 ? static_cast<size_t>(page_size) : 1;
}

// The built-in page: `page_size` candidates aligned to a multiple of
// page_size. The last page is left short rather than clipped, exactly as the
// built-in selector leaves it, so Highlight and Select clamp as before.
PageGeometry FixedPage(Schema* schema, size_t index) {
  const size_t page_size = PageSize(schema);
  return PageGeometry{index / page_size * page_size, page_size};
}

// Whether the registration belongs to a session that no longer exists, and so
// is safe to drop.
//
// The only evidence of that is the service not knowing the session any more.
// Everything else must be treated as alive, because the tempting alternative -
// asking whether the session's *current* context is the one the entry is filed
// under - gives the wrong answer routinely: a session's active engine is the
// schema switcher while its panel is open, so opening the switcher would look
// like "the context changed" and a purge would throw away the host's resolver
// and user_data for the rest of the session. A registration is not invalid
// because another engine is momentarily on top.
//
// The service also refuses lookups while it is disabled (during maintenance),
// which is likewise not evidence of anything; that case keeps the entry too.
//
// Consequence worth stating: a destroyed session whose id is handed to a new
// session is indistinguishable from a live one here, because the id is the
// session's address and nothing else remains to compare. That is why
// clear_resolver is a requirement rather than tidy-up.
bool Gone(const Entry& entry) {
  if (Service::instance().GetSession(entry.session_id))
    return false;
  return !Service::instance().disabled();
}

// Finds the entry for `ctx`, dropping it when the registration behind it belongs
// to a session that no longer exists. Every accessor goes through here rather
// than through the map directly, so a registration left by a destroyed session
// cannot serve a successor merely because the address came back.
//
// Only a definite "gone" drops anything. An unknown answer leaves the entry
// alone: the cost of keeping a stale entry is one wasted lookup, while the cost
// of dropping a live one is the host's resolver and user_data lost for the rest
// of the session.
//
// Caller holds the lock.
Entry* Find(Context* ctx, Table& t) {
  auto it = t.by_context.find(ctx);
  if (it == t.by_context.end())
    return nullptr;
  if (Gone(it->second)) {
    t.by_session.erase(it->second.session_id);
    t.by_context.erase(it);
    return nullptr;
  }
  return &it->second;
}

// Copies the entry for `ctx` out of the table, dropping it if its session is
// gone. A copy rather than a reference because the resolver is called without
// the lock held.
bool Lookup(Context* ctx, Entry* entry) {
  Table& t = table();
  std::lock_guard<std::mutex> lock(t.mutex);
  Entry* found = Find(ctx, t);
  if (!found)
    return false;
  *entry = *found;
  return true;
}

bool Registered(Context* ctx) {
  Table& t = table();
  std::lock_guard<std::mutex> lock(t.mutex);
  return Find(ctx, t) != nullptr;
}

// Points a session at the context it is using now, creating the registration if
// this is the first call. The caller holds the lock.
//
// Two things have to be true afterwards: a session that switched engines -
// ApplySchema builds a new one - must not leave the old context holding its
// registration, and two sessions must never share one, so that a later
// clear_resolver for a previous occupant cannot unregister the current one. The
// reclaim loop drops any other id still naming this context, and an entry filed
// under a different id is reset rather than inherited.
void Retarget(Context* ctx, RimeSessionId session_id, Table& t) {
  for (auto it = t.by_session.begin(); it != t.by_session.end();) {
    if (it->first != session_id && it->second == ctx)
      it = t.by_session.erase(it);
    else
      ++it;
  }

  auto previous = t.by_session.find(session_id);
  if (previous != t.by_session.end() && previous->second != ctx)
    t.by_context.erase(previous->second);
  t.by_session[session_id] = ctx;

  Entry& entry = t.by_context[ctx];
  if (entry.session_id != session_id)
    entry = Entry{};
  entry.session_id = session_id;
}

void UpsertResolver(Context* ctx,
                    RimeSessionId session_id,
                    RimeVarPageResolver resolver,
                    void* user_data) {
  Table& t = table();
  std::lock_guard<std::mutex> lock(t.mutex);
  Retarget(ctx, session_id, t);
  Entry& entry = t.by_context[ctx];
  entry.resolver = resolver;
  entry.user_data = user_data;
}

// Writes a property only when it changes: every write reaches the host's
// notification handler synchronously, so a redundant one is a wasted round trip
// through the host.
void WriteProperty(Context* ctx, const char* name, const std::string& value) {
  if (ctx->get_property(name) == value)
    return;
  ctx->set_property(name, value);
}

// Writes an empty value, which readers see as "not set" (RimeGetProperty
// reports false for an empty string). Used when there is no composition, so a
// host is not left reading the highlight of a composition that has ended.
void Unpublish(Context* ctx) {
  WriteProperty(ctx, kIndexProperty, std::string());
  WriteProperty(ctx, kSourceProperty, std::string());
}

void PublishIndex(Context* ctx) {
  Composition& comp = ctx->composition();
  if (comp.empty()) {
    Unpublish(ctx);
    return;
  }
  WriteProperty(ctx, kIndexProperty,
                std::to_string(comp.back().selected_index));
}

// Publishes the outcome of a page action. `from_host` says whether the host's
// pages determined this keystroke - that is, whether the resolver answered for
// the position the highlight was on - which is the question a host debugging its
// own layout is asking. Only page actions write the source, so it always names
// the model behind the most recent page move.
void PublishDecision(Context* ctx, size_t landed, bool from_host) {
  // Nothing is published for a session that never registered: the properties are
  // this module's answer to "what did my resolver decide", and a host that is not
  // asking should not receive them.
  if (!Registered(ctx))
    return;
  WriteProperty(ctx, kIndexProperty, std::to_string(landed));
  WriteProperty(ctx, kSourceProperty,
                from_host ? kSourceClient : kSourceFallback);
}

// Moves the highlight and tags the segment. Returns the index the engine
// actually holds, which can differ from the one asked for because Highlight
// clamps, or because the move's notifier rebuilt the composition underneath.
//
// The tag goes on after the move, not before: Highlight fires the update
// notifier, which re-runs Compose and can rebuild or empty the composition, so a
// Segment reference taken before it may be gone by the time it is tagged. The
// built-in selector tags after moving for the same reason.
size_t HighlightAndTag(Context* ctx, size_t index) {
  ctx->Highlight(index);
  Composition& comp = ctx->composition();
  if (comp.empty())
    return index;
  comp.back().tags.insert("paging");
  return comp.back().selected_index;
}

// The page holding `index`. Fails only when there is no candidate list or no
// candidate at that index; otherwise it always answers, falling back to the
// built-in page when the host has nothing to say. `from_host` reports which of
// the two answered.
bool ResolvePage(Schema* schema,
                 Context* ctx,
                 size_t index,
                 PageGeometry* page,
                 bool* from_host) {
  *from_host = false;
  Composition& comp = ctx->composition();
  if (comp.empty() || !comp.back().menu)
    return false;
  if (comp.back().menu->Prepare(index + 1) <= index)
    return false;

  Entry entry;
  if (Lookup(ctx, &entry) && entry.resolver) {
    RimeVarPage answer = {0, 0};
    if (entry.resolver(entry.user_data, entry.session_id, index, &answer)) {
      PageGeometry resolved{answer.start, answer.length};
      // A page has to contain the index it was asked about, and be non-empty: an
      // answer that fails either test is not usable, and the built-in page
      // stands in for it. varpage.source reports the downgrade.
      if (resolved.length > 0 && resolved.Contains(index)) {
        *page = resolved;
        *from_host = true;
        return true;
      }
    }
  }

  *page = FixedPage(schema, index);
  return true;
}

}  // namespace

bool NextPage(Schema* schema, Context* ctx) {
  Composition& comp = ctx->composition();
  if (comp.empty() || !comp.back().menu)
    return false;
  Menu* menu = comp.back().menu.get();
  const size_t selected = comp.back().selected_index;

  // The two page models are never mixed within one keystroke: the offset carried
  // across a turn is measured inside the page it came from, so landing in a page
  // from the other model at a foreign offset could move the highlight backwards.
  // When the host cannot place the page being turned to, the built-in arithmetic
  // serves the whole keystroke instead.
  PageGeometry current;
  bool from_host = false;
  if (ResolvePage(schema, ctx, selected, &current, &from_host) && from_host) {
    const size_t probe = current.end();
    if (menu->Prepare(probe + 1) <= probe) {
      // Nothing where the next page would begin, so this is the last page.
      if (schema && schema->page_down_cycle()) {
        PublishDecision(ctx, HighlightAndTag(ctx, 0), from_host);
      }
      // Without page_down_cycle the key is consumed without moving, so page down
      // is not delivered to the application.
      return true;
    }

    PageGeometry next;
    bool next_from_host = false;
    // The page after this one has to begin where this one ends. That tiling is
    // what makes the turn move forward, because the offset measured in `current`
    // is carried into `next`: an answer that merely *contains* the probe index
    // may start before it, and the highlight would land behind where it started.
    // Such an answer is declined, and the built-in arithmetic serves instead.
    if (ResolvePage(schema, ctx, probe, &next, &next_from_host) &&
        next_from_host && next.start == probe) {
      const size_t offset =
          std::min(selected - current.start, next.length - 1);
      PublishDecision(ctx, HighlightAndTag(ctx, next.start + offset), true);
      return true;
    }
  }

  const size_t page_size = PageSize(schema);
  const size_t probe = selected / page_size * page_size + page_size;
  if (menu->Prepare(probe + 1) <= probe) {
    if (schema && schema->page_down_cycle()) {
      PublishDecision(ctx, HighlightAndTag(ctx, 0), false);
    }
    return true;
  }
  // Highlight clamps to the last candidate, which is what the built-in's
  // explicit clamp to candidate_count - 1 amounts to.
  PublishDecision(ctx, HighlightAndTag(ctx, selected + page_size), false);
  return true;
}

bool PreviousPage(Schema* schema, Context* ctx) {
  Composition& comp = ctx->composition();
  if (comp.empty())
    return false;
  const size_t selected = comp.back().selected_index;

  PageGeometry current;
  bool from_host = false;
  if (comp.back().menu &&
      ResolvePage(schema, ctx, selected, &current, &from_host) && from_host) {
    if (current.start == 0) {
      // Already on the first page: there is no page to turn back to, and the
      // built-in consumes the key here rather than passing it on.
      PublishDecision(ctx, HighlightAndTag(ctx, 0), true);
      return true;
    }

    // No tiling guard is needed on this side. The probe is the candidate just
    // before this page, whose answer must contain it, which already forces
    // previous.start <= current.start - 1; the target is therefore at most
    // selected - 1 and cannot move forward.
    PageGeometry previous;
    bool previous_from_host = false;
    if (ResolvePage(schema, ctx, current.start - 1, &previous,
                    &previous_from_host) &&
        previous_from_host) {
      const size_t offset =
          std::min(selected - current.start, previous.length - 1);
      PublishDecision(ctx, HighlightAndTag(ctx, previous.start + offset), true);
      return true;
    }
    // As in NextPage: the whole keystroke falls back rather than mixing models.
  }

  const size_t page_size = PageSize(schema);
  const size_t target = selected < page_size ? 0 : selected - page_size;
  PublishDecision(ctx, HighlightAndTag(ctx, target), false);
  return true;
}

bool SelectCandidateAt(Schema* schema, Context* ctx, int slot) {
  Composition& comp = ctx->composition();
  if (comp.empty() || slot < 0)
    return false;
  PageGeometry current;
  bool from_host = false;
  if (!ResolvePage(schema, ctx, comp.back().selected_index, &current,
                   &from_host))
    return false;
  // The slot is relative to the page the highlight is on, and a variable-length
  // page has no fixed slot count: a slot past the end of this page does not
  // reach into the next one. The caller still consumes the key, as the built-in
  // selector does.
  if (static_cast<size_t>(slot) >= current.length)
    return false;
  return ctx->Select(current.start + static_cast<size_t>(slot));
}

void OnContextChanged(Context* ctx) {
  if (!ctx || !Registered(ctx))
    return;
  // Only the highlight: varpage.source names the model behind the most recent
  // page action, and this is not one, so it is left alone.
  PublishIndex(ctx);
}

bool SetResolver(RimeSessionId session_id,
                 RimeVarPageResolver resolver,
                 void* user_data) {
  if (!resolver)
    return false;
  an<Session> session(Service::instance().GetSession(session_id));
  if (!session)
    return false;
  Context* ctx = session->context();
  if (!ctx)
    return false;
  UpsertResolver(ctx, session_id, resolver, user_data);
  return true;
}

bool ClearResolver(RimeSessionId session_id) {
  Context* ctx = nullptr;
  {
    Table& t = table();
    std::lock_guard<std::mutex> lock(t.mutex);
    auto it = t.by_session.find(session_id);
    if (it == t.by_session.end())
      return false;
    ctx = it->second;
    t.by_context.erase(it->second);
    t.by_session.erase(it);
  }
  // Publishing stops with the registration, so clear the two properties the
  // registration was maintaining rather than leaving a host to read the last
  // values indefinitely. Only touch the context while the session still points
  // at it: this call is documented to work after the session is gone, and then
  // the pointer is not ours to dereference.
  an<Session> session(Service::instance().GetSession(session_id));
  if (session && session->context() == ctx)
    Unpublish(ctx);
  return true;
}

void Reset() {
  Table& t = table();
  std::lock_guard<std::mutex> lock(t.mutex);
  t.by_context.clear();
  t.by_session.clear();
}

}  // namespace varpage
}  // namespace rime
