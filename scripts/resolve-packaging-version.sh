#!/usr/bin/env bash
set -euo pipefail

# Resolves the release tag for a build.
#
# Format: <upstream-version>-pack.<epoch>.<minor>.<patch>
#
#   epoch  Packaging era. A constant for this scheme; see BASE_EPOCH below.
#   minor  Manual: a packaging change worth distinguishing (new capability,
#          changed behaviour for consumers). Bumped by passing an explicit
#          PACKAGING_VERSION.
#   patch  Automatic: plain rebuilds of the same upstream version. This script
#          only ever bumps the patch.
#
# Reading a version, the epoch and minor tell you which packaging era and which
# feature level are inside; the patch only says "another build of the same
# thing". So an automatic build never changes what a consumer is being offered.
#
# The old scheme was <upstream-version>-pack.<N> with a bare counter. Those tags
# are still respected: the epoch starts above the highest one, so the new
# sequence orders above the old one without rewriting any tag, and the first
# automatic build after the switch continues from where the counter stopped.
#
# Usage: resolve-packaging-version.sh
#
# Reads:  UPSTREAM_VERSION   the upstream version being packaged (required
#                            unless PACKAGING_VERSION is given)
#         PACKAGING_VERSION  explicit full tag; used verbatim when non-empty
#         EXISTING_TAGS      optional file of tag names, one per line, for
#                            offline use; otherwise queried from origin
# Writes: the resolved version on stdout

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

# The packaging era for the epoch.minor.patch scheme. It has to exceed every
# single-number revision already published under the old scheme (the highest is
# pack.8), which is what lets the new tags order above the old ones without
# deleting or rewriting anything. It is a constant, not a counter: bumping it is
# a deliberate act, not something an automatic build does.
BASE_EPOCH=9

upstream_version="${UPSTREAM_VERSION:-}"
explicit_version="${PACKAGING_VERSION:-}"

if [[ -n "${explicit_version}" ]]; then
  printf '%s\n' "${explicit_version}"
  exit 0
fi

if [[ -z "${upstream_version}" || "${upstream_version}" == "unknown" ]]; then
  printf 'UPSTREAM_VERSION is required to infer a packaging version (got "%s")\n' \
    "${upstream_version}" >&2
  exit 1
fi

tag_prefix="${upstream_version}-pack."

existing_tags() {
  if [[ -n "${EXISTING_TAGS:-}" ]]; then
    cat "${EXISTING_TAGS}"
    return
  fi
  git -C "${repo_root}" ls-remote --tags origin "refs/tags/${tag_prefix}*" |
    while read -r _ ref; do
      # Annotated tags appear twice, once as the tag and once as "<tag>^{}".
      ref="${ref#refs/tags/}"
      printf '%s\n' "${ref%^\{\}}"
    done
}

# Highest (epoch, minor, patch) among the existing tags, whether they use the
# old single-number form or the new three-number one.
best_key=""
best_epoch=""
best_minor=""
best_patch=""
best_is_legacy=1
while IFS= read -r tag; do
  suffix="${tag#"${tag_prefix}"}"
  [[ "${suffix}" != "${tag}" ]] || continue
  if [[ "${suffix}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    epoch="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[3]}"
    is_legacy=0
  elif [[ "${suffix}" =~ ^([0-9]+)$ ]]; then
    epoch="${BASH_REMATCH[1]}"
    minor=0
    patch=0
    is_legacy=1
  else
    continue
  fi
  # Fixed-width fields so a string comparison orders them numerically.
  key="$(printf '%010d.%010d.%010d' "${epoch}" "${minor}" "${patch}")"
  if [[ -z "${best_key}" || "${key}" > "${best_key}" ]]; then
    best_key="${key}"
    best_epoch="${epoch}"
    best_minor="${minor}"
    best_patch="${patch}"
    best_is_legacy="${is_legacy}"
  fi
done < <(existing_tags)

if [[ -z "${best_key}" ]]; then
  # First package of this upstream version under the new scheme.
  printf '%s%s.0.0\n' "${tag_prefix}" "${BASE_EPOCH}"
elif [[ "${best_is_legacy}" == "1" ]]; then
  # Crossing over from the old counter: start the epoch above it.
  printf '%s%d.0.0\n' "${tag_prefix}" "$((best_epoch + 1))"
else
  # Same upstream version, same packaging feature level: another build.
  printf '%s%s.%s.%d\n' "${tag_prefix}" "${best_epoch}" "${best_minor}" \
    "$((best_patch + 1))"
fi
