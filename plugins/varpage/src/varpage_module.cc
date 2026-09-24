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

static void rime_varpage_initialize() {
  LOG(INFO) << "registering component from module 'varpage'.";
  // Replaces the built-in selector registered by the gears module, which this
  // module is loaded after; Registry::Register deletes the one it replaces.
  Registry::instance().Register("selector", new Component<VarPageSelector>);
}

static void rime_varpage_finalize() {
  varpage::Reset();
}

// get_api is declared to return RimeCustomApi*, and the two struct types are
// unrelated - not related by inheritance, and C++ blesses reading a shared
// initial sequence only through a union, never through a pointer cast. So the
// storage is a union of the two, which makes both operations defined: the
// address converts between the members (they are pointer-interconvertible, all
// at offset 0), and a caller that probes data_size through the base-typed
// pointer reads a live member of the union rather than an unrelated type. That
// probe is the pattern this protocol invites, and it is the one thing a plain
// reinterpret_cast could not cover.
//
// It also removes the cast from this file entirely: &storage.custom already has
// the declared return type.
RIME_REGISTER_CUSTOM_MODULE(varpage) {
  module->get_api = [] {
    union Storage {
      RimeCustomApi custom;
      RimeVarPageApi varpage;
    };
    static std::once_flag once;
    static Storage storage = {};
    std::call_once(once, [] {
      RIME_STRUCT_INIT(RimeVarPageApi, storage.varpage);
      storage.varpage.set_resolver = &varpage::SetResolver;
      storage.varpage.clear_resolver = &varpage::ClearResolver;
    });
    return &storage.custom;
  };
}
