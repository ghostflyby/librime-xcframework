// Behavioral test for the varpage plugin.
//
// Driven by scripts/test-varpage.sh against a built librime: this links the
// dynamic slice and drives real input sessions, which is the only way to cover
// what the plugin actually changes. The build-time gates (verify_merged_plugins,
// the header install, the module smoke test) prove the module is present and
// well-formed; none of them can tell whether a page key still lands where the
// host said it should, or whether the "paging" tag survived - and a lost tag is
// silent, because it only stops key_binder's `when: paging` bindings from
// firing.
//
// Assertions are plain checks rather than a test framework on purpose: gtest is
// not a dependency of this repository, and adding it would install a test
// framework into every slice's dependency set, iOS included, for a test that
// only ever runs on macOS. The upstream suite is not an option either - it has
// no coverage of selector at all, so it cannot see any of this.
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

  rime->destroy_session(session);
  // The push above re-registered the session, and a registration has to stay
  // removable once its session is gone - that is what keeps a recycled address
  // from inheriting one, and it is the reason clear_resolver takes no Context.
  Check(varpage->clear_resolver(session),
        "clear_resolver works on a destroyed session");
  Check(varpage->clear_resolver(session) == false,
        "a second clear_resolver reports nothing left to remove");
  rime->finalize();

  std::printf("\n%s (%d failure%s)\n", g_failures == 0 ? "PASS" : "FAIL",
              g_failures, g_failures == 1 ? "" : "s");
  return g_failures == 0 ? 0 : 1;
}
