//
// Copyright (c) 2026, librime-xcframework contributors
// Distributed under the BSD 3-Clause License; see LICENSE.
//
// Module registration, the component override that makes this the "selector"
// every schema picks up, and the C API the host reaches through
// rime->find_module("varpage")->get_api().
//
#include <mutex>

#include <rime_varpage_api.h>

// LOG comes from here, routed to glog by RIME_ENABLE_LOGGING; including glog
// directly would break a build that has logging compiled out.
#include <rime/common.h>
#include <rime/component.h>
#include <rime/registry.h>

#include "varpage_pages.h"
#include "varpage_selector.h"

using namespace rime;

namespace {

bool rime_varpage_set_resolver(RimeSessionId session_id,
                               RimeVarPageResolver resolver,
                               void* user_data) {
  return varpage::SetResolver(session_id, resolver, user_data);
}

bool rime_varpage_clear_resolver(RimeSessionId session_id) {
  return varpage::ClearResolver(session_id);
}

RimeVarPageApi* rime_varpage_get_api() {
  // std::call_once rather than a data_size guard: a concurrent first call could
  // otherwise observe data_size set while the function pointers were still
  // null.
  static std::once_flag once;
  static RimeVarPageApi api = {0};
  std::call_once(once, [] {
    RIME_STRUCT_INIT(RimeVarPageApi, api);
    api.set_resolver = &rime_varpage_set_resolver;
    api.clear_resolver = &rime_varpage_clear_resolver;
  });
  return &api;
}

}  // namespace

static void rime_varpage_initialize() {
  LOG(INFO) << "registering component from module 'varpage'.";
  // Replaces the built-in selector registered by the gears module, which this
  // module is loaded after; Registry::Register deletes the one it replaces.
  Registry::instance().Register("selector", new Component<VarPageSelector>);
}

static void rime_varpage_finalize() {
  varpage::Reset();
}

RIME_REGISTER_CUSTOM_MODULE(varpage) {
  module->get_api = reinterpret_cast<RimeCustomApi* (*)()>(
      &rime_varpage_get_api);
}
