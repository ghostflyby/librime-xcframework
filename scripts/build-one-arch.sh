#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'usage: %s <macos-arm64|macos-x86_64|ios-arm64|ios-simulator-arm64|ios-simulator-x86_64>\n' "$0" >&2
  exit 2
fi

slice="$1"
case "${slice}" in
  arm64|macos-arm64)
    arch="arm64"
    platform="macos-arm64"
    triplet="arm64-osx-static-release"
    deployment_target="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
    cmake_system_name=""
    osx_sysroot=""
    build_dynamic=1
    ;;
  x86_64|macos-x86_64)
    arch="x86_64"
    platform="macos-x86_64"
    triplet="x64-osx-static-release"
    deployment_target="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
    cmake_system_name=""
    osx_sysroot=""
    build_dynamic=1
    ;;
  ios-arm64)
    arch="arm64"
    platform="ios-arm64"
    triplet="arm64-ios-static-release"
    deployment_target="${IOS_DEPLOYMENT_TARGET:-15.0}"
    cmake_system_name="iOS"
    osx_sysroot="iphoneos"
    build_dynamic=1
    ;;
  ios-simulator-arm64)
    arch="arm64"
    platform="ios-simulator-arm64"
    triplet="arm64-ios-simulator-static-release"
    deployment_target="${IOS_DEPLOYMENT_TARGET:-15.0}"
    cmake_system_name="iOS"
    osx_sysroot="iphonesimulator"
    build_dynamic=1
    ;;
  ios-simulator-x86_64)
    arch="x86_64"
    platform="ios-simulator-x86_64"
    triplet="x64-ios-simulator-static-release"
    deployment_target="${IOS_DEPLOYMENT_TARGET:-15.0}"
    cmake_system_name="iOS"
    osx_sysroot="iphonesimulator"
    build_dynamic=1
    ;;
  *)
    printf 'unsupported slice: %s\n' "${slice}" >&2
    exit 2
    ;;
esac

# Test mode. Validated here, before anything is deleted or exported: a refused
# run must not first destroy the slice's previous output, and `BUILD_TESTS` must
# not be accepted loosely - values like "true" would take the artifact path, run
# no tests, and still exit 0, which is the one failure this mode cannot afford.
# Unset means artifact mode; set to anything other than 0 or 1 is an error, empty
# included, because an empty value is a mistake rather than a request to skip.
build_tests="${BUILD_TESTS-0}"
if [[ -z "${build_tests}" ]]; then
  printf 'BUILD_TESTS is set but empty; set it to 1 to run the tests, or unset it\n' >&2
  exit 2
fi
case "${build_tests}" in
  0 | 1) ;;
  *)
    printf 'BUILD_TESTS must be 0 or 1, got: %s\n' "${build_tests}" >&2
    exit 2
    ;;
esac
if [[ "${build_tests}" -eq 1 ]]; then
  case "${slice}" in
    macos-* | arm64 | x86_64) ;;
    *)
      printf 'BUILD_TESTS needs a macOS slice: the test binary has to run on this host, and %s builds for %s\n' \
        "${platform}" "${cmake_system_name:-macOS}" >&2
      exit 2
      ;;
  esac
  if [[ "${arch}" != "$(uname -m)" ]]; then
    printf 'BUILD_TESTS builds for %s but this host is %s; the test binary would not run\n' \
      "${arch}" "$(uname -m)" >&2
    exit 2
  fi
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
work_dir="${WORK_DIR:-${repo_root}/.build}"
build_dir="${work_dir}/build-${platform}"
static_build_dir="${build_dir}-static"
dynamic_build_dir="${build_dir}-dynamic"
test_build_dir="${build_dir}-test"
source_work_dir="${work_dir}/src-${platform}"
install_dir="${OUT_DIR:-${repo_root}/out}/${platform}"
static_install_dir="${install_dir}/static"
dynamic_install_dir="${install_dir}/dynamic"
configuration="${CONFIGURATION:-Release}"
export VCPKG_OSX_DEPLOYMENT_TARGET="${VCPKG_OSX_DEPLOYMENT_TARGET:-${deployment_target}}"

