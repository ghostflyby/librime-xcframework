// Behavioral test for the varpage plugin.
//
// Driven by tests/run.sh next to it, against a built librime: this links the
// dynamic slice and drives real input sessions, which is the only way to cover
// what the plugin actually changes. The build-time gates (verify_merged_plugins,
// the header install, the module smoke test) prove the module is present and
// well-formed; none of them can tell whether a page key still lands where the
// host said it should, or whether the "paging" tag survived - and a lost tag is
// silent, because it only stops key_binder's `when: paging` bindings from
// firing.
//
// Assertions are plain checks rather than a test framework on purpose. Upstream
// librime's suite cannot host these - it has no coverage of selector at all, so
// it cannot see any of this - and this test has to be runnable against any tree
// the artifacts came from, including a dynamic slice whose dependency set has no
// gtest. It therefore links the shipped library from a bare compiler invocation
// and brings nothing with it.
//
// The harness registers a page table nothing like the built-in page_size (3
// then 4), which is what lets each assertion tell the two models apart.
#include <cstdio>
#include <cstdlib>
#include <string>

#include <rime_api.h>
#include <rime_varpage_api.h>

namespace {

RimeApi* g_rime = nullptr;
int g_failures = 0;

void Check(bool condition, const std::string& what) {
  std::printf("%s  %s\n", condition ? "ok  " : "FAIL", what.c_str());
  if (!condition)
    ++g_failures;
}

// A host layout: page 0 holds candidates [0,3), page 1 holds [3,7). Neither
// agrees with the built-in page_size of 5.
const size_t kStarts[2] = {0, 3};
const size_t kLengths[2] = {3, 4};

bool Resolver(void* user_data,
              RimeSessionId session_id,
              size_t index,
              RimeVarPage* page) {
  (void)user_data;
  (void)session_id;
  for (int i = 0; i < 2; ++i) {
    if (index >= kStarts[i] && index < kStarts[i] + kLengths[i]) {
      page->start = kStarts[i];
      page->length = kLengths[i];
      return true;
    }
  }
  return false;
}

// A host whose answers overlap instead of tiling: the page it reports for the
// index being turned to starts before the page the highlight is on. Every answer
// contains the index it was asked about, so nothing about a single answer looks
// wrong - the defect is only visible when the offset is carried across, which
// lands the highlight behind where it started. This is the shape the contract's
// tiling requirement exists to exclude.
bool UntiledResolver(void* user_data,
                     RimeSessionId session_id,
                     size_t index,
                     RimeVarPage* page) {
  (void)user_data;
  (void)session_id;
  if (index < 6) {
    page->start = 4;
    page->length = 4;
  } else {
    page->start = 0;
    page->length = index + 2;
  }
  return true;
}

// Answers "unknown" for everything: the path a host takes when it declines a
// request, which must leave the built-in arithmetic in charge.
bool UnknownResolver(void* user_data,
                     RimeSessionId session_id,
                     size_t index,
                     RimeVarPage* page) {
  (void)user_data;
  (void)session_id;
  (void)index;
  (void)page;
  return false;
}

std::string Property(RimeSessionId session, const char* name) {
  char buffer[64] = {0};
  if (!g_rime->get_property(session, name, buffer, sizeof(buffer)))
    return "";
  return buffer;
}

int Highlighted(RimeSessionId session) {
  const std::string value = Property(session, "varpage.index");
  return value.empty() ? -1 : std::atoi(value.c_str());
}

std::string CandidateAt(RimeSessionId session, size_t index) {
  RimeCandidateListIterator it;
  if (!g_rime->candidate_list_from_index(session, &it, (int)index))
    return "";
  std::string text;
  if (g_rime->candidate_list_next(&it) && it.candidate.text)
    text = it.candidate.text;
  g_rime->candidate_list_end(&it);
  return text;
}

std::string TakeCommit(RimeSessionId session) {
  RimeCommit commit{};
  RIME_STRUCT_INIT(RimeCommit, commit);
  std::string text;
  if (g_rime->get_commit(session, &commit) && commit.text)
    text = commit.text;
  g_rime->free_commit(&commit);
  return text;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 5) {
    std::printf(
        "usage: %s <shared-data-dir> <user-data-dir> <schema-id> <keys>\n",
        argv[0]);
    return 2;
  }
  const char* shared_data_dir = argv[1];
  const char* user_data_dir = argv[2];
  const char* schema_id = argv[3];
  // The input to type. It has to be a sequence the schema actually translates,
  // so it is a parameter rather than a constant: "nihao" means nothing to a
  // shape-based schema.
  const char* input = argv[4];

