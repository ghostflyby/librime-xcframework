#!/usr/bin/env bash
set -euo pipefail

# Verifies that the Swift-facing names in Rime.apinotes actually take effect.
#
# The Clang importer ignores a malformed API note without any diagnostic, and
# the release pipeline refreshes Sources/RimeHeaders/include from build output,
# so a rename can regress silently. This probe compiles a snippet against the
# headers and fails if the plain names are missing.
#
# The names probed here are not hardcoded: scripts/sync-apinotes.sh collects
# every declaration the headers flavor and emits both the notes and these
# probes, so a new flavored type in a header is covered without anyone
# remembering to extend the list. That matters because the missing-entry failure
# is invisible - the suffixed name simply stays in the Swift interface.
#
# Usage: verify-swift-names.sh [include-dir]
#
# The directory must hold the module map as well as the headers: the probes
# import the module rather than the individual headers.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
include_dir="${1:-${repo_root}/Sources/RimeHeaders/include}"

if [[ ! -d "${include_dir}" ]]; then
  printf 'include directory does not exist: %s\n' "${include_dir}" >&2
  exit 1
fi

if [[ ! -f "${include_dir}/module.modulemap" ]]; then
  # The artifacts deliberately carry no module map, so a slice's include
  # directory is not a valid target for this probe; say so rather than letting
  # the probes fail with 'no such module Rime'.
  printf 'no module.modulemap in %s; this probe needs a module to import\n' \
    "${include_dir}" >&2
  printf 'point it at Sources/RimeHeaders/include or a synced copy of it\n' >&2
  exit 1
fi

if [[ ! -f "${include_dir}/Rime.apinotes" ]]; then
  printf 'missing API notes: %s/Rime.apinotes\n' "${include_dir}" >&2
  printf 'Swift consumers would see the flavored (suffixed) names again\n' >&2
  exit 1
fi

scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT

# The collected notes must describe the headers they sit next to. A header that
# gained a flavored declaration and left the notes behind fails here instead of
# shipping a type whose suffix leaked into the Swift interface.
if ! "${script_dir}/sync-apinotes.sh" --check --headers "${include_dir}" \
    > "${scratch}/notes-check.log" 2>&1; then
  # Not necessarily staleness: the captured output carries the real cause (a
  # missing file, headers clang cannot parse, a missing tool), so print it whole
  # rather than asserting a reason.
  printf 'API notes do not match the headers in %s:\n' "${include_dir}" >&2
  sed 's/^/  /' "${scratch}/notes-check.log" >&2
  exit 1
fi

# Every name the API notes are expected to provide. Emitted by the collector, so
# this grows with the headers rather than with someone's memory.
{
  printf 'import Rime\n\n'
  "${script_dir}/sync-apinotes.sh" --print-probe plain --headers "${include_dir}"
} > "${scratch}/probe.swift"

# Compile only: a systemLibrary target has no implementation to link against.
if ! xcrun swiftc -typecheck "${scratch}/probe.swift" -I "${include_dir}" \
    2> "${scratch}/probe.log"; then
  printf 'Swift name probe failed; expected the un-suffixed names to resolve:\n' >&2
  sed 's/^/  /' "${scratch}/probe.log" >&2
  exit 1
fi

# The C spellings must be gone from what Swift sees. Asked of the interface as
# Clang and the importer present it rather than by compiling one probe per name:
# a single flavored declaration missing from the notes would otherwise pass,
# since a probe with many errors fails whether one error or all of them are the
# rename mistakes. Both directions are checked: every name the notes claim to
# rename must be absent, and no name carrying the flavor suffix may survive -
# the second catches a declaration the collector never saw, including one
# reached through a header the shim does not include.
flavor_suffix="$("${script_dir}/sync-apinotes.sh" --print-flavor-suffix \
  --headers "${include_dir}")"
"${script_dir}/sync-apinotes.sh" --print-probe names --headers "${include_dir}" \
  > "${scratch}/renamed-c-names.txt"

if ! xcrun swift-api-digester -dump-sdk -module Rime -I "${include_dir}" \
    -o "${scratch}/swift-interface.json" 2> "${scratch}/digester.log"; then
  printf 'could not dump the Swift interface of module Rime:\n' >&2
  sed 's/^/  /' "${scratch}/digester.log" >&2
  exit 1
fi

scan_status=0
python3 - "${scratch}/swift-interface.json" "${flavor_suffix}" \
  "${scratch}/renamed-c-names.txt" > "${scratch}/leftovers.log" \
  2> "${scratch}/scan-error.log" <<'PY' || scan_status=$?
import json
import sys

try:
    interface = json.load(open(sys.argv[1]))
    suffix = sys.argv[2]
    claimed = [line for line in open(sys.argv[3]).read().splitlines() if line]
