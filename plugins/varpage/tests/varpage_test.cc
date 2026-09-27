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
//   - The host page table below is nothing like the built-in page_size (3, 4,
//     then 6 candidates), which is what lets a check tell the two models apart:
//     a page key that lands on 3 went through the host, one that lands on 5
//     through the built-in. The third page is longer than page_size on purpose,
//     because that is the only shape in which the two models disagree about
//     which slots exist.
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

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

// A host layout. Page 0 holds [0,3) and page 1 [3,7) - neither agrees with the
// built-in page_size of 5 - and page 2 holds [7,13), which is *longer* than
// page_size so that select keys can address slots the built-in page would
// reject. Pages tile: each begins where the previous one ends.
const size_t kPageCount = 3;
const size_t kStarts[kPageCount] = {0, 3, 7};
const size_t kLengths[kPageCount] = {3, 4, 6};

// The select-key string the test configures. It is 1-based like the usual
// Rime configuration and deliberately omits '0': with a non-empty string the
// engine does not fall back to the digit rule, so '0' stops being a select key
// altogether - which is the behaviour one assertion below pins down.
const char kSelectKeys[] = "123456789";

// Labels configured for the driving schema, one per slot of the largest page it
// may be asked to label. Only the first page_size of them are reachable through
// the C API's select_labels.
const char* const kLabels[] = {"①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨"};
const size_t kLabelCount = sizeof(kLabels) / sizeof(kLabels[0]);

// Labels configured for the second schema, deliberately fewer than its
// page_size: the C API's gate withholds the whole array in that case rather
// than padding or truncating.
const size_t kFewLabels = 3;

// Counts calls so a test can assert the host was *not* consulted.
int resolver_calls = 0;

bool Resolver(void* user_data,
              RimeSessionId session_id,
              size_t index,
              RimeVarPage* page) {
  (void)user_data;
  (void)session_id;
  ++resolver_calls;
  for (size_t i = 0; i < kPageCount; ++i) {
    if (index >= kStarts[i] && index < kStarts[i] + kLengths[i]) {
      page->start = kStarts[i];
      page->length = kLengths[i];
      return true;
    }
  }
  return false;
}

// Records calls through its user_data, so a test can assert that the pointer
// the host passed in is the one the resolver receives, and that it stops being
// called once its session is gone.
struct HostState {
  bool released = false;
  int calls = 0;
  int calls_after_release = 0;
};

