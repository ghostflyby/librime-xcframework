#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'usage: %s <source-dir>\n' "$0" >&2
  exit 2
fi

source_dir="$1"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
patch_dir="${PATCH_DIR:-${repo_root}/patches}"

if [[ ! -d "${source_dir}" ]]; then
  printf 'source directory does not exist: %s\n' "${source_dir}" >&2
  exit 1
fi

apply_one() {
  local patch_file="$1"

  if [[ -d "${source_dir}/.git" ]]; then
    if git -C "${source_dir}" apply --check "${patch_file}" >/dev/null 2>&1; then
      git -C "${source_dir}" apply "${patch_file}"
      return 0
    fi
    if git -C "${source_dir}" apply --reverse --check "${patch_file}" >/dev/null 2>&1; then
      printf 'patch already applied, skipping: %s\n' "${patch_file}"
      return 0
    fi
    printf 'patch does not apply cleanly: %s\n' "${patch_file}" >&2
    return 1
  fi

  # --forward is required: without it, `patch` detects an already-applied patch
  # and silently *reverses* it, which would strip the fix the patch carries.
  if patch -d "${source_dir}" -p1 --forward --batch --dry-run \
      < "${patch_file}" >/dev/null 2>&1; then
    patch -d "${source_dir}" -p1 --forward --batch < "${patch_file}"
    return 0
  fi
  if patch -d "${source_dir}" -p1 --reverse --batch --dry-run \
      < "${patch_file}" >/dev/null 2>&1; then
    printf 'patch already applied, skipping: %s\n' "${patch_file}"
    return 0
  fi
  printf 'patch does not apply cleanly: %s\n' "${patch_file}" >&2
  return 1
}

shopt -s nullglob
patches=("${patch_dir}"/*.patch)
if [[ ${#patches[@]} -eq 0 ]]; then
  printf 'no patches to apply from %s\n' "${patch_dir}"
  exit 0
fi

for patch_file in "${patches[@]}"; do
  printf 'applying patch: %s\n' "${patch_file}"
  apply_one "${patch_file}"
done
