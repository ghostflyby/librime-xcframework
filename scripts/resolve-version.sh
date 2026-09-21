#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

source_dir="${UPSTREAM_SOURCE_DIR:-}"
if [[ -z "${source_dir}" ]]; then
  if [[ -d "${repo_root}/vendor/librime" ]]; then
    source_dir="${repo_root}/vendor/librime"
  elif [[ -d "${repo_root}/../librime" ]]; then
    source_dir="${repo_root}/../librime"
  else
    source_dir="${repo_root}/vendor/librime"
  fi
fi

packaging_version="${PACKAGING_VERSION:-}"

upstream_repo="${UPSTREAM_REPO:-rime/librime}"
# "worktree" is what build-one-arch.sh exports when it built the checkout
# rather than a ref; anything else is a ref that was resolved before building.
upstream_ref="${UPSTREAM_REF:-}"
if [[ -z "${upstream_ref}" ]]; then
  upstream_ref="worktree"
fi

upstream_version="unknown"
if [[ -f "${source_dir}/CMakeLists.txt" ]]; then
  upstream_version="$(sed -nE 's/^[[:space:]]*set\(rime_version[[:space:]]+([^[:space:]\)]+)\).*/\1/p' "${source_dir}/CMakeLists.txt" | head -n 1)"
  upstream_version="${upstream_version:-unknown}"
fi

upstream_commit="unknown"
if [[ -d "${source_dir}/.git" ]]; then
  if git -C "${source_dir}" rev-parse "${upstream_ref}^{commit}" >/dev/null 2>&1; then
    upstream_commit="$(git -C "${source_dir}" rev-parse "${upstream_ref}^{commit}")"
  elif git -C "${source_dir}" rev-parse HEAD >/dev/null 2>&1; then
    # A worktree build: the content is HEAD plus whatever is uncommitted, so a
    # bare commit hash would overstate how reproducible this build is.
    upstream_commit="$(git -C "${source_dir}" rev-parse HEAD)"
    if [[ -n "$(git -C "${source_dir}" status --porcelain 2>/dev/null)" ]]; then
      upstream_commit="${upstream_commit}-dirty"
    fi
  fi
fi

case "${1:-human}" in
  --env)
    printf 'UPSTREAM_REPO=%s\n' "${upstream_repo}"
    printf 'UPSTREAM_SOURCE_DIR=%s\n' "${source_dir}"
    printf 'UPSTREAM_REF=%s\n' "${upstream_ref}"
    printf 'UPSTREAM_VERSION=%s\n' "${upstream_version}"
    printf 'UPSTREAM_COMMIT=%s\n' "${upstream_commit}"
    printf 'PACKAGING_VERSION=%s\n' "${packaging_version}"
    ;;
  *)
    printf 'upstream_repo: %s\n' "${upstream_repo}"
    printf 'upstream_source_dir: %s\n' "${source_dir}"
    printf 'upstream_ref: %s\n' "${upstream_ref}"
    printf 'upstream_version: %s\n' "${upstream_version}"
    printf 'upstream_commit: %s\n' "${upstream_commit}"
    printf 'packaging_version: %s\n' "${packaging_version}"
    ;;
esac
