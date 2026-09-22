#!/usr/bin/env bash
set -euo pipefail

# Resolves the release tag for a build.
#
# Format: <upstream-version>-pack.<generation>.<minor>.<patch>
#
#   generation  Zero for an upstream version with no releases yet, so a new
#               upstream version always starts at pack.0.0.0 instead of
#               continuing the previous version's numbering. An upstream version
#               that already carries releases under the old bare-counter scheme
#               starts above the highest of those counters (pack.8, the highest
#               published, gives pack.9.0.0); that is what let the new scheme
#               take over without rewriting a single tag.
#   minor       Manual: a packaging change worth distinguishing (a new
#               capability, or a change consumers must react to). Set by passing
#               an explicit PACKAGING_VERSION.
#   patch       Automatic: another build of the same thing. This script only ever
#               bumps the patch.
#
# Generation and minor therefore reset per upstream version, so an automatic
# build can never change which packaging feature level a consumer is offered.
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

# Every existing tag for this upstream version, old counter form included.
# A failure here must be fatal: an empty list is indistinguishable from "no
# releases yet", and resolving to a fresh number would let the release steps
# overwrite an already published release's assets.
existing_tags() {
  local listing
  if [[ -n "${EXISTING_TAGS:-}" ]]; then
    if [[ ! -f "${EXISTING_TAGS}" ]]; then
      printf 'EXISTING_TAGS does not exist: %s\n' "${EXISTING_TAGS}" >&2
      return 1
    fi
    listing="$(cat "${EXISTING_TAGS}")"
  else
    listing="$(git -C "${repo_root}" ls-remote --tags origin "refs/tags/${tag_prefix}*")" || {
      printf 'failed to list %s tags from origin\n' "${tag_prefix}" >&2
      return 1
    }
    # ls-remote prints "<sha> refs/tags/<name>"; keep the names.
    listing="$(printf '%s\n' "${listing}" | awk '{print $2}' | sed 's|^refs/tags/||')"
  fi
  # Annotated tags appear twice, once as the tag and once as "<tag>^{}".
  printf '%s\n' "${listing}" | sed 's/\^{}$//'
}

# Highest (generation, minor, patch) among the existing tags, whether they use
# the old single-number form or the new three-number one.
#
# The listing is captured before it is iterated: inside a process substitution a
# failure of existing_tags would be invisible to `set -e` and a broken query
# would read as "this version has no releases yet".
tag_listing="$(existing_tags)"
best_key=""
best_generation=""
best_minor=""
best_patch=""
best_is_legacy=1
while IFS= read -r tag; do
  suffix="${tag#"${tag_prefix}"}"
  [[ "${suffix}" != "${tag}" ]] || continue
  if [[ "${suffix}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    generation="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[3]}"
    is_legacy=0
  elif [[ "${suffix}" =~ ^([0-9]+)$ ]]; then
    generation="${BASH_REMATCH[1]}"
    minor=0
    patch=0
    is_legacy=1
  else
    continue
  fi
  # Fields are compared as numbers, but a field that cannot be one (absurdly
  # long, or empty after the regexes above) is a tag this script cannot reason
  # about; say so instead of resolving to a version that may already exist.
  for field in "${generation}" "${minor}" "${patch}"; do
    if (( ${#field} > 9 )); then
      printf 'tag %s has a numeric field this script cannot order: %s\n' \
        "${tag}" "${field}" >&2
      exit 1
    fi
  done
  generation=$((10#${generation}))
  minor=$((10#${minor}))
  patch=$((10#${patch}))
  # Fixed-width fields so a string comparison orders them numerically.
  key="$(printf '%010d.%010d.%010d' "${generation}" "${minor}" "${patch}")"
  # A legacy "pack.9" and a new "pack.9.0.0" share a key, but they are not the
  # same version: semver orders "pack.9" below "pack.9.0.0" (fewer fields, all
  # preceding ones equal), so the new form wins the tie and the next build is
  # "pack.9.0.1" rather than a jump the consumer never saw.
  if [[ -z "${best_key}" || "${key}" > "${best_key}" ||
    ( "${key}" == "${best_key}" && "${is_legacy}" == "0" ) ]]; then
    best_key="${key}"
    best_generation="${generation}"
    best_minor="${minor}"
    best_patch="${patch}"
    best_is_legacy="${is_legacy}"
  fi
done <<< "${tag_listing}"

if [[ -z "${best_key}" ]]; then
  # No package for this upstream version yet: its numbering starts at zero.
  printf '%s0.0.0\n' "${tag_prefix}"
elif [[ "${best_is_legacy}" == "1" ]]; then
  # Crossing over from the old counter: start the generation above it, so the
  # new tags order above every tag already published for this version.
  printf '%s%d.0.0\n' "${tag_prefix}" "$((best_generation + 1))"
else
  # Same upstream version, same packaging feature level: another build.
  printf '%s%d.%d.%d\n' "${tag_prefix}" "${best_generation}" "${best_minor}" \
    "$((best_patch + 1))"
fi