  RimeApi* rime = rime_get_api();
  g_rime = rime;

  RimeTraits traits{};
  RIME_STRUCT_INIT(RimeTraits, traits);
  const char* modules[] = {"default", "varpage", "deployer", nullptr};
  traits.modules = modules;
  traits.shared_data_dir = shared_data_dir;
  traits.user_data_dir = user_data_dir;
  traits.distribution_name = "librime-varpage-test";
  traits.distribution_code_name = "librime-varpage-test";
  traits.distribution_version = "0";
  traits.app_name = "librime-varpage-test";

  // A selector binding that collides with a select key, deployed as a real user
  // patch so the loader merges it the way it merges a user's own config. Without
  // it there is nothing to prove that a configured binding still wins over the
  // select keys - which is the order the built-in selector implements, and the
  // reason the replacement delegates every non-page action to the base class.
  {
    const std::string patch_path =
        std::string(user_data_dir) + "/default.custom.yaml";
    FILE* patch = std::fopen(patch_path.c_str(), "w");
    if (!patch) {
      std::printf("FAIL  cannot write %s\n", patch_path.c_str());
      return 1;
    }
    std::fputs("patch:\n"
               "  selector:\n"
               "    bindings:\n"
               "      \"2\": next_candidate\n",
               patch);
    std::fclose(patch);
  }

  rime->setup(&traits);
  rime->initialize(&traits);
  // A fresh user data dir has no build artifacts, and without them every schema
  // comes up with an empty candidate list.
  if (!rime->deploy()) {
    std::printf("FAIL  deploy() failed (shared data: %s)\n", shared_data_dir);
    return 1;
  }

  RimeVarPageApi* varpage = nullptr;
  if (RimeModule* module = rime->find_module("varpage"))
    varpage = reinterpret_cast<RimeVarPageApi*>(module->get_api());
  Check(varpage != nullptr, "module varpage is registered and exposes an API");
  if (!varpage)
    return 1;

  const RimeSessionId session = rime->create_session();
  Check(session != 0, "session created");
  rime->select_schema(session, schema_id);

  // -- A session with no host: nothing published, built-in behavior. ---------
  Check(Property(session, "varpage.index").empty(),
        "no property traffic at all before the host registers");
  rime->simulate_key_sequence(session, input);

  RimeContext context{};
  RIME_STRUCT_INIT(RimeContext, context);
  rime->get_context(session, &context);
  const int candidates = context.menu.num_candidates;
  const int page_size = context.menu.page_size;
  const bool has_select_keys = context.menu.select_keys != nullptr;
  rime->free_context(&context);
  std::printf("      (page_size=%d, candidates on the first page=%d)\n",
              page_size, candidates);
  Check(candidates > 0, "candidate list is populated");
  if (candidates == 0)
    return 1;
  (void)has_select_keys;

  // A host that answers "unknown" leaves the built-in arithmetic in charge,
  // while publishing stays on so the downgrade is visible.
  Check(varpage->set_resolver(session, &UnknownResolver, nullptr),
        "a resolver answering unknown is registered");
  Check(rime->process_key(session, 0xFF56 /* XK_Next */, 0),
        "Page_Down is consumed");
  Check(Highlighted(session) == page_size,
        "an unknown answer falls back to a page_size move");
  Check(Property(session, "varpage.source") == "fallback",
        "the published source reports the built-in page");
  Check(rime->process_key(session, 0xFF55 /* XK_Prior */, 0),
        "Page_Up is consumed");
  Check(Highlighted(session) == 0, "Page_Up returns to the first candidate");
  Check(varpage->clear_resolver(session), "the unknown resolver is cleared");