except Exception as error:  # noqa: BLE001 - reported as a tool failure below
    print(f"could not read the scan inputs: {error}", file=sys.stderr)
    raise SystemExit(3)

visible = set()


def walk(node):
    if isinstance(node, dict):
        # Imports name modules, not the declarations the notes cover
        # (`_Builtin_stdbool` is the Swift standard library's).
        if node.get("kind") != "Import":
            for key in ("name", "printedName"):
                value = node.get(key)
                if isinstance(value, str):
                    visible.add(value)
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)


walk(interface)

# A module that failed to load still lets the digester exit 0 with no
# declarations, and a scan over nothing finds nothing: without this, the checks
# below would pass precisely when the headers stopped being readable at all.
if not any(name.startswith("rime") or name.startswith("Rime") for name in visible):
    print("the dumped interface contains no librime declarations")
    print("the module did not load, so this scan would be vacuous")
    raise SystemExit(2)

leftovers = sorted(set(claimed) & visible)
leftovers += sorted(name for name in visible
                    if suffix in name and not name.startswith("_Builtin"))
if leftovers:
    for name in dict.fromkeys(leftovers):
        print(name)
    raise SystemExit(1)
PY

# Distinct statuses, because a crash here must not be reported as a rename
# failure: 1 is leftovers found, 2 is a vacuous scan, 3 is the scan itself
# failing, and anything else is the interpreter never running.
case "${scan_status}" in
  0) ;;
  1)
    printf 'these C names were not renamed for Swift consumers:\n' >&2
    sed 's/^/  /' "${scratch}/leftovers.log" >&2
    printf 'each one needs an entry in the API notes (run scripts/sync-apinotes.sh)\n' >&2
    exit 1
    ;;
  2)
    printf 'could not read the Swift interface of module Rime:\n' >&2
    sed 's/^/  /' "${scratch}/leftovers.log" >&2
    exit 1
    ;;
  3)
    printf 'the Swift interface scan could not run:\n' >&2
    sed 's/^/  /' "${scratch}/scan-error.log" >&2
    exit 1
    ;;
  *)
    printf 'the Swift interface scan did not run (exit %s):\n' "${scan_status}" >&2
    sed 's/^/  /' "${scratch}/scan-error.log" >&2
    printf 'is python3 on PATH?\n' >&2
    exit 1
    ;;
esac

printf 'swift name probe passed: un-suffixed names resolve, no suffixed name is visible\n'

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

# The enums deliberately have no fixed underlying type, so the 4-byte
# representation the ABI depends on is a property of the current value set
# rather than a guarantee. Assert it here: if a value is ever added that pushes
# the compiler to a different type, this fails the release pipeline instead of
# silently shifting rime_logsink_record's layout.
cat > "${scratch}/layout.c" <<'C'
#include <rime_logsink_api.h>
#include <stddef.h>
#include <stdio.h>
int main(void) {
  printf("%zu %zu %zu\n", sizeof(rime_logsink_severity),
         sizeof(rime_logsink_threshold), sizeof(rime_logsink_record));
  return 0;
}
C

if ! xcrun clang -arch arm64 -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    -mmacosx-version-min=11.0 -I "${include_dir}" "${scratch}/layout.c" \
    -o "${scratch}/layout" 2> "${scratch}/layout.log"; then
  printf 'layout probe does not compile:\n' >&2
  sed 's/^/  /' "${scratch}/layout.log" >&2
  exit 1
fi

layout="$("${scratch}/layout")"
if [[ "${layout}" != "4 4 64" ]]; then
  printf 'unexpected enum/record layout: %s (expected "4 4 64")\n' "${layout}" >&2
  printf 'a change to the enum values or the record fields altered the ABI\n' >&2
  exit 1
fi

printf 'layout probe passed: 4-byte enums, 64-byte record\n'

# RimeSystem declares the same module for a system-provided librime, so it needs
# the same notes. Compare rather than duplicating the probe: the two files must
# not drift. A missing copy fails here too - AGENTS.md requires the file in both
# places, and the release commit stages Sources/RimeSystem, so deleting it would
# otherwise ship unnoticed.
system_notes="${repo_root}/Sources/RimeSystem/Rime.apinotes"
if [[ ! -f "${system_notes}" ]]; then
  printf 'missing API notes: %s\n' "${system_notes}" >&2
  printf 'run scripts/sync-apinotes.sh to write both copies\n' >&2
  exit 1
fi
if ! diff -q "${include_dir}/Rime.apinotes" "${system_notes}" >/dev/null; then
  printf 'Rime.apinotes has drifted between RimeHeaders and RimeSystem:\n' >&2
  diff "${include_dir}/Rime.apinotes" "${system_notes}" >&2 || true
  exit 1
fi
printf 'RimeSystem API notes are in sync\n'
