#!/usr/bin/env bash
set -euo pipefail

output_path="${1:-dist/build-metadata.json}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
mkdir -p "$(dirname "${output_path}")"

source_dir="${UPSTREAM_SOURCE_DIR:-}"
if [[ -z "${source_dir}" ]]; then
  if [[ -d "${repo_root}/vendor/librime" ]]; then
    source_dir="${repo_root}/vendor/librime"
  elif [[ -d "${repo_root}/../librime" ]]; then
    source_dir="${repo_root}/../librime"
  else
    source_dir=""
  fi
fi

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

upstream_repo="${UPSTREAM_REPO:-rime/librime}"
upstream_ref="${UPSTREAM_REF:-HEAD}"
upstream_version="${UPSTREAM_VERSION:-unknown}"
upstream_commit="${UPSTREAM_COMMIT:-unknown}"
packaging_version="${PACKAGING_VERSION:-unknown}"

if [[ -d "${source_dir}/.git" ]]; then
  if git -C "${source_dir}" rev-parse "${upstream_ref}^{commit}" >/dev/null 2>&1; then
    upstream_commit="$(git -C "${source_dir}" rev-parse "${upstream_ref}^{commit}")"
  elif git -C "${source_dir}" rev-parse HEAD >/dev/null 2>&1; then
    upstream_commit="$(git -C "${source_dir}" rev-parse HEAD)"
  fi
fi

if [[ "${upstream_version}" == "unknown" && -f "${source_dir}/CMakeLists.txt" ]]; then
  parsed_version="$(sed -nE 's/^[[:space:]]*set\(rime_version[[:space:]]+([^[:space:]\)]+)\).*/\1/p' "${source_dir}/CMakeLists.txt" | head -n 1)"
  upstream_version="${parsed_version:-unknown}"
fi

packaging_commit="unknown"
if git -C "${repo_root}" rev-parse HEAD >/dev/null 2>&1; then
  packaging_commit="$(git -C "${repo_root}" rev-parse HEAD)"
fi

xcode_version="unknown"
if command -v xcodebuild >/dev/null 2>&1; then
  xcode_version="$(xcodebuild -version | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
fi

macos_version="unknown"
if command -v sw_vers >/dev/null 2>&1; then
  macos_version="$(sw_vers -productVersion)"
fi

plugin_entries=""
manifest_path="${PLUGINS_MANIFEST:-${repo_root}/plugins.json}"
if [[ -f "${manifest_path}" ]]; then
  plugin_entries="$(python3 - "${manifest_path}" "${repo_root}" <<'PY'
import json, subprocess, sys, re
manifest, repo_root = sys.argv[1], sys.argv[2]


def pinned_commit(path):
    """Resolve the submodule revision recorded by this repository.

    `git -C <submodule> rev-parse HEAD` is not usable here: on an uninitialized
    submodule it walks up and reports the enclosing repository's HEAD, which
    would record the wrapper's commit as the plugin's. Submodule status reports
    the gitlink recorded in the repository, prefixed with '-' when the
    submodule is not checked out.
    """
    result = subprocess.run(
        ["git", "-C", repo_root, "submodule", "status", "--", path],
        capture_output=True, text=True, check=True)
    for line in result.stdout.splitlines():
        match = re.match(r"\s*[-+U]?([0-9a-f]{40})\s+(\S+)", line)
        if match and match.group(2) == path:
            return match.group(1)
    return "unknown"


def wrapper_repo():
    """owner/name of this packaging repository, from its git remote."""
    try:
        url = subprocess.run(
            ["git", "-C", repo_root, "remote", "get-url", "origin"],
            capture_output=True, text=True, check=True).stdout.strip()
    except Exception:
        return "librime-xcframework"
    for prefix in ("https://github.com/", "git@github.com:"):
        if url.startswith(prefix):
            url = url[len(prefix):]
    if url.endswith(".git"):
        url = url[:-4]
    return url


entries = []
wrapper = wrapper_repo()
for plugin in json.load(open(manifest))["plugins"]:
    is_local = bool(plugin.get("local"))
    if is_local:
        # A local plugin is a source directory of this repository, covered by
        # the wrapper LICENSE; what identifies it is the packaging commit, and
        # there is no upstream repo or pin to record.
        repo = wrapper
        try:
            commit = subprocess.run(
                ["git", "-C", repo_root, "rev-parse", "HEAD"],
                capture_output=True, text=True, check=True).stdout.strip()
        except Exception:
            commit = "unknown"
    else:
        commit = pinned_commit(plugin["path"])
        url = plugin["url"]
        repo = url.rsplit("github.com/", 1)[-1]
        if repo.endswith(".git"):
            repo = repo[:-4]
    entries.append(
        '    {\n'
        f'      "name": {json.dumps(plugin["name"])},\n'
        f'      "module": {json.dumps(plugin["module"])},\n'
        f'      "repo": {json.dumps(repo)},\n'
        f'      "commit": {json.dumps(commit)},\n'
        f'      "license": {json.dumps(plugin["license"])}\n'
        '    }')
print(",\n".join(entries))
PY
)"
fi
if [[ -z "${plugin_entries}" ]]; then
  plugin_entries=""
fi

cat > "${output_path}" <<JSON
{
  "packaging_version": "$(json_escape "${packaging_version}")",
  "upstream_repo": "$(json_escape "${upstream_repo}")",
  "upstream_ref": "$(json_escape "${upstream_ref}")",
  "upstream_version": "$(json_escape "${upstream_version}")",
  "upstream_commit": "$(json_escape "${upstream_commit}")",
  "packaging_commit": "$(json_escape "${packaging_commit}")",
  "xcode_version": "$(json_escape "${xcode_version}")",
  "runner_macos_version": "$(json_escape "${macos_version}")",
  "plugins": [
${plugin_entries}
  ],
  "artifacts": [
    "librime-static.xcframework.zip",
    "librime-dynamic.xcframework.zip",
    "librime-stub.zip",
    "LICENSE.txt",
    "THIRD_PARTY_NOTICES.md",
    "third-party-notices.zip",
    "build-metadata.json"
  ]
}
JSON

printf 'wrote metadata: %s\n' "${output_path}"
