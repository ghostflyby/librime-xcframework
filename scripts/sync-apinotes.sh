#!/usr/bin/env bash
set -euo pipefail

# Collects the declarations the public headers flavor (RIME_FLAVORED) and renders
# the API notes that strip the flavor suffix from the Swift-facing names.
#
# Why the collection is programmatic: the Clang importer ignores an annotation it
# cannot apply, so a flavored declaration that no entry covers keeps its suffixed
# name visible to Swift consumers without any diagnostic. The struct tags behind
# the flavored typedefs are what hand-written notes missed; collecting from
# clang's AST leaves nothing to notice by hand. A declaration kind this script
# does not know how to annotate is an error rather than a skip, for the same
# reason.
#
# Nothing here assumes the suffix is spelled `_stdbool`: it is read back from the
# preprocessor through RIME_FLAVORED itself, so a change to the flavoring scheme
# is collected the same way.
#
# Usage:
#   sync-apinotes.sh [--headers <include-dir>]
#       Write Sources/RimeHeaders/include/Rime.apinotes and the RimeSystem copy.
#   sync-apinotes.sh --print [--headers <include-dir>]
#       Print the notes for thos headers to stdout, for the build to install
#       next to the headers it exports.
#   sync-apinotes.sh --check [--headers <include-dir>]
#       Fail if <include-dir>/Rime.apinotes is not what those headers generate.
#   sync-apinotes.sh --print-probe plain|names [--headers <include-dir>]
#       Print for scripts/verify-swift-names.sh: the un-suffixed names that must
#       resolve as Swift, or the C names the notes claim to rename, which must
#       not be visible in the module's Swift interface.
#   sync-apinotes.sh --print-flavor-suffix [--headers <include-dir>]
#       Print the suffix the headers append to flavored names.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

headers_dir="${repo_root}/Sources/RimeHeaders/include"
mode="write"

usage() {
  printf 'usage: %s [write | --print | --check | --print-probe plain|names | --print-flavor-suffix] [--headers <include-dir>]\n' "$0" >&2
}

