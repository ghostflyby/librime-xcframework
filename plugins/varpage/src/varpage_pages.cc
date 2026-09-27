//
// Copyright (c) 2026, librime-xcframework contributors
// Distributed under the BSD 3-Clause License; see LICENSE.
//
#include "varpage_pages.h"

#include <algorithm>
#include <limits>
#include <map>
#include <mutex>
#include <string>

#include <rime/common.h>
#include <rime/composition.h>
#include <rime/context.h>
#include <rime/menu.h>
#include <rime/schema.h>
#include <rime/service.h>

namespace rime::varpage {

namespace {

constexpr char kIndexProperty[] = "varpage.index";
constexpr char kSourceProperty[] = "varpage.source";

constexpr char kSourceClient[] = "client";

struct Entry {
  RimeSessionId session_id = 0;
  // The session object, held weakly. A session id is the session's own address,
  // so a destroyed session's id can come back on a new session and every
  // numeric comparison would say "same"; the control block does not. This is
  // what makes a registration left behind by a destroyed session detectable
  // instead of being inherited by its successor.
  std::weak_ptr<Session> session;
  RimeVarPageResolver resolver = nullptr;
  void* user_data = nullptr;
};

struct Table {
  std::mutex mutex;
  std::map<const Context*, Entry> by_context;
  std::map<RimeSessionId, Context*> by_session;
  // Contexts owned by a schema switcher, mapped to the composing engine's
  // context each was opened over. Published and removed by the switcher's own
  // selector instance.
  std::map<Context*, Context*> switcher_contexts;
};

// Deliberately never destroyed: registrations outlive any teardown order the
// host picks, and a static destructor would only create a race with it.
Table& table() {
  static auto instance = new Table;
  return *instance;
}

size_t PageSize(const Schema* schema) {
  const int page_size = schema ? schema->page_size() : 0;
  return page_size > 0 ? static_cast<size_t>(page_size) : 1;
}

// The built-in page: `page_size` candidates aligned to a multiple of
// page_size. The last page is left short rather than clipped, exactly as the
// built-in selector leaves it, so Highlight and Select clamp as before.
PageGeometry FixedPage(const Schema* schema, const size_t index) {
  const size_t page_size = PageSize(schema);
  return PageGeometry{.start = index / page_size * page_size,
                      .length = page_size};
}

// Whether the registration behind `entry` still belongs to a live session.
bool Live(const Entry& entry) {
  return !entry.session.expired();
}

// Caller holds the lock. Drops the id from by_session, but only when it still
// names this context: an id can have been handed back to a new session whose
// registration now owns that key, and clearing it would unregister a live
// session.
void ForgetSession(Table& t,
                   const RimeSessionId session_id,
                   const Context* ctx) {
  if (const auto session = t.by_session.find(session_id);
      session != t.by_session.end() && session->second == ctx)
    t.by_session.erase(session);
}

// Caller holds the lock. Drops everything filed under a session that is gone,
// so a leaked registration neither pins the allocation its weak reference keeps
// alive nor lingers to be mistaken for a live one later.
void DropExpired(Table& t) {
  for (auto it = t.by_context.begin(); it != t.by_context.end();) {
    if (Live(it->second)) {
      ++it;
      continue;
    }
    ForgetSession(t, it->second.session_id, it->first);
    it = t.by_context.erase(it);
  }
}

// Caller holds the lock. Finds the entry for `ctx`, dropping it when its
// session is gone - the same guard as DropExpired, applied to the one entry a
// keystroke is asking about.
Entry* Find(const Context* ctx, Table& t) {
  const auto it = t.by_context.find(ctx);
  if (it == t.by_context.end())
    return nullptr;
  if (!Live(it->second)) {
    ForgetSession(t, it->second.session_id, ctx);
    t.by_context.erase(it);
    return nullptr;
  }
  return &it->second;
}

// Copies the entry for `ctx` out of the table. A copy rather than a reference
// because the resolver is called with no lock held.
bool Lookup(const Context* ctx, Entry* entry) {
  Table& t = table();
  std::lock_guard lock(t.mutex);
  const Entry* found = Find(ctx, t);
  if (!found)
    return false;
  *entry = *found;
  return true;
}

bool Registered(const Context* ctx) {
  Table& t = table();
  std::lock_guard lock(t.mutex);
  return Find(ctx, t) != nullptr;
}

// The context a registration belongs under. While a schema switcher is open,
// Session::context() reports the panel's own context, whose only visitor is the
// panel's selector; the composing engine is the engine the panel was opened
// over, so file there instead.
Context* RegistrationContext(Context* ctx) {
  Table& t = table();
  std::lock_guard lock(t.mutex);
  const auto it = t.switcher_contexts.find(ctx);
  if (it == t.switcher_contexts.end() || !it->second)
    return ctx;
  return it->second;
}

void UpsertResolver(Context* ctx,
                    const RimeSessionId session_id,
                    const std::shared_ptr<Session>& session,
                    const RimeVarPageResolver resolver,
                    void* user_data) {
  Table& t = table();
  std::lock_guard lock(t.mutex);
  DropExpired(t);

  // Two sessions must never share a context, so a later clear_resolver for a
  // previous occupant cannot unregister the current one: drop any other id
  // still naming this context.
  for (auto it = t.by_session.begin(); it != t.by_session.end();) {
    if (it->first != session_id && it->second == ctx)
      it = t.by_session.erase(it);
    else
      ++it;
  }
  // And one id maps to one context: a session that registers again from a
  // different context leaves its previous row behind otherwise.
  const auto previous = t.by_session.find(session_id);
  if (previous != t.by_session.end() && previous->second != ctx)
    t.by_context.erase(previous->second);
  t.by_session[session_id] = ctx;

  Entry& entry = t.by_context[ctx];
  // Reset when this context held a *different* session's registration, or this
  // id's own registration from a session that no longer exists - the reused-id
  // case, which the id comparison alone cannot see.
  if (entry.session_id != session_id || entry.session.expired())
    entry = Entry{};
  entry.session_id = session_id;
  entry.session = session;
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
  const Composition& comp = ctx->composition();
  if (comp.empty()) {
    Unpublish(ctx);
    return;
  }
  WriteProperty(ctx, kIndexProperty,
                std::to_string(comp.back().selected_index));
}

// Publishes the outcome of a page action. `from_host` says whether the host's
// answer determined this keystroke. Only page actions write the source, so it
// names the model behind the most recent one.
//
// A keystroke whose answer the host declined publishes nothing at all: the
// properties then still describe the last decision that was actually taken,
// rather than claiming a move that did not happen.
void PublishDecision(Context* ctx, const size_t landed, const bool from_host) {
  // Nothing is published for a session that never registered: the properties
  // are this module's answer to "what did my resolver decide", and a host that
  // is not asking should not receive them.
  if (!Registered(ctx))
    return;
  WriteProperty(ctx, kIndexProperty, std::to_string(landed));
  if (from_host)
    WriteProperty(ctx, kSourceProperty, kSourceClient);
}

// Moves the highlight and tags the segment. Returns the index the engine
// actually holds, which can differ from the one asked for because Highlight
// clamps, or because the move's notifier rebuilt the composition underneath.
//
// The tag goes on after the move, not before: Highlight fires the update
// notifier, which re-runs Compose and can rebuild or empty the composition, so
// a Segment reference taken before it may be gone by the time it is tagged. The
// built-in selector tags after moving for the same reason.
size_t HighlightAndTag(Context* ctx, const size_t index) {
  ctx->Highlight(index);
  Composition& comp = ctx->composition();
  if (comp.empty())
    return index;
  comp.back().tags.insert("paging");
  return comp.back().selected_index;
}

// Where a page geometry came from. The middle case is the one the callers act
// on: a host is registered and was asked, but its answer cannot be used, so the
// keystroke does nothing. It must not reach for arithmetic the host's layout
// would contradict - that is the failure this module exists to prevent.
enum class PageSource { kHost, kBuiltIn, kDeclined };

struct ResolvedPage {
  PageGeometry page;
  PageSource source = PageSource::kBuiltIn;
};

// The page holding `index`, and where that page came from.
//
// A host is asked whenever this context has a registration. Its answer is
// adopted as long as it lies inside the candidate list, which is the only thing
// checked and the only thing that can be checked: the module cannot know which
// pages the host's layout has. Everything else about the answer is the host's
// business - whether pages overlap or tile, whether the answer contains the
// index it was asked about, and therefore where in the page the highlight
// lands.
//
// The boundary is enforced by asking the menu for the page's last slot rather
// than by arithmetic on a total, because the candidate list has no known length
// until something asks for it. `length == 0` is declined as well: it cannot
// place a highlight. Both are declines rather than reasons to fall back, so a
// host's layout is never silently replaced by one it did not draw.
ResolvedPage ResolvePage(const Schema* schema,
                         Context* ctx,
                         const size_t index,
                         const bool allow_host) {
  ResolvedPage result;
  const Composition& comp = ctx->composition();
  if (comp.empty() || !comp.back().menu)
    return result;
  // By shared_ptr, and before the resolver runs: a host that breaks the
  // no-mutation rule rebuilds the composition, and the boundary check below
  // needs the menu *after* that call. Holding it keeps the list alive and the
  // second Prepare off a composition that may no longer be there.
  const an<Menu> menu = comp.back().menu;

  Entry entry;
  const bool host = allow_host && Lookup(ctx, &entry) && entry.resolver;

  // No candidate at `index` means the question cannot be asked at all. The
  // callers' own candidate checks have usually settled this already.
  if (menu->Prepare(index + 1) <= index) {
    result.source = host ? PageSource::kDeclined : PageSource::kBuiltIn;
    return result;
  }

  if (host) {
    RimeVarPage answer = {0, 0};
    if (entry.resolver(entry.user_data, entry.session_id, index, &answer)) {
      const PageGeometry resolved{answer.start, answer.length};
      const bool fits = resolved.length <=
                        std::numeric_limits<size_t>::max() - resolved.start;
      if (resolved.length > 0 && fits &&
          menu->Prepare(resolved.end()) >= resolved.end()) {
        result.page = resolved;
        result.source = PageSource::kHost;
        return result;
      }
    }
    result.source = PageSource::kDeclined;
    return result;
  }

  result.page = FixedPage(schema, index);
  return result;
}

// How far into its page the highlight sits, for a page that starts at or before
// it. A page beginning after the highlight has no offset to carry, and the
// subtraction would wrap size_t if it were attempted - an answer is no longer
// required to contain the index it was asked about, so the two can be
// unrelated. Clamping to zero lands the turn on that page's first slot.
size_t OffsetIn(const size_t selected, const PageGeometry& page) {
  return selected >= page.start ? selected - page.start : 0;
}

// Where inside `page` a turn lands: the offset the highlight had in the page it
// came from, clamped to this page's length. The offset comes from the source
// page - measuring it against the target would use an origin the highlight was
// never placed by, and would land it somewhere neither page describes.
//
// `page` is a host answer that got this far, so its length is positive:
// ResolvePage refuses an empty page before it can return kHost.
size_t LandingTarget(const size_t offset, const PageGeometry& page) {
  return page.start + std::min(offset, page.length - 1);
}

}  // namespace

void PublishSwitcherContext(Context* switcher_context,
                            Context* attached_context) {
  if (!switcher_context)
    return;
  Table& t = table();
  std::lock_guard lock(t.mutex);
  t.switcher_contexts[switcher_context] = attached_context;
}

void UnpublishSwitcherContext(Context* switcher_context) {
  if (!switcher_context)
    return;
  Table& t = table();
  std::lock_guard lock(t.mutex);
  t.switcher_contexts.erase(switcher_context);
}

bool NextPage(const Schema* schema, Context* ctx, const bool allow_host) {
  const Composition& comp = ctx->composition();
  if (comp.empty() || !comp.back().menu)
    return false;
  // By shared_ptr, not a raw pointer: the resolver is called below, and a host
  // that breaks the no-mutation rule rebuilds the composition - which would
  // leave a raw Menu* dangling. Holding it is also what keeps the candidate
  // list alive for the Prepare calls that follow.
  const an<Menu> menu = comp.back().menu;
  const size_t selected = comp.back().selected_index;

  const ResolvedPage current = ResolvePage(schema, ctx, selected, allow_host);
  if (current.source == PageSource::kHost) {
    const size_t probe = current.page.end();
    if (menu->Prepare(probe + 1) <= probe) {
      // Nothing where the next page would begin, so this is the last page. With
      // page_down_cycle the list wraps, as it does in the built-in selector;
      // without it the key is consumed without moving, so page down is not
      // delivered to the application.
      if (schema && schema->page_down_cycle())
        PublishDecision(ctx, HighlightAndTag(ctx, 0), true);
      return true;
    }

    // The page being turned to is whichever one holds the candidate just past
    // this page; the highlight's offset, measured in the page it is leaving, is
    // carried into it and clamped to that page's length. Nothing is required of
    // how the two pages relate: this one may begin before it, or after the gap
    // that ends it, and the target may land behind the highlight or not move it
    // at all. Whatever the answer describes is where the keyboard goes.
    const ResolvedPage next = ResolvePage(schema, ctx, probe, allow_host);
    if (next.source == PageSource::kHost)
      PublishDecision(
          ctx,
          HighlightAndTag(
              ctx, LandingTarget(OffsetIn(selected, current.page), next.page)),
          true);
    // A declined answer leaves the composition where it is. There is no
    // arithmetic to fall back to with a host registered: the built-in page is
    // not what this host drew, and moving by it would be a page turn the user
    // never asked for.
    return true;
  }
  if (current.source == PageSource::kDeclined)
    return true;

  // No host registered: the built-in arithmetic, which is what a drop-in
  // replacement owes a session that never registered.
  const size_t page_size = PageSize(schema);
  if (const size_t probe = selected / page_size * page_size + page_size;
      menu->Prepare(probe + 1) <= probe) {
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

bool PreviousPage(const Schema* schema, Context* ctx, const bool allow_host) {
  const Composition& comp = ctx->composition();
  if (comp.empty())
    return false;
  const size_t selected = comp.back().selected_index;

  const ResolvedPage current = ResolvePage(schema, ctx, selected, allow_host);
  if (current.source == PageSource::kHost) {
    if (current.page.start == 0) {
      // Already on the first page: there is no page to turn back to, and the
      // built-in consumes the key here rather than passing it on.
      PublishDecision(ctx, HighlightAndTag(ctx, 0), true);
      return true;
    }

    // The page being turned back to is whichever one holds the candidate just
    // before this page. As in NextPage, the offset is carried over from the
    // page being left and the answer decides the landing - including one that
    // does not move the highlight, which is how a host makes this key a no-op.
    const ResolvedPage previous =
        ResolvePage(schema, ctx, current.page.start - 1, allow_host);
    if (previous.source == PageSource::kHost)
      PublishDecision(
          ctx,
          HighlightAndTag(ctx, LandingTarget(OffsetIn(selected, current.page),
                                             previous.page)),
          true);
    // Declined: consumed without moving, and without falling back.
    return true;
  }
  if (current.source == PageSource::kDeclined)
    return true;

  // No host registered: the built-in arithmetic.
  const size_t page_size = PageSize(schema);
  const size_t target = selected < page_size ? 0 : selected - page_size;
  PublishDecision(ctx, HighlightAndTag(ctx, target), false);
  return true;
}

bool SelectCandidateAt(const Schema* schema,
                       Context* ctx,
                       const int slot,
                       const bool allow_host) {
  const Composition& comp = ctx->composition();
  if (comp.empty() || slot < 0)
    return false;
  const ResolvedPage current =
      ResolvePage(schema, ctx, comp.back().selected_index, allow_host);
  // A declined answer selects nothing. The caller still consumes the key, as
  // the built-in selector does for a slot past the end of a page.
  if (current.source == PageSource::kDeclined)
    return false;
  // The slot is relative to the page the highlight is on, and a variable-length
  // page has no fixed slot count: a slot past the end of this page does not
  // reach into the next one.
  if (static_cast<size_t>(slot) >= current.page.length)
    return false;
  return ctx->Select(current.page.start + static_cast<size_t>(slot));
}

void OnContextChanged(Context* ctx) {
  if (!ctx)
    return;

  // This runs whenever a live session's composition or highlight changes, which
  // makes it the natural place to sweep registrations whose session is gone.
  // Nothing else can: librime has no session-destroyed notification to hook
  // (DestroySession, CleanupStaleSessions and CleanupAllSessions all just erase
  // the session from their map), so the weak reference is the only evidence of
  // a death and something has to come along and look.
  //
  // Sweeping here is what makes clear_resolver optional. Without it, abandoning
  // a registration would leave its entry - and, because the weak reference
  // keeps the session's control block alive, the session's own allocation -
  // until the next registration by anyone.
  //
  // The lock is not held across the publishing below: writing a property
  // notifies the host, and the host is allowed to be slow.
  bool registered = false;
  {
    Table& t = table();
    std::lock_guard lock(t.mutex);
    DropExpired(t);
    registered = Find(ctx, t) != nullptr;
  }
  if (!registered)
    return;
  // Only the highlight: varpage.source names the model behind the most recent
  // page action, and this is not one, so it is left alone.
  PublishIndex(ctx);
}

bool SetResolver(const RimeSessionId session_id,
                 const RimeVarPageResolver resolver,
                 void* user_data) {
  if (!resolver)
    return false;
  const an<Session> session(Service::instance().GetSession(session_id));
  if (!session)
    return false;
  Context* ctx = session->context();
  if (!ctx)
    return false;
  UpsertResolver(RegistrationContext(ctx), session_id, session, resolver,
                 user_data);
  return true;
}

bool ClearResolver(const RimeSessionId session_id) {
  Context* ctx = nullptr;
  bool session_alive = false;
  {
    Table& t = table();
    std::lock_guard lock(t.mutex);
    const auto it = t.by_session.find(session_id);
    if (it == t.by_session.end())
      return false;
    ctx = it->second;
    if (const auto entry = t.by_context.find(ctx);
        entry != t.by_context.end()) {
      session_alive = Live(entry->second);
      t.by_context.erase(entry);
    }
    t.by_session.erase(it);
  }
  // Publishing stops with the registration, so clear the two properties the
  // registration was maintaining rather than leaving a host to read the last
  // values indefinitely. The context is only touched while its session is still
  // alive, which is also what makes this safe after the session is gone: then
  // the pointer is not ours to dereference. (Asking the service instead would
  // be wrong while the switcher is open, when the session's context is the
  // panel's.)
  if (ctx && session_alive)
    Unpublish(ctx);
  return true;
}

void Reset() {
  auto& [mutex, by_context, by_session, switcher_contexts] = table();
  std::lock_guard lock(mutex);
  by_context.clear();
  by_session.clear();
  switcher_contexts.clear();
}

}  // namespace rime::varpage
