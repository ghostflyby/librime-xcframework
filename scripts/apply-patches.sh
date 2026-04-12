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

shopt -s nullglob
patches=("${patch_dir}"/*.patch)
if [[ ${#patches[@]} -eq 0 ]]; then
  printf 'no patches to apply from %s\n' "${patch_dir}"
  exit 0
fi

for patch_file in "${patches[@]}"; do
  printf 'applying patch: %s\n' "${patch_file}"
  if [[ -d "${source_dir}/.git" ]]; then
    git -C "${source_dir}" apply "${patch_file}"
  else
    patch -d "${source_dir}" -p1 < "${patch_file}"
  fi
done

