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
const char kStartProperty[] = "varpage.start";
const char kLengthProperty[] = "varpage.length";
const char kSourceProperty[] = "varpage.source";

const char kSourceClient[] = "client";
const char kSourceFallback[] = "fallback";
const char kSourceStale[] = "stale";

struct Entry {
  RimeSessionId session_id = 0;
  RimeVarPageResolver resolver = nullptr;
  void* user_data = nullptr;

  // The page the host last reported, for the candidate the highlight sat on
  // when it was reported. Only trusted while `menu` still matches and the
  // highlight lies inside it; once the highlight leaves, the host has more to
  // say and the built-in arithmetic serves until it does.
  bool has_page = false;
  const void* menu = nullptr;
  size_t page_start = 0;
  size_t page_length = 0;
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

// Set while this module is moving the highlight itself, so the context
// notifier does not publish a transient answer: the move is already about to
// publish the geometry it used, and the notifier fires in the middle of it,
// when the new page is not yet the one on record.
thread_local bool t_in_page_action = false;

class PageActionGuard {
 public:
  PageActionGuard() : previous_(t_in_page_action) { t_in_page_action = true; }
  ~PageActionGuard() { t_in_page_action = previous_; }

  PageActionGuard(const PageActionGuard&) = delete;
  PageActionGuard& operator=(const PageActionGuard&) = delete;

 private:
  const bool previous_;
};

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
// clear_resolver is a requirement rather than tidy-up. The stale *page* such an
// entry may carry is still validated against the menu pointer before use.
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
// gone.
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
// Three things have to be true afterwards:
//
//   - a session that switched engines - ApplySchema builds a new one - must not
//     leave the old context holding its registration;
//   - two sessions must never share one, so a later clear_resolver for a
//     previous occupant cannot unregister the current one. The reclaim loop
//     drops any other id still naming this context;
//   - an entry filed under this context for a *different* session is reset
//     rather than reused, so a session that arrives at a context a previous one
//     used starts from a clean slate instead of inheriting its reported page.
//     Only the numeric id is available to tell them apart, so this cannot see a
//     session whose id came back after destruction - see Gone() for that limit
//     and why clear_resolver is required.
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

void StorePage(Context* ctx, const void* menu, const PageGeometry& page) {
  Table& t = table();
  std::lock_guard<std::mutex> lock(t.mutex);
  Entry* entry = Find(ctx, t);
  if (!entry)
    return;
  entry->has_page = true;
  entry->menu = menu;
  entry->page_start = page.start;
  entry->page_length = page.length;
}

// Forgets the stored report. Called when the composition empties, so the next
// composition cannot inherit a page from the previous one.
void DropReport(Context* ctx) {
  Table& t = table();
  std::lock_guard<std::mutex> lock(t.mutex);
  if (Entry* entry = Find(ctx, t))
    entry->has_page = false;
}

bool CachedPage(Context* ctx,
                const void* menu,
                size_t index,
                PageGeometry* page) {
  Table& t = table();
  std::lock_guard<std::mutex> lock(t.mutex);
  const Entry* entry = Find(ctx, t);
  if (!entry || !entry->has_page || entry->menu != menu)
    return false;
  PageGeometry cached{entry->page_start, entry->page_length};
  if (!cached.Contains(index))
    return false;
  *page = cached;
  return true;
}

void WriteProperty(Context* ctx, const char* name, const std::string& value) {
  if (ctx->get_property(name) == value)
    return;
  ctx->set_property(name, value);
}

void PublishIndex(Context* ctx, size_t index) {
  if (!Registered(ctx))
    return;
  WriteProperty(ctx, kIndexProperty, std::to_string(index));
}

void PublishStale(Context* ctx, size_t index) {
  if (!Registered(ctx))
    return;
  WriteProperty(ctx, kIndexProperty, std::to_string(index));
  WriteProperty(ctx, kSourceProperty, kSourceStale);
}

void PublishPage(Context* ctx,
                 size_t index,
                 const PageGeometry& page,
                 const char* source) {
  if (!Registered(ctx))
    return;
  WriteProperty(ctx, kIndexProperty, std::to_string(index));
  WriteProperty(ctx, kStartProperty, std::to_string(page.start));
  WriteProperty(ctx, kLengthProperty, std::to_string(page.length));
  WriteProperty(ctx, kSourceProperty, source);
}

// Publishes the page a page action landed on, along with which model produced
// it. The action publishes the geometry it used rather than re-resolving after
// the fact: a re-resolution can disagree with the geometry that placed the
// highlight, and a host rendering from these properties would then draw a page
// the highlight is not on.
void PublishUsed(Context* ctx,
                 size_t index,
                 const PageGeometry& page,
                 bool from_host) {
  PublishPage(ctx, index, page, from_host ? kSourceClient : kSourceFallback);
}

// Publishes what is known right now without asking the host: the highlight, and
// either the page the host reported or the built-in page that stands in for it.
// A host that sees "fallback" here is being told its report was not usable.
void PublishCurrent(Context* ctx, Schema* schema) {
  if (!Registered(ctx))
    return;
  Composition& comp = ctx->composition();
  if (comp.empty()) {
    PublishStale(ctx, 0);
    return;
  }
  const size_t selected = comp.back().selected_index;
  PageGeometry cached;
  if (CachedPage(ctx, comp.back().menu.get(), selected, &cached)) {
    PublishPage(ctx, selected, cached, kSourceClient);
    return;
  }
  PublishPage(ctx, selected, FixedPage(schema, selected), kSourceFallback);
}

// The page holding `index`. Fails only when there is no candidate list or no
// candidate at that index; otherwise it always answers, falling back to the
// built-in page when the host has nothing to say.
bool ResolvePage(Schema* schema,
                 Context* ctx,
                 size_t index,
                 PageGeometry* page,
                 bool* from_host) {
  *from_host = false;
  Composition& comp = ctx->composition();
  if (comp.empty() || !comp.back().menu)
    return false;
  Menu* menu = comp.back().menu.get();
  if (menu->Prepare(index + 1) <= index)
    return false;

  if (CachedPage(ctx, menu, index, page)) {
    *from_host = true;
    return true;
  }

  Entry entry;
  if (Lookup(ctx, &entry) && entry.resolver) {
    RimeVarPage answer = {0, 0};
    if (entry.resolver(entry.user_data, entry.session_id, index, &answer)) {
      PageGeometry resolved{answer.start, answer.length};
      if (resolved.length > 0 && resolved.Contains(index)) {
        *page = resolved;
        *from_host = true;
        if (index == comp.back().selected_index)
          StorePage(ctx, menu, resolved);
        return true;
      }
      // A page that does not contain its own index is not usable; fall through
      // to the built-in page. varpage.source reports the downgrade.
    }
  }

  *page = FixedPage(schema, index);
  return true;
}

// Moves the highlight and tags the segment.
//
// The tag is inserted after the move, not before: Highlight fires the update
// notifier, which re-runs Compose and can rebuild the composition - or empty it
// - so a Segment reference taken before the move may be gone by the time it is
// tagged. The built-in selector tags after moving for the same reason. The
// notifier is also suppressed while the move is in flight, since this module
// publishes the geometry the move used straight afterwards.
void HighlightAndTag(Context* ctx, size_t index) {
  PageActionGuard guard;
  ctx->Highlight(index);
  Composition& comp = ctx->composition();
  if (!comp.empty())
    comp.back().tags.insert("paging");
}

}  // namespace

