#!/usr/bin/env bash
set -euo pipefail

# Collects license texts for the statically merged plugins into the
# third-party notices bundle, verifying the expected license text is present.
#
# Usage: collect-plugin-notices.sh <dest-dir>

if [[ $# -ne 1 ]]; then
  printf 'usage: %s <dest-dir>\n' "$0" >&2
  exit 2
fi

dest_dir="$1"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
manifest_path="${PLUGINS_MANIFEST:-${repo_root}/plugins.json}"

if [[ ! -f "${manifest_path}" ]]; then
  printf 'plugin manifest does not exist: %s\n' "${manifest_path}" >&2
  exit 1
fi

mkdir -p "${dest_dir}/plugins"

while IFS=$'\x1f' read -r name license license_file license_marker; do
  license_src="${repo_root}/plugins/${name}/${license_file}"
  if [[ ! -f "${license_src}" ]]; then
    printf '[%s] license file missing: %s\n' "${name}" "${license_src}" >&2
    printf '[%s] run: git submodule update --init --recursive\n' "${name}" >&2
    exit 1
  fi
  if [[ -n "${license_marker}" ]] && ! grep -qF "${license_marker}" "${license_src}"; then
    printf '[%s] expected %s license text in %s but did not find: %s\n' \
      "${name}" "${license}" "${license_file}" "${license_marker}" >&2
    exit 1
  fi
  cp "${license_src}" "${dest_dir}/plugins/${name}.txt"
  printf '%s\t%s\n' "${name}" "${license}"
done < <(python3 - "${manifest_path}" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for plugin in data["plugins"]:
    fields = [
        plugin["name"],
        plugin["license"],
        plugin.get("license_file", "LICENSE"),
        plugin.get("license_marker", ""),
    ]
    print("\x1f".join(fields))
PY
)
