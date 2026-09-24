// Behavioral test for the varpage plugin.
//
// Driven by tests/run.sh next to it, against a built librime: this links the
// dynamic slice and drives real input sessions, which is the only way to cover
// what the plugin actually changes. The build-time gates
// (verify_merged_plugins, the header install, the module smoke test) prove the
// module is present and well-formed; none of them can tell whether a page key
// still lands where the host said it should, or whether the "paging" tag
// survived - and a lost tag is silent, because it only stops key_binder's
// `when: paging` bindings from firing.
//
// Assertions are plain checks rather than a test framework on purpose. Upstream
// librime's suite cannot host these - it has no coverage of selector at all, so
// it cannot see any of this - and this test has to be runnable against any tree
// the artifacts came from, including a dynamic slice whose dependency set has
// no gtest. It therefore links the shipped library from a bare compiler
// invocation and brings nothing with it.
//
// Two things about the shape of these assertions, both learned the hard way:
//
//   - Observed behavior, not the plugin's own published values. A check that
//     reads varpage.* alone can pass on a value written earlier; where a
//     property is used it is cross-checked against the highlight the engine
//     holds.
//   - The host page table below is nothing like the built-in page_size (3 then
//     4), which is what lets a check tell the two models apart: a page key that
//     lands on 3 went through the host, one that lands on 5 through the
//     built-in.
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

// Counts calls so a test can assert the host was *not* consulted.
int resolver_calls = 0;