bool NextPage(Schema* schema, Context* ctx) {
  Composition& comp = ctx->composition();
  if (comp.empty() || !comp.back().menu)
    return false;
  Menu* menu = comp.back().menu.get();
  const size_t selected = comp.back().selected_index;

  // The two page models are never mixed within one keystroke. The offset kept
  // across a turn is measured inside the page it came from, so landing in a page
  // from the other model at a foreign offset can move the highlight backwards;
  // when the host cannot place the page being turned to, the whole keystroke
  // goes to the built-in arithmetic instead.
  PageGeometry current;
  bool from_host = false;
  if (ResolvePage(schema, ctx, selected, &current, &from_host) && from_host) {
    const size_t probe = current.end();
    if (menu->Prepare(probe + 1) <= probe) {
      // No candidate where the next page would begin, so this is the last page.
      if (schema && schema->page_down_cycle()) {
        PageGeometry first;
        bool first_from_host = false;
        if (!ResolvePage(schema, ctx, 0, &first, &first_from_host) ||
            !first_from_host) {
          first = FixedPage(schema, 0);
          first_from_host = false;
        }
        if (first_from_host)
          StorePage(ctx, menu, first);
        HighlightAndTag(ctx, first.start);
        PublishUsed(ctx, first.start, first, first_from_host);
      }
      // Without page_down_cycle the key is consumed without moving, so page
      // down is not delivered to the application.
      return true;
    }
    PageGeometry next;
    bool next_from_host = false;
    // The page after this one has to begin where this one ends; that is the
    // tiling the contract asks of a host, and it is what makes the turn move
    // forward. A page that merely *contains* the probe index may start before it,
    // and carrying the offset into it would land the highlight behind where it
    // started. A host that answers that way falls back for this keystroke, which
    // varpage.source reports.
    if (ResolvePage(schema, ctx, probe, &next, &next_from_host) &&
        next_from_host && next.start == probe) {
      const size_t offset =
          std::min(selected - current.start, next.length - 1);
      const size_t target = next.start + offset;
      // Stored before the move: the move's notifier publishes what the geometry
      // looks like at that moment, and the new page has to already be known.
      StorePage(ctx, menu, next);
      HighlightAndTag(ctx, target);
      PublishUsed(ctx, target, next, true);
      return true;
    }
  }

  const size_t page_size = PageSize(schema);
  const size_t probe = selected / page_size * page_size + page_size;
  if (menu->Prepare(probe + 1) <= probe) {
    if (schema && schema->page_down_cycle()) {
      HighlightAndTag(ctx, 0);
      PublishUsed(ctx, 0, FixedPage(schema, 0), false);
    }
    return true;
  }
  // Highlight clamps to the last candidate, which is what the built-in's
  // explicit clamp to candidate_count - 1 amounts to. What gets published has to
  // be the position the engine actually holds, not the one asked for, because
  // varpage.index is defined as the highlighted candidate - a host reading a
  // clamped-away index would render a highlight that is not there.
  const size_t requested = selected + page_size;
  HighlightAndTag(ctx, requested);
  // Re-read after the move, and only while a segment is still there: the move's
  // notifier can rebuild or empty the composition.
  const size_t landed =
      comp.empty() ? requested : comp.back().selected_index;
  PublishUsed(ctx, landed, FixedPage(schema, landed), false);
  return true;
}

