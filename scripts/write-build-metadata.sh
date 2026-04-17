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
  "artifacts": [
    "librime-static.xcframework.zip",
    "librime-dynamic.xcframework.zip",
    "build-metadata.json"
  ]
}
JSON

printf 'wrote metadata: %s\n' "${output_path}"