bool RecordingResolver(void* user_data,
                       RimeSessionId session_id,
                       size_t index,
                       RimeVarPage* page) {
  auto* host = static_cast<HostState*>(user_data);
  if (host->released) {
    ++host->calls_after_release;
    return false;
  }
  ++host->calls;
  (void)session_id;
  if (index < 3) {
    page->start = 0;
    page->length = 3;
  } else {
    page->start = 3;
    page->length = 4;
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

// A host whose answers overlap instead of tiling: the page it reports for the
// index being turned to starts before the page the highlight is on. Every
// answer contains the index it was asked about and stays inside the list, so it
// breaks no rule the module enforces - and the module honours it, offset and
// all, which lands the highlight behind where it started. That backwards move
// is the host's layout talking, not a defect, and this resolver exists to pin
// that distinction down.
bool OverlappingResolver(void* user_data,
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

// A host that answers with a page running past the end of the candidate list.
// This is the one thing a resolver may not do, so the answer is declined and
// the built-in arithmetic takes the keystroke. It counts its calls through
// user_data for the same reason RecordingResolver does: the assertions around
// it expect a fallback, and a fallback is also what a registration that never
// reached this resolver at all would produce, so the count is what tells the
// two apart.
bool PastTheEndResolver(void* user_data,
                        RimeSessionId session_id,
                        size_t index,
                        RimeVarPage* page) {
  auto* calls = static_cast<int*>(user_data);
  if (calls)
    ++*calls;
  (void)session_id;
  page->start = index;
  page->length = 1000000;
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

// The preedit, which is how a selected-but-not-committed candidate shows up.
std::string Preedit(RimeSessionId session) {
  RimeContext context{};
  RIME_STRUCT_INIT(RimeContext, context);
  std::string text;
  if (g_rime->get_context(session, &context) && context.composition.preedit)
    text = context.composition.preedit;
  g_rime->free_context(&context);
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

// The C API's label array, as a host receives it: `present` is whether
// select_labels was non-NULL at all, and `labels` holds exactly page_size
// entries - the bound the array's lifetime is built around, and the only one a
// caller may use. One get_context per struct: a second call on the same struct
// would drop the first allocation.
struct Labels {
  bool present = false;
  int page_size = 0;
  std::vector<std::string> labels;
};

Labels ReadLabels(RimeSessionId session) {
  Labels result;
  RimeContext context{};
  RIME_STRUCT_INIT(RimeContext, context);
  if (!g_rime->get_context(session, &context))
    return result;
  result.page_size = context.menu.page_size;
  if (context.select_labels) {
    result.present = true;
    for (int i = 0; i < context.menu.page_size; ++i) {
      result.labels.push_back(context.select_labels[i]
                                  ? context.select_labels[i]
                                  : std::string("(null)"));
    }
  }
  g_rime->free_context(&context);
  return result;
}

// The label list as a host can read it for itself, which is the only route to
// entries past page_size. This is the same config the engine reads: schema_open
// resolves the deployed, patch-merged file that the engine's own Schema also
// loads.
std::vector<std::string> ConfigLabels(const char* schema_id) {
  std::vector<std::string> labels;
  RimeConfig config{};
  if (!g_rime->schema_open(schema_id, &config))
    return labels;
  const size_t size =
      g_rime->config_list_size(&config, "menu/alternative_select_labels");
  for (size_t i = 0; i < size; ++i) {
    char key[64];
    std::snprintf(key, sizeof(key), "menu/alternative_select_labels/@%zu", i);
    const char* label = g_rime->config_get_cstring(&config, key);
    labels.push_back(label ? label : "");
  }
  g_rime->config_close(&config);
  return labels;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 7) {
    std::printf(
        "usage: %s <shared-data-dir> <user-data-dir> <schema-id> <keys> "
        "<labels-off-schema> <labels-off-keys>\n",
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
  // A second schema, used to observe the label gate from the other side: it is
  // given fewer labels than its page_size, and the assertion is that the C API
  // then reports no labels at all.
  const char* labels_off_schema = argv[5];
  // The key sequence that second schema translates, which only it knows how to
  // answer: a candidate list is what the label gate is observed on.
  const char* labels_off_input = argv[6];

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
        "      \"2\": next_candidate\n"
        "      \"4\": home\n",
        patch);
    std::fclose(patch);
  }

  // The select keys and labels for the driving schema. Both are written as a
  // user patch, i.e. through the same deploy-time merge any schema author's
  // `.custom.yaml` goes through, so what the engine reads here is what a real
  // configuration produces. kSelectKeys omits '0', which turns it into a probe:
  // a digit inside the string selects by position, a digit outside it is not a
  // select key at all.
  {
    const std::string patch_path =
        std::string(user_data_dir) + "/" + schema_id + ".custom.yaml";
    FILE* patch = std::fopen(patch_path.c_str(), "w");
    if (!patch) {
      std::printf("FAIL  cannot write %s\n", patch_path.c_str());
      return 1;
    }
    std::fputs("patch:\n  menu/alternative_select_keys: \"", patch);
    std::fputs(kSelectKeys, patch);
    std::fputs("\"\n  menu/alternative_select_labels: [", patch);
    for (size_t i = 0; i < kLabelCount; ++i) {
      std::fprintf(patch, "%s\"%s\"", i ? ", " : "", kLabels[i]);
    }
    std::fputs("]\n", patch);
    std::fclose(patch);
  }

  // The other side of the label gate: fewer labels than page_size.
  {
    const std::string patch_path =
        std::string(user_data_dir) + "/" + labels_off_schema + ".custom.yaml";
    FILE* patch = std::fopen(patch_path.c_str(), "w");
    if (!patch) {
      std::printf("FAIL  cannot write %s\n", patch_path.c_str());
      return 1;
    }
    std::fprintf(patch, "patch:\n  menu/alternative_select_labels: [");
    for (size_t i = 0; i < kFewLabels; ++i) {
      std::fprintf(patch, "%s\"%s\"", i ? ", " : "", kLabels[i]);
    }
    std::fputs("]\n", patch);
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

  // A bound action that *declines* must fall through to the host's select-key
  // arithmetic, not the built-in one. "4" is bound to `home`, which declines at
  // the first candidate, so the key falls through to slot 3 - and slot 3 exists
  // in the built-in page [0,5) but not in the host's [0,3). Delegating the
  // whole event to the base class would run the base's own select-key block,
  // which resolves the slot against page_size and commits candidate 3 instead.
  rime->clear_composition(session);
  rime->simulate_key_sequence(session, input);
  Check(Highlighted(session) == 0,
        "at the first candidate for the declining action");
  const std::string before_declined = Preedit(session);
  rime->process_key(session, '4', 0);
  // The preedit is what tells the two outcomes apart, not the commit: selecting
  // a candidate that spans only part of the input shows up as a change in the
  // preedit and commits nothing, so an empty commit is true either way.
  Check(Preedit(session) == before_declined,
        "a declined binding does not select from the built-in page's slots");

  // -- A host page longer than page_size takes slots page_size cannot. ------
  // The third host page is [7,13): six candidates, one more than the built-in
  // page_size. Slot 5 exists there and has no counterpart on any built-in page,
  // so it is the case that tells the two slot arithmetics apart in the other
  // direction from the short-page checks above. Two page turns walk the
  // highlight 0 -> 3 -> 7, and '6' is the sixth character of the configured key
  // string, i.e. slot 5.
  rime->clear_composition(session);
  rime->simulate_key_sequence(session, input);
  rime->process_key(session, 0xFF56, 0);
  rime->process_key(session, 0xFF56, 0);
  Check(Highlighted(session) == 7,
        "two page turns reach the host's third page");
  {
    const std::string sixth = CandidateAt(session, 12);
    Check(rime->process_key(session, '6', 0), "select key 6 is consumed");
    // The candidate covers one syllable of the input, so it lands in the
    // preedit rather than in the commit; an empty commit is expected either way
    // and proves nothing on its own.
    Check(!sixth.empty() && Preedit(session).find(sixth) != std::string::npos,
          "and it takes slot 5, which page_size alone would have rejected ('" +
              sixth + "')");
  }

  // One slot further is past the end of that page: '9' is slot 8 and the page
  // holds six. As on a short built-in page, the key is consumed and the
  // composition does not move.
  rime->clear_composition(session);
  rime->simulate_key_sequence(session, input);
  rime->process_key(session, 0xFF56, 0);
  rime->process_key(session, 0xFF56, 0);
  Check(Highlighted(session) == 7, "back on the long page");
  {
    const std::string before = Preedit(session);
    Check(rime->process_key(session, '9', 0), "slot 8 is consumed");
    Check(Preedit(session) == before && Highlighted(session) == 7,
          "but selects nothing: it is past the end of the six-candidate page");
  }

  // A digit outside a non-empty select-key string is not a select key at all -
  // the string replaces the digit rule rather than extending it, which is the
  // built-in contract the module keeps. '0' is the probe, because the
  // configured string stops at '9'. With no processor claiming it, the key
  // falls through to the editor, which ends the composition.
  rime->clear_composition(session);
  rime->simulate_key_sequence(session, input);
  Check(Highlighted(session) == 0, "a fresh composition for the unbound digit");
  Check(!rime->process_key(session, '0', 0),
        "'0' is not a select key when the configured string omits it");
  Check(Highlighted(session) == -1,
        "and the key fell through to the editor, which ended the composition");

  // -- select_labels stay bound to page_size. ------------------------------
  // The engine builds its label array from the same configuration this test
  // writes, but it hands out exactly page_size entries, and only when the
  // configured list is at least that long. A host page longer than page_size
  // therefore cannot be labelled through that array - which is why the module's
  // header tells a host to read the configuration itself. These checks pin the
  // engine's side of that arrangement; the config read below is the host's.
  rime->clear_composition(session);
  rime->simulate_key_sequence(session, input);
  rime->process_key(session, 0xFF56, 0);
  rime->process_key(session, 0xFF56, 0);
  Check(Highlighted(session) == 7,
        "on the long host page for the label checks");
  {
    const Labels labels = ReadLabels(session);
    Check(labels.present, "the engine offers a label array");
    Check(labels.page_size == page_size,
          "whose page_size is the built-in one, not the host page's six");
    bool matches = labels.labels.size() == static_cast<size_t>(page_size);
    for (size_t i = 0; matches && i < labels.labels.size(); ++i)
      matches = labels.labels[i] == kLabels[i];
    Check(matches,
          "and its page_size entries are the first page_size configured "
          "labels, in slot order");
  }
  {
    const std::vector<std::string> configured = ConfigLabels(schema_id);
    bool complete = configured.size() == kLabelCount;
    for (size_t i = 0; complete && i < kLabelCount; ++i)
      complete = configured[i] == kLabels[i];
    Check(complete,
          "while a host that opens the schema config reads all nine, which is "
          "what makes a page longer than page_size labelable at all");
  }

  // The gate from the other side: a list shorter than page_size yields no array
  // at all rather than a short one, so labels can go missing without the page
  // being long. This second schema is deployed with three of them against the
  // same page_size of five.
  {
    const RimeSessionId short_session = rime->create_session();
    rime->select_schema(short_session, labels_off_schema);
    rime->simulate_key_sequence(short_session, labels_off_input);
    // Check the configuration the assertion is about before checking what the
    // engine makes of it. Without this, a patch that failed to write or merge
    // would also produce "no array", and the assertion below would pass while
    // proving nothing - the very thing it exists to pin down would be absent
    // rather than withheld.
    const std::vector<std::string> configured = ConfigLabels(labels_off_schema);
    Check(configured.size() == kFewLabels,
          "the second schema really has a label list, with fewer entries than "
          "its page_size");
    const Labels none = ReadLabels(short_session);
    Check(none.page_size > static_cast<int>(configured.size()),
          "the second schema's page_size is larger than its label list");
    Check(!none.present,
          "and the engine then offers no label array at all, not a short one");
    rime->destroy_session(short_session);
  }

  // -- The host's geometry is honoured, backwards or not. -------------------
  // The probe is the candidate just past the current page, and the offset is
  // carried into whatever page comes back. This host answers with a page that
  // starts *before* the one the highlight is on, so the turn lands behind where
  // it started. That is the host's layout talking and the module carries it
  // out; the check below is that the module does not substitute its own idea of
  // where the turn should go. (A hit against the built-in arithmetic would land
  // a whole page_size ahead instead, which is what makes the two
  // distinguishable.)
  rime->clear_composition(session);
  rime->simulate_key_sequence(session, input);
  Check(varpage->set_resolver(session, &OverlappingResolver, nullptr),
        "a resolver whose pages overlap is registered");
  rime->process_key(session, 0xFF56, 0);
  const int before_overlapping_turn = Highlighted(session);
  Check(before_overlapping_turn > 1,
        "the highlight has room behind it before the overlapping turn");
  Check(rime->process_key(session, 0xFF56, 0), "Page_Down is consumed");
  std::printf("       (overlapping answer: %d -> %d, source=%s)\n",
              before_overlapping_turn, Highlighted(session),
              Property(session, "varpage.source").c_str());
  Check(Highlighted(session) < before_overlapping_turn,
        "the highlight went backwards, because that is where the host's page "
        "put it");
  Check(
      Property(session, "varpage.source") == "client",
      "and the source reports the host's page was used, not the built-in one");

  // -- An answer past the candidate list is the one thing declined. ---------
  // The module does not police how pages relate to each other, but it does keep
  // the highlight inside the candidate list: a page whose last slot holds no
  // candidate is refused, and the keystroke falls back to the built-in
  // arithmetic. This answer is otherwise well-formed - it contains the index it
  // was asked about - so the boundary is the only reason to refuse it.
  rime->clear_composition(session);
  rime->simulate_key_sequence(session, input);
  int past_end_calls = 0;
  Check(varpage->set_resolver(session, &PastTheEndResolver, &past_end_calls),
        "a resolver answering past the end is registered");
  const int before_past_end = Highlighted(session);
  Check(rime->process_key(session, 0xFF56, 0), "Page_Down is consumed");
  std::printf("       (past-the-end answer: %d -> %d, source=%s, calls=%d)\n",
              before_past_end, Highlighted(session),
              Property(session, "varpage.source").c_str(), past_end_calls);
  Check(past_end_calls > 0,
        "the answer was actually consulted, so the fallback below is the "
        "boundary being enforced, not a registration that never arrived");
  Check(Highlighted(session) == before_past_end + page_size,
        "the answer was refused and the built-in page_size move applied");
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
    // A page key reaches the panel's own selector instance, which must not ask
    // the host about the schema list - a menu the host never laid out. Two
    // things prevent it: the registration is filed against the composing
    // engine, so the panel's context has nothing filed under it, and the
    // panel's instance declines the host branch outright. This check gates the
    // combination; the assertions after the panel closes are the ones that
    // isolate the filing.
    rime->process_key(panel_registration, 0xFF56, 0);
    Check(resolver_calls == before,
          "the panel's own menu never reaches the host's resolver");
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

  // -- An abandoned registration does not linger. ---------------------------
  // A session that registered and was destroyed without clear_resolver leaves
  // nothing for a later clear_resolver to find, once another session has been
  // active.
  //
  // Which mechanism provides that is not isolated here, and cannot be from the
  // public API: the allocator hands the destroyed session's context address to
  // the next session (measured: it reliably does), so the next session's key
  // reaches Find, which drops any entry whose session is gone. The sweep in
  // OnContextChanged covers the other case - an entry at an address no live
  // session touches - and no test reaches it. What is asserted below is the
  // contract, which holds either way.
  {
    const RimeSessionId abandoned = rime->create_session();
    rime->select_schema(abandoned, schema_id);
    rime->simulate_key_sequence(abandoned, input);
    Check(varpage->set_resolver(abandoned, &Resolver, nullptr),
          "a session registers");
    rime->destroy_session(abandoned);

    const RimeSessionId survivor = rime->create_session();
    rime->select_schema(survivor, schema_id);
    rime->simulate_key_sequence(survivor, input);
    rime->process_key(survivor, 0xFF56, 0);
    Check(varpage->clear_resolver(abandoned) == false,
          "an abandoned registration is gone by the time another session acts");
    rime->destroy_session(survivor);
  }

  // -- user_data is passed through and never touched after the session. ------
  // This is what lets a host free its own state as soon as it destroys the
  // session, with no cleanup callback for the module to invoke: the resolver is
  // only ever reached through the registration table's liveness check, so a
  // registration whose session is gone cannot be called. The test marks its
  // state released and then exercises other sessions, which is when a stale
  // call would show up.
  {
    HostState host;
    const RimeSessionId owning = rime->create_session();
    rime->select_schema(owning, schema_id);
    rime->simulate_key_sequence(owning, input);
    Check(varpage->set_resolver(owning, &RecordingResolver, &host),
          "a session registers with host state");
    rime->process_key(owning, 0xFF56, 0);
    Check(host.calls > 0 && Highlighted(owning) == 3,
          "the resolver received the host's own pointer and drove the page");
    rime->destroy_session(owning);

    // The host may release its state immediately, without waiting for the
    // module to notice anything. This is the load-bearing part: the
    // registration is still in the table at this moment, and it is the liveness
    // check on the way in - not the sweep, which is opportunistic - that keeps
    // a resolver call from ever reaching this now-freed pointer.
    host.released = true;
    for (int i = 0; i < 3; ++i) {
      const RimeSessionId other = rime->create_session();
      rime->select_schema(other, schema_id);
      rime->simulate_key_sequence(other, input);
      rime->process_key(other, 0xFF56, 0);
      rime->destroy_session(other);
    }
    Check(host.calls_after_release == 0,
          "no resolver call reached host state released before any sweep");

    // And what the host was holding is still removable, so its own bookkeeping
    // can be tidied whenever it likes.
    Check(varpage->clear_resolver(owning) == false,
          "by now the abandoned entry has been dropped");
  }

  // -- clear_resolver opens the user_data window with the session still up. ---
  // The other half of the ownership contract: a host that wants to free its
  // state without destroying the session must be able to, and before this call
  // that would be a use-after-free because the resolver was still being asked.
  {
    HostState host;
    const RimeSessionId live = rime->create_session();
    rime->select_schema(live, schema_id);
    rime->simulate_key_sequence(live, input);
    Check(varpage->set_resolver(live, &RecordingResolver, &host),
          "a live session registers with host state");
    rime->process_key(live, 0xFF56, 0);
    const int calls_before = host.calls;
    Check(calls_before > 0, "and the resolver is being asked");

    Check(varpage->clear_resolver(live), "the registration is cleared");
    // The session is still alive and still usable - it just pages on the
    // built-in grid now, and must not touch the released state.
    host.released = true;
    rime->simulate_key_sequence(live, input);
    rime->process_key(live, 0xFF56, 0);
    Check(host.calls_after_release == 0 && host.calls == calls_before,
          "and it is not asked again, so the window opens with the session "
          "alive");
    rime->destroy_session(live);
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