# Work directories are reused rather than recreated.
#
# Wiping them unconditionally was pure cost: a CI runner starts from an empty
# workspace, so there was never anything to delete there, while locally it threw
# away the compiler's work on every run - the difference between seconds and a
# full rebuild for a one-file change. The build system already notices an edited
# source file, so the only thing reuse needs is a guard on what a directory was
# *created* for. Each directory records that, and is discarded when the guard no
# longer matches, which is the case the wipe was really there for: a different
# upstream ref, a different triplet, a different set of configure arguments.
#
# CLEAN=1 discards everything first, for when a build has gone strange in a way
# the guards cannot see.
clean="${CLEAN:-0}"
stamp_dir="${work_dir}/stamps"
mkdir -p "${stamp_dir}"

# Whether the directory behind `stamp` was made for something other than `guard`.
stale() {
  local stamp="$1" guard="$2"

  [[ "${clean}" -eq 1 ]] && return 0
  [[ -f "${stamp}" ]] || return 0
  [[ "$(cat "${stamp}")" != "${guard}" ]]
}

# Records that the directory is now in the state `guard` describes. Called after
# the step that fills it, so an interrupted run leaves the guard absent and the
# next run starts that directory over rather than trusting it.
mark_fresh() {
  printf '%s\n' "$2" > "$1"
}

source_dir="${UPSTREAM_SOURCE_DIR:-}"
if [[ -z "${source_dir}" ]]; then
  if [[ -d "${repo_root}/vendor/librime" ]]; then
    source_dir="${repo_root}/vendor/librime"
  elif [[ -d "${repo_root}/../librime" ]]; then
    source_dir="${repo_root}/../librime"
  else
    printf 'could not find upstream source. Set UPSTREAM_SOURCE_DIR or checkout vendor/librime.\n' >&2
    exit 1
  fi
fi

# Source selection. With no UPSTREAM_REF the working tree is built, so an
# in-progress edit under a development checkout is what gets compiled; with an
# explicit UPSTREAM_REF that ref's committed content is built, and an
# unresolvable ref is an error rather than a silent fallback to the checkout.
upstream_ref="${UPSTREAM_REF:-}"
if [[ -z "${upstream_ref}" ]]; then
  build_from_worktree=1
  upstream_ref="worktree"
elif [[ -d "${source_dir}/.git" ]] && git -C "${source_dir}" rev-parse "${upstream_ref}^{commit}" >/dev/null 2>&1; then
  build_from_worktree=0
else
  printf 'cannot resolve UPSTREAM_REF=%s in %s\n' "${upstream_ref}" "${source_dir}" >&2
  exit 1
fi
# resolve-version.sh records what was built, so it needs the same answer.
export UPSTREAM_REF="${upstream_ref}"

vcpkg_root="${VCPKG_ROOT:-}"
if [[ -z "${vcpkg_root}" ]]; then
  printf 'VCPKG_ROOT is required: point it at a vcpkg checkout.\n' >&2
  exit 1
fi

if [[ ! -f "${vcpkg_root}/scripts/buildsystems/vcpkg.cmake" ]]; then
  printf 'vcpkg toolchain file was not found under VCPKG_ROOT: %s\n' "${vcpkg_root}" >&2
  exit 1
fi

# The toolchain is provided by the CI environment and assumed locally, so name
# what is missing instead of letting cmake fail with its own wording.
for tool in cmake ninja; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    printf 'required tool not found in PATH: %s\n' "${tool}" >&2
    exit 1
  fi
done