  // -- With a host: the same keys follow the host's pages. -------------------
  Check(varpage->set_resolver(session, &Resolver, nullptr),
        "host resolver registered");
  RimeVarPage page = {0, 0};
  Check(varpage->query_page(session, 0, &page), "query_page resolves index 0");
  Check(page.start == 0 && page.length == 3,
        "the host page for index 0 is [0,3), not the built-in [0,5)");

  rime->process_key(session, 0xFF56, 0);
  Check(Highlighted(session) == 3,
        "Page_Down lands on the next host page's first candidate");
  // The index property is the plugin's own report; this checks it against the
  // highlight the engine actually has, which the C API exposes as a page-relative
  // index plus a page number.
  {
    RimeContext after_turn{};
    RIME_STRUCT_INIT(RimeContext, after_turn);
    rime->get_context(session, &after_turn);
    const int absolute =
        after_turn.menu.page_no * after_turn.menu.page_size +
        after_turn.menu.highlighted_candidate_index;
    rime->free_context(&after_turn);
    Check(absolute == 3, "and the engine's own highlight agrees");
  }
  Check(Property(session, "varpage.start") == "3" &&
            Property(session, "varpage.length") == "4",
        "the published geometry is the host page [3,7)");
  Check(Property(session, "varpage.source") == "client",
        "the published source reports the host page");

  // The "paging" tag is what makes key_binder's `when: paging` bindings fire,
  // and losing it is silent. The shipped default.yaml binds `minus` to Page_Up
  // only while paging, so this asserts the tag through a real configuration
  // rather than by introspecting engine state.
  //
  // Checking the highlight alone would not work: without the tag, `minus`
  // reaches the punctuator instead, which commits "-" and clears the
  // composition - and a cleared composition publishes index 0 too, so a naive
  // check passes either way. What distinguishes them is that a page turn keeps
  // the candidate list alive and the host page in use, while punctuation
  // commits text and empties the "composition".
  Check(rime->process_key(session, 0x2D /* minus */, 0),
        "minus is consumed");
  // The three checks below are what make this a test of the tag. The one above
  // is not: without the tag, `minus` is consumed by the punctuator just the
  // same, which is exactly why the failure would otherwise go unnoticed.
  Check(TakeCommit(session).empty(),
        "and the paging binding ran, not the punctuator");
  RimeContext after_minus{};
  RIME_STRUCT_INIT(RimeContext, after_minus);
  rime->get_context(session, &after_minus);
  const bool menu_alive = after_minus.menu.num_candidates > 0;
  rime->free_context(&after_minus);
  Check(menu_alive, "the candidate list survived the page turn");
  Check(Property(session, "varpage.source") == "client",
        "the host page is still in use, so the turn went through it");
  Check(Highlighted(session) == 0, "and it turned the page back");

  Check(varpage->turn_page(session, /*backward=*/false),
        "turn_page serves a UI-driven page turn");
  Check(Highlighted(session) == 3, "turn_page moved to the host's second page");
  Check(varpage->turn_page(session, /*backward=*/true),
        "turn_page(backward) serves a UI-driven page turn");
  Check(Highlighted(session) == 0, "turn_page(backward) returns");

  // -- Select keys address slots in the host page. ---------------------------
  // Selecting slot 2 commits that candidate. The commit text is the only way to
  // recognise which candidate was taken, and a candidate only commits its own
  // span of the input - so a key sequence whose candidate 2 is not the whole
  // input gives a shorter commit and a failure here. The hint says as much,
  // because nothing else in the output would.
  const std::string third = CandidateAt(session, 2);
  rime->process_key(session, '3', 0);
  const std::string committed = TakeCommit(session);
  Check(committed == third,
        "select key 3 commits candidate 2 ('" + third + "')");
  if (committed != third) {
    std::printf(
        "      committed '%s'; if this input has no whole-input candidate at\n"
        "      index 2, pass --input with a sequence that does\n",
        committed.c_str());
  }

