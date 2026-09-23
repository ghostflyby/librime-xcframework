#!/usr/bin/env bash
set -euo pipefail

# Verifies the headers this repository commits, without building anything: the
# package ships Sources/RimeHeaders/include as-is, so a mistake there (an
# umbrella that no longer compiles, notes that disagree with their headers, a
# plugin header that was edited in one copy and not the other) is otherwise
# found only while preparing a release.
#
# The copy check exists because a local plugin's public header is committed
# twice: once beside the plugin, which is what install_plugin_headers copies into
# the export set, and once under Sources/RimeHeaders/include, which is what
# consumers import. They are two files that must always agree, and until this
# script nothing checked it - unlike Rime.apinotes, which verify-swift-names.sh
# already guards.
#
# What this cannot check is that the committed headers match a *build*, because
# that needs the artifacts. The build produces the export set from the sources,
# and the release pipeline syncs that back over Sources/RimeHeaders/include, so a
# committed copy that drifted from a build is corrected there rather than here.
#
# usage: verify-committed-headers.sh [--headers <include-dir>]

usage() {
  cat <<'EOF'
usage: verify-committed-headers.sh [--headers <include-dir>]

  --headers <include-dir>  directory holding the committed headers, and the
                           module map that names the umbrella header
                           (default: Sources/RimeHeaders/include)
EOF
}

headers_dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --headers)
      headers_dir="${2:?--headers requires a directory}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown argument: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "${headers_dir}" ]]; then
  headers_dir="${repo_root}/Sources/RimeHeaders/include"
fi
if [[ ! -d "${headers_dir}" ]]; then
  printf 'no headers directory at %s\n' "${headers_dir}" >&2
  exit 1
fi

# The list of local plugins, read once and checked: a manifest that cannot be
# parsed must fail the script rather than turn every check below into a silent
# no-op, which is the one outcome it must never have.
manifest_listing=""
if ! manifest_listing="$(python3 - "${repo_root}/plugins.json" <<'PY'
import json
import sys

for plugin in json.load(open(sys.argv[1]))["plugins"]:
    if plugin.get("local"):
        sys.stdout.write(plugin["name"] + "\x1f" + plugin["path"] + "\n")
PY
)"; then
  printf 'could not read the local plugins from %s\n' \
    "${repo_root}/plugins.json" >&2
  exit 1
fi
if [[ -z "${manifest_listing}" ]]; then
  printf 'no local plugins in %s; expected at least one\n' \
    "${repo_root}/plugins.json" >&2
  exit 1
fi

# The module map names the umbrella, so read it before the checks that need it.
modulemap="${headers_dir}/module.modulemap"
if [[ ! -f "${modulemap}" ]]; then
  printf 'no module.modulemap in %s\n' "${headers_dir}" >&2
  exit 1
fi
# grep -o rather than sed on the line's shape: the clause may share a line with
# the rest of the module declaration, which is how the packaging step writes it.
umbrella="$(grep -o 'umbrella header[[:space:]]*"[^"]*"' "${modulemap}" |
  head -1 | sed 's/.*"\(.*\)"/\1/')"
if [[ -z "${umbrella}" ]]; then
  printf 'module.modulemap names no umbrella header: %s\n' "${modulemap}" >&2
  exit 1
fi
if [[ ! -f "${headers_dir}/${umbrella}" ]]; then
  printf 'umbrella header %s named by the module map does not exist in %s\n' \
    "${umbrella}" "${headers_dir}" >&2
  exit 1
fi

# 1. Every local plugin's public header must be byte-identical in both copies.
#
# The set of headers comes from the plugin's own directory, and both directions
# matter: a header that exists only there has not been exported at all, and one
# that exists only in the committed set is stale. So a local plugin with no
# header to check is an error, not a skip.
printf 'checking plugin header copies\n'
checked_headers=0
while IFS=$'\x1f' read -r name path; do
  [[ -n "${name}" ]] || continue
  plugin_include="${repo_root}/${path}/include"
  if [[ ! -d "${plugin_include}" ]]; then
    printf 'local plugin %s has no include directory: %s\n' \
      "${name}" "${plugin_include}" >&2
    exit 1
  fi
  found_any=0
  while IFS= read -r -d '' source; do
    found_any=1
    name_only="$(basename "${source}")"
    committed="${headers_dir}/${name_only}"
    if [[ ! -f "${committed}" ]]; then
      printf 'plugin %s header %s is not committed under %s\n' \
        "${name}" "${name_only}" "${headers_dir}" >&2
      exit 1
    fi
    if ! diff -q "${source}" "${committed}" >/dev/null; then
      printf 'plugin %s header %s differs between its two committed copies:\n' \
        "${name}" "${name_only}" >&2
      printf '  %s\n  %s\n' "${source}" "${committed}" >&2
      diff -u "${source}" "${committed}" >&2 || true
      exit 1
    fi
    checked_headers=$((checked_headers + 1))
  done < <(find "${plugin_include}" -maxdepth 1 -name '*.h' -print0)
  if [[ "${found_any}" -eq 0 ]]; then
    printf 'local plugin %s exports no public header from %s\n' \
      "${name}" "${plugin_include}" >&2
    exit 1
  fi
done <<< "${manifest_listing}"

if [[ "${checked_headers}" -eq 0 ]]; then
  printf 'no plugin headers were found to check\n' >&2
  exit 1
fi

# 2. Every plugin header must be reachable from the umbrella. A header nothing
#    includes contributes no declarations to the module, so neither the smoke
#    test below nor the notes check could notice it dropping out of RimeShim.h.
printf 'checking the umbrella includes every plugin header\n'
while IFS=$'\x1f' read -r name path; do
  [[ -n "${name}" ]] || continue
  while IFS= read -r -d '' source; do
    name_only="$(basename "${source}")"
    if ! grep -qF "#include \"${name_only}\"" "${headers_dir}/${umbrella}"; then
      printf 'umbrella %s does not include plugin header %s\n' \
        "${umbrella}" "${name_only}" >&2
      exit 1
    fi
  done < <(find "${repo_root}/${path}/include" -maxdepth 1 -name '*.h' -print0)
done <<< "${manifest_listing}"

# 3. The umbrella must still compile as a module, which is how consumers import
#    it: this catches a header the commit dropped, renamed, or broke. Same check
#    the packaging step runs, against the committed set instead of the built one.
printf 'checking the umbrella header compiles as a module\n'
smoke_dir="$(mktemp -d)"
trap 'rm -rf "${smoke_dir}"' EXIT
printf '#include "%s"\n' "${umbrella}" > "${smoke_dir}/smoke.c"
xcrun clang -fmodules -fsyntax-only -I "${headers_dir}" "${smoke_dir}/smoke.c"

# 4. API notes and Swift names, both of which describe the committed set and are
#    what consumers see. These are the same two checks the release runs, so a
#    pull request that edits a header or its notes fails here rather than there.
printf 'checking API notes and Swift names\n'
"${repo_root}/scripts/sync-apinotes.sh" --check --headers "${headers_dir}"
"${repo_root}/scripts/verify-swift-names.sh" "${headers_dir}"

printf 'verified committed headers in %s\n' "${headers_dir}"