bool PreviousPage(Schema* schema, Context* ctx) {
  Composition& comp = ctx->composition();
  if (comp.empty())
    return false;
  Menu* menu = comp.back().menu.get();
  const size_t selected = comp.back().selected_index;

  PageGeometry current;
  bool from_host = false;
  if (menu && ResolvePage(schema, ctx, selected, &current, &from_host) &&
      from_host) {
    if (current.start == 0) {
      // Already on the first page: there is no page to turn back to.
      HighlightAndTag(ctx, 0);
      PublishUsed(ctx, 0, current, true);
      return true;
    }
    PageGeometry previous;
    bool previous_from_host = false;
    if (ResolvePage(schema, ctx, current.start - 1, &previous,
                    &previous_from_host) &&
        previous_from_host) {
      const size_t offset =
          std::min(selected - current.start, previous.length - 1);
      const size_t target = previous.start + offset;
      StorePage(ctx, menu, previous);
      HighlightAndTag(ctx, target);
      PublishUsed(ctx, target, previous, true);
      return true;
    }
    // As in NextPage: the whole keystroke falls back rather than mixing models.
  }

  const size_t page_size = PageSize(schema);
  const size_t target = selected < page_size ? 0 : selected - page_size;
  HighlightAndTag(ctx, target);
  PublishUsed(ctx, target, FixedPage(schema, target), false);
  return true;
}

bool SelectCandidateAt(Schema* schema, Context* ctx, int slot) {
  Composition& comp = ctx->composition();
  if (comp.empty() || slot < 0)
    return false;
  const size_t selected = comp.back().selected_index;
  PageGeometry current;
  bool from_host = false;
  if (!ResolvePage(schema, ctx, selected, &current, &from_host))
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
  if (!ctx || t_in_page_action || !Registered(ctx))
    return;
  Composition& comp = ctx->composition();
  if (comp.empty()) {
    DropReport(ctx);
    PublishStale(ctx, 0);
    return;
  }
  const size_t selected = comp.back().selected_index;
  PublishIndex(ctx, selected);
  PageGeometry cached;
  if (!CachedPage(ctx, comp.back().menu.get(), selected, &cached)) {
    // The highlight left the page the host reported - an arrow key, a filter
    // pass, a script writing selected_index - so the geometry is not
    // authoritative again until the host reports.
    PublishStale(ctx, selected);
  }
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
  Table& t = table();
  std::lock_guard<std::mutex> lock(t.mutex);
  auto it = t.by_session.find(session_id);
  if (it == t.by_session.end())
    return false;
  t.by_context.erase(it->second);
  t.by_session.erase(it);
  return true;
}

bool SetClientPage(RimeSessionId session_id, size_t start, size_t length) {
  if (length == 0)
    return false;
  an<Session> session(Service::instance().GetSession(session_id));
  if (!session)
    return false;
  Context* ctx = session->context();
  if (!ctx)
    return false;
  Composition& comp = ctx->composition();
  if (comp.empty() || !comp.back().menu)
    return false;
  {
    Table& t = table();
    std::lock_guard<std::mutex> lock(t.mutex);
    Retarget(ctx, session_id, t);
  }
  StorePage(ctx, comp.back().menu.get(), PageGeometry{start, length});
  PublishCurrent(ctx, session->schema());
  return true;
}

bool QueryPage(RimeSessionId session_id, size_t index, PageGeometry* page) {
  if (!page)
    return false;
  an<Session> session(Service::instance().GetSession(session_id));
  if (!session)
    return false;
  Context* ctx = session->context();
  if (!ctx)
    return false;
  bool from_host = false;
  return ResolvePage(session->schema(), ctx, index, page, &from_host);
}

bool TurnPage(RimeSessionId session_id, bool backward) {
  an<Session> session(Service::instance().GetSession(session_id));
  if (!session)
    return false;
  Context* ctx = session->context();
  if (!ctx)
    return false;
  // The page keys only act on a segment that has a menu and is not raw input;
  // turn_page is documented to behave the way they do.
  Composition& comp = ctx->composition();
  if (comp.empty() || !comp.back().menu || comp.back().HasTag("raw"))
    return false;
  Schema* schema = session->schema();
  return backward ? PreviousPage(schema, ctx) : NextPage(schema, ctx);
}

void Reset() {
  Table& t = table();
  std::lock_guard<std::mutex> lock(t.mutex);
  t.by_context.clear();
  t.by_session.clear();
}

}  // namespace varpage
}  // namespace rime