  // Slot 3 is inside the built-in page [0,5) but past the end of the host page
  // [0,3): the key is still consumed, and nothing is selected.
  rime->simulate_key_sequence(session, input);
  Check(varpage->query_page(session, 0, &page) && page.length == 3,
        "the host page is [0,3) again after retyping");
  rime->process_key(session, '4', 0);
  Check(TakeCommit(session).empty(),
        "a slot past the end of the host page selects nothing");

  // A digit the config bound to an action must run that action, not select.
  // The base class looks the key up in the keymap before it falls through to the
  // select keys; a replacement that computed the slot first would shadow the
  // binding. The two outcomes are told apart by what happens to the highlight:
  // the action moves it by one, while the shadowed path resolves a slot and
  // leaves the selection in a state that resets it.
  rime->clear_composition(session);
  rime->simulate_key_sequence(session, input);
  Check(varpage->query_page(session, 0, &page) && page.length == 3,
        "the composition is back on the host's first page");
  rime->process_key(session, '2', 0);
  Check(TakeCommit(session).empty(),
        "a digit bound to next_candidate does not select");
  Check(Highlighted(session) == 1,
        "and it moved the highlight instead");
  Check(varpage->query_page(session, 1, &page) && page.length == 3,
        "the composition survived, so the binding ran as an action");

  // -- Push-only mode and the lifecycle call. --------------------------------
  Check(varpage->clear_resolver(session), "resolver cleared");
  // A length nothing has published before: the highlight is at 0 here, and the
  // last geometry published for it was the host's [0,3), so a stale value
  // cannot satisfy the assertions below.
  Check(varpage->set_page(session, 0, 4), "a host page is pushed directly");
  Check(Property(session, "varpage.length") == "4" &&
            Property(session, "varpage.start") == "0" &&
            Property(session, "varpage.source") == "client",
        "the pushed page is published");
  Check(varpage->query_page(session, (size_t)page_size, &page) &&
            page.start == (size_t)page_size,
        "with no resolver, a later index resolves to the built-in page");
  Check(varpage->set_page(session, 0, 0) == false,
        "a zero-length page is rejected");

  // A host answer that does not tile - a page containing the probe index but
  // starting before it - must be declined: carrying the offset into it would
  // move the highlight backwards. The keystroke falls back instead, and the
  // published source says so.
  rime->clear_composition(session);
  rime->simulate_key_sequence(session, input);
  Check(varpage->set_resolver(session, &UntiledResolver, nullptr),
        "an untiled resolver is registered");
  // Move the highlight with the built-in arithmetic first, so the turn below has
  // a non-zero offset to carry and something behind it to move back to. With the
  // resolver answering as it does, applying that offset would land on index 1.
  rime->process_key(session, 0xFF56, 0);
  const int before_untiled_turn = Highlighted(session);
  Check(before_untiled_turn > 1,
        "the highlight has room behind it before the untiled turn");
  Check(rime->process_key(session, 0xFF56, 0), "Page_Down is consumed");
  std::printf("       (untiled answer: %d -> %d, source=%s)\n",
              before_untiled_turn, Highlighted(session),
              Property(session, "varpage.source").c_str());
  Check(Highlighted(session) >= before_untiled_turn,
        "the highlight did not move backwards on an untiled answer");
  // The keystroke has to actually fall back, not merely be consumed: a
  // do-nothing implementation would satisfy "did not move backwards" too. The
  // fallback is the built-in move, so the highlight lands a whole page further
  // on, and the published page is the built-in one that follows.
  const int expected_fallback = before_untiled_turn + page_size;
  Check(Highlighted(session) == expected_fallback,
        "and it fell back to the built-in page_size move");
  // The published page is the built-in page containing the position it landed
  // on, so its start is that position: 5 + 5 = 10 here, aligning to [10,15).
  Check(Property(session, "varpage.start") == std::to_string(expected_fallback),
        "with the built-in page published for the position it landed on");
  Check(Property(session, "varpage.source") == "fallback",
        "and the source reports the built-in page was used");

