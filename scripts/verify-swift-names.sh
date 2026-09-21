#!/usr/bin/env bash
set -euo pipefail

# Verifies that the Swift-facing names in Rime.apinotes actually take effect.
#
# The Clang importer ignores a malformed API note without any diagnostic, and
# the release pipeline refreshes Sources/RimeHeaders/include from build output,
# so a rename can regress silently. This probe compiles a snippet against the
# headers and fails if the plain names are missing.
#
# Usage: verify-swift-names.sh [include-dir]

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
include_dir="${1:-${repo_root}/Sources/RimeHeaders/include}"

if [[ ! -d "${include_dir}" ]]; then
  printf 'include directory does not exist: %s\n' "${include_dir}" >&2
  exit 1
fi

if [[ ! -f "${include_dir}/Rime.apinotes" ]]; then
  printf 'missing API notes: %s/Rime.apinotes\n' "${include_dir}" >&2
  printf 'Swift consumers would see the _stdbool suffixed names again\n' >&2
  exit 1
fi

scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT

# Every name the API notes are expected to provide, plus the suffixed spelling
# that must no longer resolve.
cat > "${scratch}/probe.swift" <<'SWIFT'
import Rime

// Renamed types.
let api = RimeApi.self
let menu = RimeMenu.self
let context = RimeContext.self
let status = RimeStatus.self
let levers = RimeLeversApi.self
// Renamed entry point.
let entry = rime_get_api.self

_ = (api, menu, context, status, levers, entry)
SWIFT

# Compile only: a systemLibrary target has no implementation to link against.
if ! xcrun swiftc -typecheck "${scratch}/probe.swift" -I "${include_dir}" \
    2> "${scratch}/probe.log"; then
  printf 'Swift name probe failed; expected the un-suffixed names to resolve:\n' >&2
  sed 's/^/  /' "${scratch}/probe.log" >&2
  exit 1
fi

# The suffixed spellings must be gone, otherwise the rename did not apply and
# the probe above may have passed on a stale module cache.
cat > "${scratch}/stale.swift" <<'SWIFT'
import Rime
_ = RimeApi_stdbool.self
SWIFT

if xcrun swiftc -typecheck "${scratch}/stale.swift" -I "${include_dir}" \
    > /dev/null 2>&1; then
  printf 'RimeApi_stdbool still resolves; the API notes were not applied\n' >&2
  exit 1
fi

printf 'swift name probe passed: un-suffixed names resolve, suffixed names are rejected\n'

# The logsink enums must import as Swift enums rather than as integers, which is
# what makes the constants passable to the API and exhaustive switches possible.
# Both properties regress silently if someone rewrites them as plain `int`.
cat > "${scratch}/logsink.swift" <<'SWIFT'
import Rime

// Swift-facing names, so the C identifiers with their RIME_LOGSINK_ prefix do
// not leak into call sites.
func describe(_ severity: RimeLogSinkSeverity) -> String {
  // Exhaustive on purpose; an open enum would require @unknown default here.
  switch severity {
  case .info: return "info"
  case .warning: return "warning"
  case .error: return "error"
  case .fatal: return "fatal"
  }
}

// The threshold enum has an off state that a record can never have, and its
// case names are namespaced by the type - so .info/.error appear on BOTH enums
// without an at- prefix, while C keeps its flat RIME_LOGSINK_AT_ identifiers.
let silent: RimeLogSinkThreshold = .silent
let atError: RimeLogSinkThreshold = .error
let atInfo: RimeLogSinkThreshold = .info

// And the constants must be passable to the API (an int parameter would reject
// them, which was the original defect).
func configure(_ api: inout RimeLogSinkApi) {
  _ = api.set_stderr_threshold(silent)
  _ = api.set_stderr_threshold(atError)
  _ = api.set_stderr_threshold(atInfo)
  _ = api.set_stderr_threshold(.fatal)
}

// The same case spelling on the other enum must still resolve to its own type.
func sameSpellingBothEnums(_ s: RimeLogSinkSeverity, _ t: RimeLogSinkThreshold) -> Bool {
  s == .info && t == .info
}

// The record's severity is the enum, so callers compare it as one.
func inspect(_ record: rime_logsink_record) -> Bool {
  record.severity == .error
}

_ = (describe, silent, atError, atInfo, configure, inspect, sameSpellingBothEnums)
SWIFT

if ! xcrun swiftc -typecheck "${scratch}/logsink.swift" -I "${include_dir}" \
    2> "${scratch}/logsink.log"; then
  printf 'logsink enum probe failed; the enums must import as Swift enums:\n' >&2
  sed 's/^/  /' "${scratch}/logsink.log" >&2
  exit 1
fi

printf 'logsink enum probe passed: severities and thresholds are Swift enums\n'

# The header must also be clean for plain C/C++ consumers compiled with a
# pedantic standard, which is where an unguarded Clang-only attribute (or an
# unmarked C23 fixed underlying type) shows up as a warning. GCC does not know
# swift_name/enum_extensibility at all, so this is the regression guard for the
# __has_attribute wiring.
cat > "${scratch}/c_consumer.c" <<'C'
#include <rime_logsink_api.h>
int main(void) {
  rime_logsink_severity severity = RIME_LOGSINK_WARNING;
  rime_logsink_threshold threshold = RIME_LOGSINK_AT_ERROR;
  return (int)(severity + threshold);
}
C

if ! xcrun clang -std=c99 -pedantic-errors -fsyntax-only -I "${include_dir}" \
    "${scratch}/c_consumer.c" 2> "${scratch}/c_consumer.log"; then
  printf 'C consumer does not compile cleanly under -std=c99 -pedantic-errors:\n' >&2
  sed 's/^/  /' "${scratch}/c_consumer.log" >&2
  exit 1
fi

if ! xcrun clang++ -std=c++17 -pedantic-errors -x c++ -fsyntax-only \
    -I "${include_dir}" "${scratch}/c_consumer.c" 2> "${scratch}/cpp.log"; then
  printf 'C++ consumer does not compile cleanly under -pedantic-errors:\n' >&2
  sed 's/^/  /' "${scratch}/cpp.log" >&2
  exit 1
fi

printf 'C/C++ pedantic probe passed: header is warning-free for plain consumers\n'

# RimeSystem declares the same module for a system-provided librime, so it needs
# the same notes. Compare rather than duplicating the probe: the two files must
# not drift.
system_notes="${repo_root}/Sources/RimeSystem/Rime.apinotes"
if [[ -f "${system_notes}" ]]; then
  if ! diff -q "${include_dir}/Rime.apinotes" "${system_notes}" >/dev/null; then
    printf 'Rime.apinotes has drifted between RimeHeaders and RimeSystem:\n' >&2
    diff "${include_dir}/Rime.apinotes" "${system_notes}" >&2 || true
    exit 1
  fi
  printf 'RimeSystem API notes are in sync\n'
fi
