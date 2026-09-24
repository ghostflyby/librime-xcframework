#!/usr/bin/env bash
set -euo pipefail

# Behavioral test for the varpage plugin: compiles varpage_test.cc and runs it
# against a librime that was built with the plugin merged in.
#
# Self-locating on purpose - it lives with the plugin it tests and reads
# everything it needs from this directory, so moving or vendoring the plugin
# moves its test with it.
#
# This is the only test in this repository that drives input sessions, and it
# exists because the build-time gates cannot cover behavior.
# verify_merged_plugins proves rime_require_module_varpage is in the library and
# the module smoke test proves the public header compiles; neither can tell
# whether a page key lands where the host's layout says it should, and a lost
# "paging" tag is silent - it only stops key_binder's `when: paging` bindings
# from firing, which the page keys then never notice.
#
# The input is a cmake build tree of librime, which is what
# scripts/build-one-arch.sh leaves behind and what CI already has: a
# <dir>/lib/librime.dylib plus the data files upstream copies into <dir>/bin.
#
# usage: plugins/varpage/tests/run.sh --build-dir <dir> [--schema <id>] [--input <keys>]

usage() {
  cat <<'EOF'
usage: run.sh --build-dir <dir> [--schema <id>] [--input <keys>]

  --build-dir <dir>  a cmake build tree of librime with varpage merged in:
                     <dir>/lib/librime.dylib and <dir>/bin/*.schema.yaml
  --schema <id>      schema to drive the session with (default luna_pinyin,
                     which the data directory must then contain)
  --input <keys>     key sequence to type (default "nihao", which is input for
                     luna_pinyin). It must be a sequence whose second candidate
                     spans the whole input, because one assertion selects that
                     candidate and expects it to commit the input unchanged;
                     "nihao" does, an arbitrary string may not.

The tree must be built with BUILD_SHARED_LIBS=ON, because the test links the
library rather than the static archive, and with varpage merged
(BUILD_MERGED_PLUGINS=ON with varpage in RIME_PLUGINS).
EOF
}

build_dir=""
schema=""
input=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-dir)
      build_dir="${2:?--build-dir requires a directory}"
      shift 2
      ;;
    --schema)
      schema="${2:?--schema requires an identifier}"
      shift 2
      ;;
    --input)
      input="${2:?--input requires a key sequence}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown argument: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${build_dir}" ]]; then
  usage >&2
  exit 2
fi

# Everything this script reads sits next to it: the test source here, the
# plugin's public header one level up. No repository root is assumed, so the
# directory can be used wherever the plugin is.
test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_dir="$(cd "${test_dir}/.." && pwd)"

lib_dir="${build_dir}/lib"
data_dir="${build_dir}/bin"
if [[ ! -e "${lib_dir}/librime.dylib" ]]; then
  printf 'no librime.dylib in %s; build with BUILD_SHARED_LIBS=ON\n' \
    "${lib_dir}" >&2
  exit 1
fi
if [[ ! -d "${data_dir}" ]]; then
  printf 'no data directory at %s\n' "${data_dir}" >&2
  exit 1
fi

# The data directory has to be the one upstream ships: luna_pinyin is what this
# test drives, and deploy() fails if default.yaml lists a schema the directory
# does not have, so pointing --build-dir at a pruned data set needs a hand-edited
# default.yaml too. Fail loudly rather than picking some other schema, which
# cannot deploy.
if [[ -z "${schema}" ]]; then
  if [[ ! -f "${data_dir}/luna_pinyin.schema.yaml" ]]; then
    printf 'no luna_pinyin.schema.yaml in %s; pass --schema and --input\n' \
      "${data_dir}" >&2
    exit 1
  fi
  schema="luna_pinyin"
fi
if [[ -z "${input}" ]]; then
  if [[ "${schema}" != "luna_pinyin" ]]; then
    printf 'schema %s: pass --input with a key sequence it translates\n' \
      "${schema}" >&2
    exit 1
  fi
  input="nihao"
fi

# Headers: the plugin's own public header, plus the C API headers. A build tree
# that has been installed into carries them in <dir>/include; otherwise they
# come from the upstream source the build was made from, which its CMakeCache
# records.
include_dirs=("-I${plugin_dir}/include")
if [[ -f "${build_dir}/include/rime_api.h" ]]; then
  include_dirs+=("-I${build_dir}/include")
else
  source_dir="$(sed -n 's/^rime_SOURCE_DIR:STATIC=//p' \
    "${build_dir}/CMakeCache.txt" 2>/dev/null || true)"
  if [[ -z "${source_dir}" || ! -d "${source_dir}/src" ]]; then
    printf 'no rime_api.h in %s and no usable rime_SOURCE_DIR in its CMakeCache\n' \
      "${build_dir}/include" >&2
    exit 1
  fi
  include_dirs+=("-I${source_dir}/src" "-I${source_dir}/include")
fi

# The library is linked by an rpath that has to be absolute: dyld resolves a
# relative LC_RPATH against the working directory, not the executable's, so a
# relative --build-dir would break the moment anything changed directory.
lib_dir="$(cd "${lib_dir}" && pwd)"

work_dir="$(mktemp -d)"
user_dir="${work_dir}-user"
# Not `exec`: replacing the shell would skip this trap, leaving the compiled
# binary and the deployed user data behind on every run.
trap 'rm -rf "${work_dir}" "${user_dir}"' EXIT

printf 'building the test against %s\n' "${lib_dir}/librime.dylib"
c++ -std=c++17 -O1 -Wall -Wextra \
  -o "${work_dir}/varpage_test" \
  "${test_dir}/varpage_test.cc" \
  "${include_dirs[@]}" \
  -L"${lib_dir}" -lrime -Wl,-rpath,"${lib_dir}"

mkdir -p "${user_dir}"
printf 'schema %s, input %s\n' "${schema}" "${input}"
"${work_dir}/varpage_test" "${data_dir}" "${user_dir}" "${schema}" "${input}"
