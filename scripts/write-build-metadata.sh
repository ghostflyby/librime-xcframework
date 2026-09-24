#!/usr/bin/env bash
set -euo pipefail

output_path="${1:-dist/build-metadata.json}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
mkdir -p "$(dirname "${output_path}")"

# Which upstream this describes, and which tree it was read from, is
# resolve-version.sh's answer rather than a second implementation of the same
# ladder: this script and the build that produced the artifacts have to agree
# about what was built, and two copies of the rules would be free to drift.
#
# A key that is absent is an error. resolve-version.sh always prints all of them,
# so a miss means the two scripts no longer agree on the names - and a release
# whose metadata silently recorded nothing for a field would describe an artifact
# by omission.
resolve_upstream() {
  local key="$1" value

  value="$(sed -n "s/^${key}=//p" <<< "${upstream_env}")"
  if [[ -z "${value}" ]]; then
    # Set only for a release, so an empty one is a local build rather than a
    # disagreement between the two scripts.
    if [[ "${key}" == "PACKAGING_VERSION" ]]; then
      printf '%s\n' "unknown"
      return 0
    fi
    printf 'resolve-version.sh reported no value for %s\n' "${key}" >&2
    exit 1
  fi
  printf '%s\n' "${value}"
}

upstream_env="$("${script_dir}/resolve-version.sh" --env)"

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

upstream_repo="$(resolve_upstream UPSTREAM_REPO)"
upstream_ref="$(resolve_upstream UPSTREAM_REF)"
upstream_version="$(resolve_upstream UPSTREAM_VERSION)"
upstream_commit="$(resolve_upstream UPSTREAM_COMMIT)"
packaging_version="$(resolve_upstream PACKAGING_VERSION)"

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
