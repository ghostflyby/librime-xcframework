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
