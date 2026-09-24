#!/usr/bin/env bash
set -euo pipefail

# Describes the upstream source a build came from: which tree, ref, version and
# commit. This is the one place the source-resolution ladder and the version
# parsing live - build-one-arch.sh asks here which tree to build, and
# write-build-metadata.sh asks here what to record - so a build and its
# description cannot disagree about which upstream they mean.
#
# Modes:
#   (default)           human-readable report
#   --env               KEY=VALUE lines, for sourcing or appending to a file
#   --print-source-dir  the source directory only, exiting non-zero if none
#                       exists. A build needs this failure; the reporting modes
#                       instead degrade to "unknown", because describing a build
#                       that already happened should not fail for want of a
#                       checkout that is no longer present.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

# UPSTREAM_SOURCE_DIR, then vendor/librime, then ../librime. No fallback to a
# path that does not exist: a caller that needs a tree has to be told there is
# none, rather than left to interpret an empty or invented answer.
source_dir="${UPSTREAM_SOURCE_DIR:-}"
if [[ -z "${source_dir}" ]]; then
  if [[ -d "${repo_root}/vendor/librime" ]]; then
    source_dir="${repo_root}/vendor/librime"
  elif [[ -d "${repo_root}/../librime" ]]; then
    source_dir="${repo_root}/../librime"
  fi
fi

if [[ "${1:-human}" == "--print-source-dir" ]]; then
  if [[ -z "${source_dir}" || ! -d "${source_dir}" ]]; then
    exit 1
  fi
  printf '%s\n' "${source_dir}"
  exit 0
fi

packaging_version="${PACKAGING_VERSION:-}"

upstream_repo="${UPSTREAM_REPO:-rime/librime}"
# "worktree" is what build-one-arch.sh exports when it built the checkout
# rather than a ref; anything else is a ref that was resolved before building.
upstream_ref="${UPSTREAM_REF:-}"
if [[ -z "${upstream_ref}" ]]; then
  upstream_ref="worktree"
fi

# The version and commit come from the tree when there is one, which is what a
# build just used. They fall back to the environment for the case with no tree at
# all: the packaging job works from downloaded slices, carrying the values the
# build recorded in source.env, and has no checkout to read them from.
upstream_version="unknown"
if [[ -n "${source_dir}" && -f "${source_dir}/CMakeLists.txt" ]]; then
  upstream_version="$(sed -nE 's/^[[:space:]]*set\(rime_version[[:space:]]+([^[:space:]\)]+)\).*/\1/p' "${source_dir}/CMakeLists.txt" | head -n 1)"
  upstream_version="${upstream_version:-unknown}"
fi
if [[ "${upstream_version}" == "unknown" ]]; then
  upstream_version="${UPSTREAM_VERSION:-unknown}"
fi

upstream_commit="unknown"
if [[ -n "${source_dir}" && -d "${source_dir}/.git" ]]; then
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
if [[ "${upstream_commit}" == "unknown" ]]; then
  upstream_commit="${UPSTREAM_COMMIT:-unknown}"
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