  // A destroyed session must not unregister the session that replaced it. The
  // allocator can reuse addresses, so this is checked from both sides: the
  // registration the live session made is what clear_resolver for the dead one
  // must leave alone.
  //
  // Note what is deliberately NOT asserted here. When the allocator hands back
  // the same addresses, the new session's id is numerically the old one's, and
  // so is its context - the plugin holds no other identity to tell them apart,
  // so it cannot detect the swap at all. That is why clear_resolver is a
  // documented requirement rather than an optimisation, and why this test drives
  // it rather than pretending the plugin can infer it.
  {
    const RimeSessionId first = rime->create_session();
    rime->select_schema(first, schema_id);
    rime->simulate_key_sequence(first, input);
    Check(varpage->set_resolver(first, &Resolver, nullptr),
          "a session registers under its resolver");
    RimeVarPage probe_page = {0, 0};
    Check(varpage->query_page(first, 0, &probe_page) && probe_page.length == 3,
          "its resolver answers");
    rime->process_key(first, 0xFF56, 0);
    Check(Property(first, "varpage.source") == "client",
          "and its page is published as the host's");

    // A second session registers while the first is still around, so the two
    // have distinct ids and clearing one cannot be confused with the other.
    const RimeSessionId second = rime->create_session();
    rime->select_schema(second, schema_id);
    rime->simulate_key_sequence(second, input);
    Check(varpage->set_resolver(second, &Resolver, nullptr),
          "a second session registers");
    rime->process_key(second, 0xFF56, 0);
    Check(Property(second, "varpage.source") == "client",
          "and it publishes under its own registration");

    Check(varpage->clear_resolver(first),
          "clearing the first session finds its registration");
    // Asked of the registry rather than of a property: the property already said
    // "client" before the clear, so it would still say so if the clear had wiped
    // everything. The second session's resolver answering is the real evidence.
    RimeVarPage survivor{0, 0};
    Check(varpage->query_page(second, 0, &survivor) && survivor.length == 3,
          "and the second session's registration survived it");

    rime->destroy_session(second);
    rime->destroy_session(first);
  }

  // Registering is not invalidated by another engine becoming active for a
  // while. Opening the schema switcher does exactly that - it makes the session's
  // active engine the switcher, whose context is a different one - and a
  // registration keyed on "is the active context the one I was filed under"
  // would be discarded the first time a user pressed F4, silently and for the
  // rest of the session. The registration must outlive that.
  {
    const RimeSessionId panel_session = rime->create_session();
    rime->select_schema(panel_session, schema_id);
    rime->simulate_key_sequence(panel_session, input);
    Check(varpage->set_resolver(panel_session, &Resolver, nullptr),
          "a session registers before the switcher opens");
    // F4 opens the schema switcher in the shipped default.yaml.
    rime->process_key(panel_session, 0xFFC1 /* F4 */, 0);
    rime->clear_composition(panel_session);
    rime->process_key(panel_session, 0xFF1B /* Escape */, 0);
    // Retype: query_page needs a candidate list to resolve against, and visiting
    // the panel ends the previous composition.
    rime->simulate_key_sequence(panel_session, input);
    RimeVarPage after_panel{0, 0};
    Check(varpage->query_page(panel_session, 0, &after_panel) &&
              after_panel.length == 3,
          "and its resolver still answers after the switcher was used");
    Check(varpage->clear_resolver(panel_session),
          "the registration is still there to clear");
    rime->destroy_session(panel_session);
  }

  rime->destroy_session(session);
  // A registration has to stay removable once its session is gone - that is what
  // keeps a recycled address from inheriting one, and it is the reason
  // clear_resolver takes no Context.
  Check(varpage->clear_resolver(session),
        "clear_resolver works on a destroyed session");
  Check(varpage->clear_resolver(session) == false,
        "a second clear_resolver reports nothing left to remove");
  rime->finalize();

  std::printf("\n%s (%d failure%s)\n", g_failures == 0 ? "PASS" : "FAIL",
              g_failures, g_failures == 1 ? "" : "s");
  return g_failures == 0 ? 0 : 1;
}
