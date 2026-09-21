#!/usr/bin/env bash
set -euo pipefail

# Copies the plugin submodule checkouts into the upstream source tree, applies
# per-plugin patches, and verifies the licenses we expect to redistribute.
#
# Usage: prepare-plugins.sh <source-dir>
#
# Prints the module list on stdout for callers that want to feed RIME_PLUGINS
# to the upstream CMake build. All progress and error output goes to stderr.

if [[ $# -ne 1 ]]; then
  printf 'usage: %s <source-dir>\n' "$0" >&2
  exit 2
fi

source_dir="$1"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
manifest_path="${PLUGINS_MANIFEST:-${repo_root}/plugins.json}"

if [[ ! -d "${source_dir}" ]]; then
  printf 'source directory does not exist: %s\n' "${source_dir}" >&2
  exit 1
fi

if [[ ! -f "${manifest_path}" ]]; then
  printf 'plugin manifest does not exist: %s\n' "${manifest_path}" >&2
  exit 1
fi

plugin_fields="$(mktemp)"
trap 'rm -f "${plugin_fields}"' EXIT

# Write the fields through a real file, not a process substitution, so a
# manifest parse failure is reported instead of silently truncating the list.
if ! python3 - "${manifest_path}" > "${plugin_fields}" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for plugin in data["plugins"]:
    if plugin["name"] != plugin["module"]:
        raise SystemExit(
            "plugin %r declares module %r; the module name must match the "
            "plugin directory name that upstream CMake reads"
            % (plugin["name"], plugin["module"]))
    fields = [
        plugin["name"],
        plugin["module"],
        plugin["path"],
        plugin["license"],
        plugin.get("license_file", "LICENSE"),
        plugin.get("license_marker", ""),
        plugin.get("patch", ""),
    ]
    print("\x1f".join(fields))
PY
then
  printf 'failed to read plugin manifest: %s\n' "${manifest_path}" >&2
  exit 1
fi

expected_count="$(wc -l < "${plugin_fields}" | tr -d ' ')"
if [[ "${expected_count}" -eq 0 ]]; then
  printf 'plugin manifest lists no plugins: %s\n' "${manifest_path}" >&2
  exit 1
fi

plugin_names=()
module_names=()

while IFS=$'\x1f' read -r name module path license license_file license_marker patch; do
  plugin_src="${repo_root}/${path}"
  plugin_dst="${source_dir}/plugins/${name}"

  if [[ ! -d "${plugin_src}" ]]; then
    printf 'plugin checkout missing: %s (run: git submodule update --init --recursive)\n' "${plugin_src}" >&2
    exit 1
  fi

  if [[ ! -f "${plugin_src}/${license_file}" ]]; then
    printf '[%s] license file missing: %s\n' "${name}" "${plugin_src}/${license_file}" >&2
    exit 1
  fi

  # librime-octagram was GPLv3 until its 2026-07 relicense, so a stale pin
  # silently brings copyleft into the artifacts. Refuse anything whose license
  # text is not the expected one.
  if [[ -z "${license_marker}" ]]; then
    printf '[%s] manifest declares no license_marker, so the %s license cannot be verified\n' \
      "${name}" "${license}" >&2
    exit 1
  fi
  if ! grep -qF "${license_marker}" "${plugin_src}/${license_file}"; then
    printf '[%s] expected %s license text in %s but did not find: %s\n' \
      "${name}" "${license}" "${license_file}" "${license_marker}" >&2
    printf '[%s] refusing to build: a stale pin would redistribute the wrong license\n' "${name}" >&2
    exit 1
  fi

  rm -rf "${plugin_dst}"
  rsync -a --delete --exclude .git "${plugin_src}/" "${plugin_dst}/"

  if [[ -n "${patch}" ]]; then
    patch_path="${repo_root}/${patch}"
    if [[ ! -f "${patch_path}" ]]; then
      printf '[%s] patch listed in manifest is missing: %s\n' "${name}" "${patch_path}" >&2
      exit 1
    fi
    printf 'applying plugin patch [%s]: %s\n' "${name}" "${patch}" >&2
    # --forward keeps an already-applied patch from being silently reversed.
    if ! patch -d "${plugin_dst}" -p1 --forward --batch < "${patch_path}" >&2; then
      printf '[%s] plugin patch did not apply cleanly: %s\n' "${name}" "${patch}" >&2
      exit 1
    fi
  fi

  plugin_names+=("${name}")
  module_names+=("${module}")
done < "${plugin_fields}"

if [[ "${#plugin_names[@]}" -ne "${expected_count}" ]]; then
  printf 'prepared %d plugin(s) but the manifest lists %d\n' \
    "${#plugin_names[@]}" "${expected_count}" >&2
  exit 1
fi

printf 'prepared %d plugin(s): %s\n' "${#plugin_names[@]}" "${plugin_names[*]}" >&2
printf '%s\n' "${module_names[*]}"