set_mode() {
  if [[ "${mode}" != "write" ]]; then
    printf 'conflicting arguments: %s cannot be combined with %s\n' "$1" "${mode}" >&2
    exit 2
  fi
  mode="$1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --print)
      set_mode print
      ;;
    --check)
      set_mode check
      ;;
    --print-probe)
      shift
      if [[ $# -eq 0 ]]; then
        printf '%s requires plain or names\n' "--print-probe" >&2
        exit 2
      fi
      case "$1" in
        plain | names) set_mode "probe-$1" ;;
        *)
          printf 'unknown probe kind: %s\n' "$1" >&2
          exit 2
          ;;
      esac
      ;;
    --print-flavor-suffix)
      set_mode suffix
      ;;
    --headers)
      shift
      if [[ $# -eq 0 ]]; then
        printf '%s requires a directory\n' "--headers" >&2
        exit 2
      fi
      headers_dir="$1"
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
  shift
done

if [[ ! -f "${headers_dir}/RimeShim.h" ]]; then
  printf 'no RimeShim.h in the include directory: %s\n' "${headers_dir}" >&2
  exit 1
fi

# One program, invoked per mode: it owns the collection and the rendering, the
# shell owns the file plumbing below.
helper="$(mktemp)"
generated=""
cleanup() {
  rm -f "${helper}"
  if [[ -n "${generated}" ]]; then
    rm -f "${generated}"
  fi
}
trap cleanup EXIT
cat > "${helper}" <<'PY'
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

mode = sys.argv[1]
headers_dir = Path(sys.argv[2])


def fail(message):
    print(f"sync-apinotes: {message}", file=sys.stderr)
    raise SystemExit(1)


def clang(arguments, source):
    """Run clang over a translation unit that includes the module shim."""
    with tempfile.TemporaryDirectory() as scratch:
        tu = Path(scratch) / "probe.c"
        tu.write_text(source)
        result = subprocess.run(
            ["xcrun", "clang", *arguments, "-I", str(headers_dir), str(tu)],
            capture_output=True,
            text=True,
        )
    if result.returncode != 0:
        fail(f"clang could not process the headers in {headers_dir}:"
             f"\n{result.stderr.strip()}")
    return result.stdout


# Read the suffix off the preprocessor instead of assuming `_stdbool`: the
# flavoring macro token-pastes it onto whatever name it is given.
expanded = clang(["-E", "-P"],
                 '#include "RimeShim.h"\nRIME_FLAVORED(__rime_flavor_probe__)\n')
match = re.search(r"__rime_flavor_probe__([A-Za-z0-9_]*)", expanded)
if match is None or not match.group(1):
    fail("the headers no longer flavor names through RIME_FLAVORED")
suffix = match.group(1)

ast = json.loads(clang(["-Xclang", "-ast-dump=json", "-fsyntax-only"],
                       '#include "RimeShim.h"\n'))


def walk(node):
    if isinstance(node, dict):
        yield node
        for value in node.values():
            yield from walk(value)
    elif isinstance(node, list):
        for value in node:
            yield from walk(value)


def flavored(node):
    name = node.get("name")
    if isinstance(name, str) and len(name) > len(suffix) and name.endswith(suffix):
        return name
    return None


def strip(name):
    return name[: -len(suffix)]


typedef_names = set()
record_names = set()
function_names = set()
unhandled = set()

for node in walk(ast):
    name = flavored(node)
    if name is None:
        continue
    kind = node.get("kind")
    if kind == "TypedefDecl":
        typedef_names.add(name)
    elif kind in ("RecordDecl", "EnumDecl"):
        record_names.add(name)
    elif kind == "FunctionDecl":
        function_names.add(name)
    else:
        unhandled.add(f"{kind} {name}")

if unhandled:
    fail("no rule for these flavored declarations, decide their Swift names and"
         " extend this script:\n  " + "\n  ".join(sorted(unhandled)))

# Every flavored name loses the suffix from its own spelling, and nothing else
# changes. Swift imports `typedef struct foo_t {…} Foo` as `struct foo_t` plus
# `typealias Foo = foo_t`, so a tag and its typedef are two spellings of one type
# and stay two here as well. Renaming the tag to the typedef's name would delete
# `rime_api_t` from the Swift surface - a name upstream's own headers expose -
# which is not this file's business.
#
# Keyed by (section, C name) because one name can need an entry in two sections.
# A tag and its typedef are distinct C names, so both spellings exist only when
# the headers spell them differently; clang names an anonymous record after its
# typedef, and that typedef is then the single entry.
entries = {}
for name in sorted(record_names):
    entries[("Tags", name)] = strip(name)
for name in sorted(function_names):
    entries[("Functions", name)] = strip(name)
for name in sorted(typedef_names):
    entries[("Typedefs", name)] = strip(name)

if not entries:
    fail(f"found no flavored declarations in {headers_dir}; is RIME_FLAVORED still used?")

identifier = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
# An assertion rather than a live check: removing one fixed suffix from distinct
# names yields distinct names, so with the rule above this cannot fire today. It
# exists because the importer resolves a duplicate Swift name by silently keeping
# one entry, so a later change to how names are derived (camel-casing, folding,
# truncation) must fail here instead of quietly collapsing two types into one.
swift_names_seen = {}
for name, swift_name in {(n, s) for (_, n), s in entries.items()}:
    # The notes are a text file the importer parses without diagnostics, so a
    # rendered name that is not an identifier would be ignored in silence.
    if not identifier.match(swift_name):
        fail(f"{name} would be renamed to {swift_name!r}, which is not an identifier")
    previous = swift_names_seen.setdefault(swift_name, name)
    if previous != name:
        fail(f"{name} and {previous} would both be renamed to"
             f" {swift_name}; disambiguate them in the headers")

header_text = f"""\
# Copyright (c) 2026, librime-xcframework contributors
# Distributed under the BSD 3-Clause License; see LICENSE.
#
# Swift-side names for the Rime module.
#
# Generated by scripts/sync-apinotes.sh from the declarations the public headers
# flavor; edit that script, not this file. Re-run it after touching a flavored
# declaration and keep the RimeSystem copy identical.
#
# The public headers are compiled in their stdbool flavor, so every flavored
# entity carries a `{suffix}` suffix in C and the function entry point is
# `rime_get_api{suffix}`. That suffix is an implementation detail of how the
# library deduplicates its two API flavors; Swift consumers should not see it.
#
# Every flavored declaration keeps its own name with the suffix removed, so the
# Swift surface stays the one the C headers describe: `struct rime_api_t` plus
# `typealias RimeApi = rime_api_t`, not the suffixed spellings.
#
# These notes are applied by the Clang importer and change nothing on the C or
# binary side: the emitted calls still reference the suffixed names and the
# structs keep their suffixed tags. Renaming here rather than with
# `__attribute__((swift_name))` in the headers keeps this file free of
# annotations that the release pipeline's header sync would overwrite.
#
# Two things fail silently and are therefore covered by
# scripts/verify-swift-names.sh:
#   - a Function entry needs the parentheses in SwiftName ('name()'); without
#     them the rename is ignored with no diagnostic;
#   - this file must be named after the module (Rime) and sit next to the
#     module map.
"""


def render():
    # `Name` must match the module, like the filename does.
    lines = [header_text, "Name: Rime", ""]
    for section in ("Typedefs", "Tags", "Functions"):
        names = sorted(n for (s, n) in entries if s == section)
        if not names:
            continue
        lines.append(f"{section}:")
        for name in names:
            swift_name = entries[(section, name)]
            if section == "Functions":
                swift_name = f"'{swift_name}()'"
            lines.append(f"- Name: {name}")
            lines.append(f"  SwiftName: {swift_name}")
    return "\n".join(lines) + "\n"


if mode == "emit":
    counts = {s: sum(1 for (section, _) in entries if section == s)
              for s in ("Typedefs", "Tags", "Functions")}
    print(f"sync-apinotes: {len(entries)} flavored declarations in {headers_dir} "
          f"({counts['Typedefs']} typedefs, {counts['Tags']} tags, "
          f"{counts['Functions']} functions)", file=sys.stderr)
    sys.stdout.write(render())
elif mode == "suffix":
    print(suffix)
elif mode == "probe-plain":
    # One statement per Swift name the notes promise; a tag and its typedef
    # collapse into one line because they map to the same name.
    seen = []
    for (_, name), swift_name in sorted(entries.items()):
        if swift_name not in seen:
            seen.append(swift_name)
    for swift_name in seen:
        print(f"_ = {swift_name}.self")
elif mode == "probe-names":
    # Every C name the notes claim to rename, once each. A name in this list that
    # is still visible in the Swift interface was not renamed, which is the check
    # that also covers a name carrying no suffix (`struct rime_api_t`), where a
    # suffix scan cannot see the leak.
    for name in sorted({name for _, name in entries}):
        print(name)
else:
    fail(f"unknown mode: {mode}")
PY

if [[ "${mode}" == "write" || "${mode}" == "check" ]]; then
  generated="$(mktemp)"
  python3 "${helper}" emit "${headers_dir}" > "${generated}"
fi

case "${mode}" in
  print)
    python3 "${helper}" emit "${headers_dir}"
    ;;
  write)
    for destination in \
      "${repo_root}/Sources/RimeHeaders/include/Rime.apinotes" \
      "${repo_root}/Sources/RimeSystem/Rime.apinotes"; do
      if cmp -s "${generated}" "${destination}"; then
        printf 'unchanged: %s\n' "${destination}"
      else
        cp "${generated}" "${destination}"
        printf 'updated: %s\n' "${destination}"
      fi
    done
    ;;
  check)
    # The notes travel with the headers they annotate, so a stale copy next to a
    # built include directory would hand Swift the suffixed names back.
    target="${headers_dir}/Rime.apinotes"
    if [[ ! -f "${target}" ]]; then
      printf 'missing API notes: %s\n' "${target}" >&2
      printf 'Swift consumers would see the suffixed names again\n' >&2
      exit 1
    fi
    if ! cmp -s "${generated}" "${target}"; then
      printf '%s does not match the headers next to it; run scripts/sync-apinotes.sh:\n' "${target}" >&2
      diff -u "${target}" "${generated}" | sed 's/^/  /' >&2 || true
      exit 1
    fi
    printf 'API notes are up to date with the headers: %s\n' "${headers_dir}"
    ;;
  suffix | probe-plain | probe-names)
    python3 "${helper}" "${mode}" "${headers_dir}"
    ;;
esac