bool Resolver(void* user_data,
              RimeSessionId session_id,
              size_t index,
              RimeVarPage* page) {
  (void)user_data;
  (void)session_id;
  ++resolver_calls;
  for (int i = 0; i < 2; ++i) {
    if (index >= kStarts[i] && index < kStarts[i] + kLengths[i]) {
      page->start = kStarts[i];
      page->length = kLengths[i];
      return true;
    }
  }
  return false;
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

// A host whose answers overlap instead of tiling: the page it reports for the
// index being turned to starts before the page the highlight is on. Every
// answer contains the index it was asked about, so nothing about a single
// answer looks wrong - the defect is only visible when the offset is carried
// across, which lands the highlight behind where it started. This is the shape
// the contract's tiling requirement exists to exclude.
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

std::string Property(RimeSessionId session, const char* name) {
  char buffer[64] = {0};
  if (!g_rime->get_property(session, name, buffer, sizeof(buffer)))
    return "";
  return buffer;
}

// The highlight, from the engine rather than from the plugin: the C API reports
// it as a page-relative index plus a page number, and the product is the
// absolute index (that identity holds because both come from the same
// selected_index).
int Highlighted(RimeSessionId session) {
  RimeContext context{};
  RIME_STRUCT_INIT(RimeContext, context);
  int index = -1;
  if (g_rime->get_context(session, &context) &&
      context.menu.num_candidates > 0) {
    index = context.menu.page_no * context.menu.page_size +
            context.menu.highlighted_candidate_index;
  }
  g_rime->free_context(&context);
  return index;
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

int PageSize(RimeSessionId session) {
  RimeContext context{};
  RIME_STRUCT_INIT(RimeContext, context);
  g_rime->get_context(session, &context);
  const int page_size = context.menu.page_size;
  g_rime->free_context(&context);
  return page_size;
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

  // A selector binding that collides with a select key, deployed as a real user
  // patch so the loader merges it the way it merges a user's own config.
  // Without it there is nothing to prove that a configured binding still wins
  // over the select keys - which is the order the built-in selector implements,
  // and the reason the replacement delegates every non-page action to the base
  // class.
  {
    const std::string patch_path =
        std::string(user_data_dir) + "/default.custom.yaml";
    FILE* patch = std::fopen(patch_path.c_str(), "w");
    if (!patch) {
      std::printf("FAIL  cannot write %s\n", patch_path.c_str());
      return 1;
    }
    std::fputs(
        "patch:\n"
        "  selector:\n"
        "    bindings:\n"
        "      \"2\": next_candidate\n",
        patch);
    std::fclose(patch);
  }

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

  // -- No host at all: the built-in arithmetic, and no property traffic. -----
  Check(Property(session, "varpage.index").empty(),
        "no property traffic before the host registers");
  rime->simulate_key_sequence(session, input);
  const int page_size = PageSize(session);
  Check(page_size > 1 && Highlighted(session) == 0,
        "the composition starts with the highlight on candidate 0");
  Check(rime->process_key(session, 0xFF56 /* XK_Next */, 0),
        "Page_Down is consumed");
  Check(Highlighted(session) == page_size,
        "with no host, Page_Down moves by page_size");
  Check(rime->process_key(session, 0xFF55 /* XK_Prior */, 0),
        "Page_Up is consumed");
  Check(Highlighted(session) == 0, "Page_Up returns to the first candidate");
  Check(Property(session, "varpage.index").empty(),
        "still no property traffic: nothing is registered");

  // -- A host that answers "unknown": still built-in, and it says so. --------
  Check(varpage->set_resolver(session, &UnknownResolver, nullptr),
        "a resolver answering unknown is registered");
  Check(rime->process_key(session, 0xFF56, 0), "Page_Down is consumed");
  Check(Highlighted(session) == page_size,
        "an unknown answer falls back to a page_size move");
  Check(Property(session, "varpage.source") == "fallback",
        "and the source property reports the built-in page");
  Check(varpage->clear_resolver(session), "the unknown resolver is cleared");

  // -- A host with pages: the same keys now follow them. --------------------
  // Start from a fresh composition. The phase above left the highlight wherever
  // its last page move put it, and a page turn from there is not the move being
  // asserted here.
  rime->clear_composition(session);
  rime->simulate_key_sequence(session, input);
  Check(Highlighted(session) == 0, "the composition restarts at the start");
  Check(varpage->set_resolver(session, &Resolver, nullptr),
        "host resolver registered");
  Check(rime->process_key(session, 0xFF56, 0), "Page_Down is consumed");
  Check(Highlighted(session) == 3,
        "Page_Down lands on the host's second page, not the built-in fifth");
  Check(Property(session, "varpage.index") == "3" &&
            Property(session, "varpage.source") == "client",
        "and the published highlight and source agree with the engine's move");
  Check(rime->process_key(session, 0xFF55, 0), "Page_Up is consumed");
  Check(Highlighted(session) == 0, "Page_Up returns to the host's first page");

  // The "paging" tag is what makes key_binder's `when: paging` bindings fire,
  // and losing it is silent. The shipped default.yaml binds `minus` to Page_Up
  // only while paging, so this asserts the tag through a real configuration
  // rather than by introspecting engine state.
  //
  // Checking the highlight alone would not work: without the tag, `minus`
  // reaches the punctuator instead, which commits "-" and clears the
  // composition - and a cleared composition also reports index 0, so a naive
  // check passes either way.
  rime->process_key(session, 0xFF56, 0);
  Check(Highlighted(session) == 3, "back on the host's second page");
  Check(rime->process_key(session, 0x2D /* minus */, 0), "minus is consumed");
  Check(TakeCommit(session).empty(),
        "and the paging binding ran, not the punctuator");
  Check(Property(session, "varpage.source") == "client",
        "the candidate list survived, and the host page is still in use");
  Check(Highlighted(session) == 0, "and it turned the page back");

  // -- Select keys address slots in the host page. --------------------------
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
  rime->process_key(session, '4', 0);
  Check(TakeCommit(session).empty(),
        "a slot past the end of the host page selects nothing");
  Check(Highlighted(session) == 0, "the highlight stayed put");

  // A digit the config bound to an action must run that action, not select. The
  // base class looks the key up in the keymap before it falls through to the
  // select keys; a replacement that computed the slot first would shadow the
  // binding. The two outcomes are told apart by what happens to the highlight:
  // the action moves it by one, the shadowed path leaves the composition in a
  // state that resets it.
  rime->clear_composition(session);
  rime->simulate_key_sequence(session, input);
  Check(Highlighted(session) == 0, "the composition is back at the start");
  rime->process_key(session, '2', 0);
  Check(TakeCommit(session).empty(),
        "a digit bound to next_candidate does not select");
  Check(Highlighted(session) == 1, "and it moved the highlight instead");
  Check(!CandidateAt(session, 0).empty(),
        "the composition survived, so the binding ran as an action");

  // -- A host answer that does not tile is declined. ------------------------
  // The probe is the candidate just past the current page, and the offset is
  // carried into whatever page comes back. An answer that contains that index
  // but starts earlier would move the highlight backwards. Move the highlight
  // with the built-in arithmetic first, so it has somewhere to move back to if
  // the guard is missing.
  rime->clear_composition(session);
  rime->simulate_key_sequence(session, input);
  Check(varpage->set_resolver(session, &UntiledResolver, nullptr),
        "an untiled resolver is registered");
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
  // on.
  Check(Highlighted(session) == before_untiled_turn + page_size,
        "and it fell back to the built-in page_size move");
  Check(Property(session, "varpage.source") == "fallback",
        "and the source reports the built-in page was used");

  // -- Registration outlives another engine becoming active. ----------------
  // Opening the schema switcher makes the session's active engine the switcher,
  // whose context is a different one. A registration keyed on "is the active
  // context the one I was filed under" would be discarded the first time a user
  // pressed F4, silently and for the rest of the session.
  {
    const RimeSessionId panel_session = rime->create_session();
    rime->select_schema(panel_session, schema_id);
    rime->simulate_key_sequence(panel_session, input);
    Check(varpage->set_resolver(panel_session, &Resolver, nullptr),
          "a session registers before the switcher opens");
    rime->process_key(panel_session, 0xFFC1 /* F4 */, 0);
    rime->clear_composition(panel_session);
    rime->process_key(panel_session, 0xFF1B /* Escape */, 0);
    // Retype, then ask for a page: landing on the host's page rather than the
    // built-in one is what shows the resolver is still consulted.
    rime->simulate_key_sequence(panel_session, input);
    Check(rime->process_key(panel_session, 0xFF56, 0),
          "Page_Down is consumed after the switcher was used");
    Check(Highlighted(panel_session) == 3,
          "and it still followed the host's page");
    Check(Property(panel_session, "varpage.source") == "client",
          "with the host's model still reported");
    Check(varpage->clear_resolver(panel_session),
          "the registration is still there to clear");
    rime->destroy_session(panel_session);
  }

  // -- Registering *while* the panel is open. --------------------------------
  // Session::context() reports the panel's own context while a switcher is
  // active, so a registration made in that window used to be filed where only
  // panel keys could reach it: set_resolver returned true, the panel then
  // called the host's resolver for a menu the host never laid out, and the
  // composing engine silently fell back to fixed pages for the rest of the
  // session. Both halves are asserted here - the panel must not reach the host,
  // and the registration must still apply once the panel closes.
  {
    const RimeSessionId panel_registration = rime->create_session();
    rime->select_schema(panel_registration, schema_id);
    rime->process_key(panel_registration, 0xFFC1 /* F4 */, 0);
    const int before = resolver_calls;
    Check(varpage->set_resolver(panel_registration, &Resolver, nullptr),
          "a session registers while the panel is open");
    // A page key reaches the panel's own selector instance. It must not reach
    // the host: the menu it would be answered with is the schema list, which
    // the host never laid out. What prevents it is the registration being filed
    // against the composing engine, so there is nothing filed under the panel's
    // context to find.
    rime->process_key(panel_registration, 0xFF56, 0);
    Check(resolver_calls == before,
          "and the panel does not ask the host about its own menu");
    rime->process_key(panel_registration, 0xFF1B /* Escape */, 0);

    rime->simulate_key_sequence(panel_registration, input);
    Check(rime->process_key(panel_registration, 0xFF56, 0),
          "Page_Down is consumed after the panel closes");
    Check(Highlighted(panel_registration) == 3,
          "and the registration filed during the panel still applies");
    Check(Property(panel_registration, "varpage.source") == "client",
          "with the host's model reported");
    Check(varpage->clear_resolver(panel_registration),
          "the registration is there to clear");
    rime->destroy_session(panel_registration);
  }

  // -- A schema switch rebuilds the processors. ------------------------------
  // ApplySchema clears and recreates every processor, so the selector instance
  // the host registered against does not survive it. The registration must: it
  // is filed against the session and the engine, both of which do survive.
  {
    const RimeSessionId switching = rime->create_session();
    rime->select_schema(switching, schema_id);
    rime->simulate_key_sequence(switching, input);
    Check(varpage->set_resolver(switching, &Resolver, nullptr),
          "a session registers");
    rime->select_schema(switching, schema_id);
    rime->simulate_key_sequence(switching, input);
    Check(rime->process_key(switching, 0xFF56, 0),
          "Page_Down is consumed after a schema switch");
    Check(Highlighted(switching) == 3,
          "and the host's pages still apply after the processors were rebuilt");
    Check(varpage->clear_resolver(switching),
          "the registration is there to clear");
    rime->destroy_session(switching);
  }

  // -- Two sessions do not share a registration. ----------------------------
  {
    const RimeSessionId first = rime->create_session();
    rime->select_schema(first, schema_id);
    rime->simulate_key_sequence(first, input);
    Check(varpage->set_resolver(first, &Resolver, nullptr),
          "a session registers under its resolver");

    const RimeSessionId second = rime->create_session();
    rime->select_schema(second, schema_id);
    rime->simulate_key_sequence(second, input);
    Check(varpage->set_resolver(second, &Resolver, nullptr),
          "a second session registers");

    Check(varpage->clear_resolver(first),
          "clearing the first session finds its registration");
    // Asked of behavior rather than of a property: the property already said
    // "client" before the clear, so it would still say so if the clear had
    // wiped everything.
    Check(rime->process_key(second, 0xFF56, 0) && Highlighted(second) == 3,
          "and the second session's registration survived it");

    rime->destroy_session(second);
    rime->destroy_session(first);
  }

  // -- Properties follow the composition. -----------------------------------
  rime->clear_composition(session);
  Check(Property(session, "varpage.index").empty() &&
            Property(session, "varpage.source").empty(),
        "ending the composition clears the published highlight and source");
  rime->simulate_key_sequence(session, input);
  Check(Property(session, "varpage.index") == "0",
        "and typing again publishes it");

  // A registration has to stay removable once its session is gone: that is what
  // keeps a recycled address from inheriting one, and it is why clear_resolver
  // takes an id rather than a pointer into the session. This session registered
  // for the host phase above and is destroyed without being cleared, so the
  // lookup below has only an id to work with.
  rime->destroy_session(session);
  Check(varpage->clear_resolver(session),
        "clear_resolver finds a registration after its session is gone");
  Check(varpage->clear_resolver(session) == false,
        "and a second clear reports nothing left");
  rime->finalize();

  std::printf("\n%s (%d failure%s)\n", g_failures == 0 ? "PASS" : "FAIL",
              g_failures, g_failures == 1 ? "" : "s");
  return g_failures == 0 ? 0 : 1;
}