# The source tree is filled by the export or copy below, so it can be kept as it
# is unless what it holds would no longer be produced: the ref it was exported
# from, or the patches applied on top of it. Both fillers keep the rest in step -
# `rsync --delete` for a working tree, `git archive | tar -x` for an export, and
# `prepare-plugins.sh` rsyncs the plugin directories every run - so the ref, the
# patches and the plugins are the whole of what a tree depends on.
#
# The patches have to be in the guard, not just the ref: `apply_patches` runs
# against whatever tree it finds, and an already-patched tree makes an edited
# patch neither apply nor reverse-apply, so a changed patch would be silently
# ignored rather than applied.
source_guard="ref=${upstream_ref}"
while IFS= read -r -d '' patch_file; do
  source_guard+=" patch:$(cksum < "${patch_file}")"
done < <(find "${repo_root}/patches" -name '*.patch' -print0 | sort -z)
if stale "${stamp_dir}/source-${platform}" "${source_guard}"; then
  rm -rf "${source_work_dir}"
fi
mkdir -p "${source_work_dir}"

# Test mode neither writes nor clears out/<platform>: it produces no artifacts,
# and a run that removed a slice built earlier would be a surprise for anyone
# running the two modes back to back. Artifact mode checks the same guard further
# down, once the configure arguments it depends on exist.
if [[ "${build_tests}" -eq 0 ]]; then
  mkdir -p "${static_install_dir}" "${dynamic_install_dir}"
fi

if [[ "${build_from_worktree}" -eq 0 ]]; then
  printf 'exporting %s from %s\n' "${upstream_ref}" "${source_dir}"
  git -C "${source_dir}" archive "${upstream_ref}" | tar -x -C "${source_work_dir}"
else
  printf 'copying working tree from %s\n' "${source_dir}"
  rsync -a --delete --exclude .git "${source_dir}/" "${source_work_dir}/"
fi

"${script_dir}/apply-patches.sh" "${source_work_dir}"

# Assigned separately from the export: a `export VAR="$(cmd)"` reports the
# export's own status, which would hide a failing prepare-plugins.sh - the step
# that copies the plugins in and verifies their licenses.
RIME_PLUGINS="$("${script_dir}/prepare-plugins.sh" "${source_work_dir}")"
export RIME_PLUGINS

# read -a rather than an unquoted expansion: the module list is space separated,
# and bash 3.2 (the macOS default) has no mapfile.
read -r -a plugin_modules <<< "${RIME_PLUGINS}"
if [[ ${#plugin_modules[@]} -eq 0 ]]; then
  printf 'no plugins were prepared; the artifacts are expected to merge the plugins from plugins.json\n' >&2
  exit 1
fi
printf 'merging plugin modules: %s\n' "${plugin_modules[*]}"

if [[ ! -f "${source_work_dir}/CMakeLists.txt" ]]; then
  printf 'selected source ref does not contain CMakeLists.txt: %s\n' "${source_work_dir}" >&2
  exit 1
fi
# The tree has been filled, patched and given its plugins, so it now matches the
# guard written above and the next run may keep it.
mark_fresh "${stamp_dir}/source-${platform}" "${source_guard}"

configure_common=(
  -S "${source_work_dir}"
  -G Ninja
  -DCMAKE_BUILD_TYPE="${configuration}"
  -DCMAKE_OSX_ARCHITECTURES="${arch}"
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${deployment_target}"
  -DCMAKE_INSTALL_NAME_DIR="@rpath"
  -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-headerpad_max_install_names"
  -DCMAKE_TOOLCHAIN_FILE="${vcpkg_root}/scripts/buildsystems/vcpkg.cmake"
  -DVCPKG_TARGET_TRIPLET="${triplet}"
  -DVCPKG_OVERLAY_TRIPLETS="${repo_root}/triplets"
  -DVCPKG_OVERLAY_PORTS="${repo_root}/ports"
  -DVCPKG_MANIFEST_DIR="${repo_root}"
  -DVCPKG_INSTALL_OPTIONS=--allow-unsupported
  -DBUILD_STATIC=ON
  -DWITH_STATIC_DEPS=ON
  -DBUILD_MERGED_PLUGINS=ON
  -DBUILD_SEPARATE_LIBS=OFF
  -DBUILD_TOOLS=OFF
  -DBUILD_SAMPLE=OFF
  -DENABLE_EXTERNAL_PLUGINS=OFF
)

# Upstream's test suite is a separate mode rather than a flag on the artifact
# build, for two reasons: it needs gtest, which comes from the manifest's
# "tests" feature precisely so artifact builds never install a test framework;
# and it needs BUILD_SHARED_LIBS, which upstream requires before it will add its
# test directory at all. Reusing this script is what makes the suite run against
# the same upstream ref, patches and merged plugins as the artifacts - the point
# of running it is to catch the packaging layer breaking librime itself, which a
# separately configured build could not show. The mode, and the guards that keep
# it to a runnable host, were validated at the top of this script.
if [[ "${build_tests}" -eq 1 ]]; then
  configure_common+=(-DBUILD_TEST=ON -DBUILD_TESTING=ON)
  configure_common+=(-DVCPKG_MANIFEST_FEATURES=tests)
else
  configure_common+=(-DBUILD_TEST=OFF -DBUILD_TESTING=OFF)
fi
if [[ -n "${cmake_system_name}" ]]; then
  configure_common+=(-DCMAKE_SYSTEM_NAME="${cmake_system_name}")
fi

if [[ -n "${osx_sysroot}" ]]; then
  configure_common+=(-DCMAKE_OSX_SYSROOT="${osx_sysroot}")
fi

# Identifies what a build directory's CMake cache depends on. The configure
# arguments are the whole of it: they carry the source path, the arch and
# deployment target, the triplet, the toolchain and the feature flags. A change to
# any of them means the cache describes a configuration that is no longer being
# asked for, so the directory is configured from scratch rather than reused.
configure_guard() {
  printf '%s\n' "${configure_common[@]}" "$@" | cksum
}

configure_and_install() {
  local output_dir="$1"
  local prefix="$2"
  local shared_libs="$3"

  local guard
  guard="$(configure_guard "${prefix}" "-DBUILD_SHARED_LIBS=${shared_libs}")"
  local stamp
  stamp="${stamp_dir}/$(basename "${output_dir}")"
  if stale "${stamp}" "${guard}"; then
    rm -rf "${output_dir}"
  fi
  mkdir -p "${output_dir}"

  cmake "${configure_common[@]}" \
    -B "${output_dir}" \
    -DCMAKE_INSTALL_PREFIX="${prefix}" \
    -DBUILD_SHARED_LIBS="${shared_libs}"
  mark_fresh "${stamp}" "${guard}"

  cmake --build "${output_dir}" --config "${configuration}" --target install
}

# Builds and runs the two suites against one tree: upstream's own tests, and the
# behavioral tests that each plugin keeps in its own tests/ directory and that
# drive real input sessions. Both are registered with ctest - upstream's by its
# own test/CMakeLists.txt, the plugins' by their CMakeLists - so one ctest run
# covers them and reports them together. They run against the source this script
# prepared: the same ref, patches and merged plugins the artifacts would come
# from, which is the whole point, since a suite run against an unpatched checkout
# could not report anything about this repository.
run_tests() {
  local guard
  guard="$(configure_guard "-DCMAKE_INSTALL_PREFIX=${test_build_dir}/install" \
    "-DBUILD_SHARED_LIBS=ON")"
  local stamp
  stamp="${stamp_dir}/$(basename "${test_build_dir}")"
  if stale "${stamp}" "${guard}"; then
    rm -rf "${test_build_dir}"
  fi
  mkdir -p "${test_build_dir}"

  cmake "${configure_common[@]}" \
    -B "${test_build_dir}" \
    -DCMAKE_INSTALL_PREFIX="${test_build_dir}/install" \
    -DBUILD_SHARED_LIBS=ON
  mark_fresh "${stamp}" "${guard}"

  cmake --build "${test_build_dir}" --config "${configuration}" \
    --target rime_test

  # A plugin's test registration is conditional (it needs a test build and a
  # shared library), and a registration that silently did not happen would leave
  # ctest reporting a clean run of upstream's suite alone. Check it is there
  # before trusting that run.
  #
  # Captured into a variable rather than piped into `grep -q`: grep exits on the
  # first match, and under `pipefail` the resulting SIGPIPE on ctest would fail
  # the check and report a registered test as missing. This is the same trap
  # verify_merged_plugins documents.
  printf 'checking the plugin tests registered\n'
  registered="$(cd "${test_build_dir}" && ctest -N)"
  if [[ "${registered}" != *varpage_behavioral* ]]; then
    printf 'the varpage behavioral test is not registered with ctest; it needs BUILD_TEST and BUILD_SHARED_LIBS\n' >&2
    printf '%s\n' "${registered}" >&2
    exit 1
  fi

  printf 'running the test suites\n'
  # --no-tests=error because a suite that registers nothing still exits 0 by
  # default, and this job's exit status is its only signal.
  (
    cd "${test_build_dir}"
    ctest --output-on-failure --no-tests=error
  )
}

prune_exported_headers() {
  local include_dir="$1"

  rm -f "${include_dir}/rime_api_deprecated.h"
}

# Copy the shim this repository owns into the exported include directory, so it
# travels with the build output. The release pipeline syncs that directory into
# Sources/RimeHeaders/include/, and because that sync deletes files absent from
# the source it would otherwise remove the shim from the package. The API notes
# are not copied here: install_wrapper_apinotes renders them from these headers.
install_wrapper_headers() {
  local include_dir="$1"

  cp "${repo_root}/Sources/RimeHeaders/include/RimeShim.h" \
    "${include_dir}/RimeShim.h"
}

# Render the API notes from the headers actually being exported, rather than
# copying the committed file: the notes annotate exactly what sits next to them,
# so a flavored declaration upstream adds is covered in the artifacts even before
# the committed copy is refreshed, and a published slice cannot carry notes that
# disagree with its own headers.
#
# Must run after prune_exported_headers and install_plugin_headers: the notes
# describe the final export set, and a header that is pruned or not yet installed
# must not contribute an entry for a declaration the slice does not ship.
install_wrapper_apinotes() {
  local include_dir="$1"

  "${repo_root}/scripts/sync-apinotes.sh" --print --headers "${include_dir}" \
    > "${include_dir}/Rime.apinotes"
}

# Public headers of the plugins carried in this repository. They live outside
# upstream's src/ tree, which is what its install rule globs, so copy them into
# the exported include directory, where the release pipeline picks them up for
# Sources/RimeHeaders.
#
# Driven by the manifest rather than by globbing plugins/: a directory that is
# not in the manifest must not publish headers, and an accidental basename
# collision (including with a librime header) must fail loudly instead of
# silently overwriting.
install_plugin_headers() {
  local include_dir="$1"
  local header header_name destination

  # The collision this guards against is a name clash, and both ways it can happen
  # are decidable from the sources: a plugin header named like one librime installs
  # (which would shadow a public header), or two plugins shipping the same name
  # (the second would silently replace the first).
  #
  # Checked against the sources rather than against what is already in the export
  # directory, because the destination test - "the file exists" - fails the build
  # on any leftover copy, and a reused out/ directory always has those.
  local upstream_names plugin_seen=() name
  upstream_names="$(cd "${source_work_dir}/src" && find . -maxdepth 1 -name '*.h' \
    -print | sed -n 's|^\./||p' | grep -v '_impl\.h$' || true)"

  while IFS= read -r -d '' header; do
    header_name="$(basename "${header}")"
    if grep -qxF "${header_name}" <<< "${upstream_names}"; then
      printf 'plugin header %s would shadow a librime public header of the same name\n' \
        "${header}" >&2
      exit 1
    fi
    for name in ${plugin_seen[@]+"${plugin_seen[@]}"}; do
      if [[ "${name}" == "${header_name}" ]]; then
        printf 'plugin header %s duplicates a header another plugin already exported\n' \
          "${header}" >&2
        exit 1
      fi
    done
    plugin_seen+=("${header_name}")

    destination="${include_dir}/${header_name}"
    cp "${header}" "${destination}"
  done < <(plugin_public_headers)
}

# Prints the public headers of the manifest's local plugins, NUL-delimited.
plugin_public_headers() {
  local manifest_path="${PLUGINS_MANIFEST:-${repo_root}/plugins.json}"

  [[ -f "${manifest_path}" ]] || return 0

  python3 - "${manifest_path}" "${repo_root}" <<'PY'
import json, os, sys
manifest, repo_root = sys.argv[1], sys.argv[2]
for plugin in json.load(open(manifest))["plugins"]:
    if not plugin.get("local"):
        continue
    include_dir = os.path.join(repo_root, plugin["path"], "include")
    if not os.path.isdir(include_dir):
        continue
    for name in sorted(os.listdir(include_dir)):
        if name.endswith(".h"):
            sys.stdout.write(os.path.join(include_dir, name) + "\0")
PY
}

collect_vcpkg_notices() {
  local notices_dir="$1"
  local share_dir copyright_file port_name destination

  # Cleared rather than reused, unlike the build and install directories: this
  # collection is the set of ports currently installed, and the guard on the
  # install directory keys on the configure arguments rather than on vcpkg.json's
  # contents. A dependency removed from the manifest would therefore leave its
  # notice behind, and the bundle would claim a library the artifacts do not
  # contain. Copying these files again costs nothing.
  rm -rf "${notices_dir}"
  mkdir -p "${notices_dir}/vcpkg" "${notices_dir}/librime"

  for share_dir in "${static_build_dir}/vcpkg_installed/${triplet}/share" "${vcpkg_root}/installed/${triplet}/share"; do
    if [[ ! -d "${share_dir}" ]]; then
      continue
    fi

    while IFS= read -r -d '' copyright_file; do
      port_name="$(basename "$(dirname "${copyright_file}")")"
      destination="${notices_dir}/vcpkg/${port_name}.txt"
      if [[ ! -f "${destination}" ]]; then
        cp "${copyright_file}" "${destination}"
      fi
    done < <(find "${share_dir}" -mindepth 2 -maxdepth 2 -type f -name copyright -print0)
  done

  collect_librime_bundled_notices "${notices_dir}/librime"
}

# Upstream librime compiles in two header-only libraries whose licenses are not
# installed by upstream's CMake rules and are not vcpkg ports. Collect them from
# the upstream source tree here, where it exists, so they travel with the slice
# artifacts the same way the vcpkg notices do.
collect_librime_bundled_notices() {
  local destination_dir="$1"

  if [[ -f "${source_work_dir}/include/COPYING.darts-clone" ]]; then
    cp "${source_work_dir}/include/COPYING.darts-clone" "${destination_dir}/darts-clone.txt"
  else
    printf 'warning: darts-clone license text not found for the notices bundle\n' >&2
  fi

  if [[ -f "${source_work_dir}/include/utf8.h" ]]; then
    sed -n '1,/^ \*\/$/p' "${source_work_dir}/include/utf8.h" \
      | sed '1d;$d' > "${destination_dir}/utf8-cpp.txt"
  else
    printf 'warning: utf8-cpp license text not found for the notices bundle\n' >&2
  fi
}

# Test mode stops here: it exists to validate the packaging layer against
# librime, not to produce artifacts, and building the static and dynamic slices
# as well would only make a failing test slower to report.
if [[ "${build_tests}" -eq 1 ]]; then
  run_tests
  printf 'tests passed for %s (source: %s)\n' "${platform}" "${upstream_ref}"
  exit 0
fi

# out/<platform> is reused for the same reason the build trees are: the install
# step rewrites what it installs, so clearing first only repeats work. What reuse
# cannot see is an install *rule* that disappeared, which would leave its file
# behind - a build-script change rather than a source one, and what CLEAN=1 is
# for.
install_guard="$(configure_guard "${platform}" "static+dynamic")"
if stale "${stamp_dir}/install-${platform}" "${install_guard}"; then
  rm -rf "${install_dir}"
fi
mkdir -p "${static_install_dir}" "${dynamic_install_dir}"
mark_fresh "${stamp_dir}/install-${platform}" "${install_guard}"

configure_and_install "${static_build_dir}" "${static_install_dir}" OFF

static_archive="${static_install_dir}/lib/librime.a"
if [[ ! -f "${static_archive}" ]]; then
  printf 'expected librime archive was not produced: %s\n' "${static_archive}" >&2
  exit 1
fi

dep_archives=()
for vcpkg_lib_dir in "${static_build_dir}/vcpkg_installed/${triplet}/lib" "${vcpkg_root}/installed/${triplet}/lib"; do
  if [[ -d "${vcpkg_lib_dir}" ]]; then
    while IFS= read -r -d '' archive; do
      dep_archives+=("${archive}")
    done < <(find "${vcpkg_lib_dir}" -maxdepth 1 -name '*.a' -print0)
  fi
done

if [[ ${#dep_archives[@]} -gt 0 ]]; then
  merged_archive="${static_install_dir}/lib/librime-merged.a"
  printf 'merging %d dependency archives into %s\n' "${#dep_archives[@]}" "${static_archive}"
  libtool -static -o "${merged_archive}" "${static_archive}" "${dep_archives[@]}"
  mv "${merged_archive}" "${static_archive}"
else
  printf 'warning: no vcpkg dependency archives found to merge\n' >&2
fi

install_wrapper_headers "${static_install_dir}/include"
prune_exported_headers "${static_install_dir}/include"
install_plugin_headers "${static_install_dir}/include"
install_wrapper_apinotes "${static_install_dir}/include"

# Static linking drops module registration objects unless something references
# them, and a dropped plugin leaves an artifact that still looks complete. Fail
# loudly instead of shipping a plugin-less library.
verify_merged_plugins() {
  local library="$1"
  local missing=() module symbols

  if [[ ${#plugin_modules[@]} -eq 0 ]]; then
    return 0
  fi

  symbols="$(nm -gU "${library}" 2>/dev/null || true)"
  for module in "${plugin_modules[@]}"; do
    # Match the C++ mangled forms, either plain or inside the rime namespace:
    # __Z<len>rime_require_module_<module>v / __ZN4rime<len>rime_require_module_<module>Ev
    # Use a here-string rather than a pipe: `grep -q` exits on the first match,
    # and under `pipefail` the resulting SIGPIPE on the writer would fail the
    # whole pipeline and report a present module as missing.
    if ! grep -qE "rime_require_module_${module}(v|Ev)$" <<< "${symbols}"; then
      missing+=("${module}")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    printf 'librime was built without merged plugin module(s): %s\n' "${missing[*]}" >&2
    printf 'expected rime_require_module_* symbols in %s\n' "${library}" >&2
    exit 1
  fi
  printf 'verified merged plugin modules in %s: %s\n' "${library}" "${plugin_modules[*]}"
}

verify_merged_plugins "${static_archive}"

if [[ "${build_dynamic}" -eq 1 ]]; then
  configure_and_install "${dynamic_build_dir}" "${dynamic_install_dir}" ON

  dynamic_library="${dynamic_install_dir}/lib/librime.dylib"
  if [[ ! -f "${dynamic_library}" ]]; then
    printf 'expected librime dynamic library was not produced: %s\n' "${dynamic_library}" >&2
    exit 1
  fi

  install_wrapper_headers "${dynamic_install_dir}/include"
  prune_exported_headers "${dynamic_install_dir}/include"
  install_plugin_headers "${dynamic_install_dir}/include"
  install_wrapper_apinotes "${dynamic_install_dir}/include"
fi

collect_vcpkg_notices "${install_dir}/notices"

# Record the resolved inputs next to the slice output. The packaging job reads
# this from the downloaded slice (it has no upstream checkout of its own), and a
# local run gets the same file, so both paths describe a build the same way.
"${script_dir}/resolve-version.sh" --env > "${install_dir}/source.env"

printf 'built %s at %s\n' "${platform}" "${install_dir}"
