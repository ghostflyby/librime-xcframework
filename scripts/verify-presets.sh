#!/usr/bin/env bash
set -euo pipefail

# Checks that presets/CMakePresets.json expands to the configure values this
# repository intends, without building anything: a stub project stands in for
# librime and a stub toolchain for vcpkg, so this runs in seconds.
#
# It exists because the preset file is now the only place the configure matrix
# lives. A flag that quietly stopped being set - upstream's BUILD_TEST defaults to
# ON, so an artifact preset losing its "OFF" would install gtest and leak its
# license into the notices bundle - would otherwise only show up in a release.
# The checks run per leaf preset, since inheritance is what carries most of these
# values and a broken "inherits" is invisible in a JSON read.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
preset_file="${repo_root}/presets/CMakePresets.json"

if [[ ! -f "${preset_file}" ]]; then
  printf 'preset file does not exist: %s\n' "${preset_file}" >&2
  exit 1
fi

if ! command -v cmake >/dev/null 2>&1; then
  printf 'cmake is required to expand the presets\n' >&2
  exit 1
fi

probe_root="$(mktemp -d)"
trap 'rm -rf "${probe_root}"' EXIT

src="${probe_root}/src"
mkdir -p "${src}" "${probe_root}/fake-vcpkg/scripts/buildsystems" "${probe_root}/out"
# The toolchain only has to exist: these checks read the values CMake was
# configured with, and vcpkg itself is not consulted.
touch "${probe_root}/fake-vcpkg/scripts/buildsystems/vcpkg.cmake"

# Prints the value CMake ended up with for one variable, as reported by the
# configure below. CMAKE_SYSTEM_NAME and CMAKE_OSX_SYSROOT are printed too: CMake
# resolves both, so the check asserts what they resolved to rather than the
# literal in the preset.
cat > "${src}/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.21)
project(probe NONE)
foreach(v CMAKE_OSX_ARCHITECTURES CMAKE_OSX_DEPLOYMENT_TARGET CMAKE_SYSTEM_NAME
          CMAKE_OSX_SYSROOT CMAKE_INSTALL_NAME_DIR CMAKE_SHARED_LINKER_FLAGS
          CMAKE_BUILD_TYPE VCPKG_TARGET_TRIPLET VCPKG_MANIFEST_DIR
          VCPKG_OVERLAY_TRIPLETS VCPKG_OVERLAY_PORTS VCPKG_INSTALL_OPTIONS
          BUILD_STATIC WITH_STATIC_DEPS BUILD_MERGED_PLUGINS BUILD_SEPARATE_LIBS
          BUILD_TOOLS BUILD_SAMPLE ENABLE_EXTERNAL_PLUGINS
          BUILD_SHARED_LIBS BUILD_TEST BUILD_TESTING VCPKG_MANIFEST_FEATURES
          CMAKE_INSTALL_PREFIX)
  message(STATUS "PROBE ${v}=[${${v}}]")
endforeach()
message(STATUS "PROBE ENV_DEPLOY=[$ENV{VCPKG_OSX_DEPLOYMENT_TARGET}]")
EOF
ln -s "${preset_file}" "${src}/CMakePresets.json"

# The names the presets read back out of the environment, set to values this
# check can recognise. They are also the names configure_guard has to cover, which
# is checked at the bottom.
export VCPKG_ROOT="${probe_root}/fake-vcpkg"
export WRAPPER_ROOT="${repo_root}"
export OUT_DIR="${probe_root}/out"

failures=0

check() {
  local preset="$1" name="$2" want="$3" got="$4"

  if [[ "${got}" != "${want}" ]]; then
    printf 'FAIL %-28s %-24s want=[%s] got=[%s]\n' "${preset}" "${name}" "${want}" "${got}" >&2
    failures=$((failures + 1))
  fi
}

probe_get() {
  sed -n "s/^${2}=\[\(.*\)\]$/\1/p" "${probe_root}/${1}.probe"
}

leaves=(
  macos-arm64-static macos-arm64-dynamic macos-arm64-test
  macos-x86_64-static macos-x86_64-dynamic macos-x86_64-test
  ios-arm64-static ios-arm64-dynamic
  ios-simulator-arm64-static ios-simulator-arm64-dynamic
  ios-simulator-x86_64-static ios-simulator-x86_64-dynamic
)

for preset in "${leaves[@]}"; do
  # Not `cmake ... | sed`: under `pipefail` a failing configure aborts the script
  # through `set -e` before the check below can report anything, so the failure
  # would be a silent exit with no message. Captured in two steps instead, and
  # cmake's own output is echoed when it fails, since that is what names the
  # actual problem.
  output="$(cd "${src}" && cmake --preset "${preset}" 2>&1)" && rc=0 || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    printf 'FAIL %s did not configure:\n%s\n' "${preset}" "${output}" >&2
    failures=$((failures + 1))
    continue
  fi
  printf '%s\n' "${output}" | sed -n 's/^-- PROBE //p' > "${probe_root}/${preset}.probe"
  if [[ ! -s "${probe_root}/${preset}.probe" ]]; then
    printf 'FAIL %s produced no configure output\n' "${preset}" >&2
    failures=$((failures + 1))
  fi
done

# Values every slice shares, from the hidden wrapper preset.
expect_shared() {
  local preset="$1" pair
  for pair in "CMAKE_BUILD_TYPE=Release" "CMAKE_INSTALL_NAME_DIR=@rpath" \
              "CMAKE_SHARED_LINKER_FLAGS=-Wl,-headerpad_max_install_names" \
              "BUILD_STATIC=ON" "WITH_STATIC_DEPS=ON" "BUILD_MERGED_PLUGINS=ON" \
              "BUILD_SEPARATE_LIBS=OFF" "BUILD_TOOLS=OFF" "BUILD_SAMPLE=OFF" \
              "ENABLE_EXTERNAL_PLUGINS=OFF" "VCPKG_MANIFEST_DIR=${WRAPPER_ROOT}" \
              "VCPKG_OVERLAY_TRIPLETS=${WRAPPER_ROOT}/triplets" \
              "VCPKG_OVERLAY_PORTS=${WRAPPER_ROOT}/ports" \
              "VCPKG_INSTALL_OPTIONS=--allow-unsupported"; do
    check "${preset}" "${pair%%=*}" "${pair#*=}" "$(probe_get "${preset}" "${pair%%=*}")"
  done
}

expect_slice() {
  local preset="$1" arch="$2" deploy="$3" triplet="$4" shared="$5" prefix="$6" \
        sysname="${7:-Darwin}" sysroot_kind="${8:-}"

  check "${preset}" CMAKE_OSX_ARCHITECTURES "${arch}" "$(probe_get "${preset}" CMAKE_OSX_ARCHITECTURES)"
  check "${preset}" CMAKE_OSX_DEPLOYMENT_TARGET "${deploy}" "$(probe_get "${preset}" CMAKE_OSX_DEPLOYMENT_TARGET)"
  check "${preset}" VCPKG_TARGET_TRIPLET "${triplet}" "$(probe_get "${preset}" VCPKG_TARGET_TRIPLET)"
  check "${preset}" BUILD_SHARED_LIBS "${shared}" "$(probe_get "${preset}" BUILD_SHARED_LIBS)"
  check "${preset}" CMAKE_INSTALL_PREFIX "${prefix}" "$(probe_get "${preset}" CMAKE_INSTALL_PREFIX)"
  # CMake reports the host as Darwin where a preset sets no CMAKE_SYSTEM_NAME,
  # which is what the macOS slices did before they had presets.
  check "${preset}" CMAKE_SYSTEM_NAME "${sysname}" "$(probe_get "${preset}" CMAKE_SYSTEM_NAME)"

  local resolved
  resolved="$(probe_get "${preset}" CMAKE_OSX_SYSROOT)"
  if [[ -n "${sysroot_kind}" ]]; then
    # CMake normalizes a sysroot name to the SDK path it resolves to.
    if [[ "${resolved}" != *"${sysroot_kind}"* ]]; then
      printf 'FAIL %-28s %-24s want an SDK path for %s, got=[%s]\n' \
        "${preset}" CMAKE_OSX_SYSROOT "${sysroot_kind}" "${resolved}" >&2
      failures=$((failures + 1))
    fi
  else
    check "${preset}" CMAKE_OSX_SYSROOT "" "${resolved}"
  fi

  # The deployment target reaches the toolchain through the environment as well as
  # the cache variable, because the triplets read it when vcpkg builds a port.
  check "${preset}" ENV_DEPLOY "${deploy}" "$(probe_get "${preset}" ENV_DEPLOY)"

  expect_shared "${preset}"
}

expect_slice macos-arm64-static           arm64  11.0 arm64-osx-static-release           OFF "${OUT_DIR}/macos-arm64/static"
expect_slice macos-arm64-dynamic          arm64  11.0 arm64-osx-static-release           ON  "${OUT_DIR}/macos-arm64/dynamic"
expect_slice macos-x86_64-static          x86_64 11.0 x64-osx-static-release             OFF "${OUT_DIR}/macos-x86_64/static"
expect_slice macos-x86_64-dynamic         x86_64 11.0 x64-osx-static-release             ON  "${OUT_DIR}/macos-x86_64/dynamic"
expect_slice ios-arm64-static             arm64  15.0 arm64-ios-static-release           OFF "${OUT_DIR}/ios-arm64/static" iOS iPhoneOS
expect_slice ios-arm64-dynamic            arm64  15.0 arm64-ios-static-release           ON  "${OUT_DIR}/ios-arm64/dynamic" iOS iPhoneOS
expect_slice ios-simulator-arm64-static   arm64  15.0 arm64-ios-simulator-static-release OFF "${OUT_DIR}/ios-simulator-arm64/static" iOS iPhoneSimulator
expect_slice ios-simulator-arm64-dynamic  arm64  15.0 arm64-ios-simulator-static-release ON  "${OUT_DIR}/ios-simulator-arm64/dynamic" iOS iPhoneSimulator
expect_slice ios-simulator-x86_64-static  x86_64 15.0 x64-ios-simulator-static-release  OFF "${OUT_DIR}/ios-simulator-x86_64/static" iOS iPhoneSimulator
expect_slice ios-simulator-x86_64-dynamic x86_64 15.0 x64-ios-simulator-static-release  ON  "${OUT_DIR}/ios-simulator-x86_64/dynamic" iOS iPhoneSimulator

# An artifact build must not carry test settings: upstream defaults BUILD_TEST to
# ON, and the tests feature is what installs gtest, whose license would then be
# collected into the notices bundle for an artifact that does not contain it.
for preset in "${leaves[@]}"; do
  case "${preset}" in *-test) continue ;; esac
  check "${preset}" BUILD_TEST "OFF" "$(probe_get "${preset}" BUILD_TEST)"
  check "${preset}" BUILD_TESTING "OFF" "$(probe_get "${preset}" BUILD_TESTING)"
  check "${preset}" VCPKG_MANIFEST_FEATURES "" "$(probe_get "${preset}" VCPKG_MANIFEST_FEATURES)"
done

# Test builds need a shared library - upstream only adds its test directory when
# it builds one - and gtest, which the manifest's tests feature provides. Their
# slice values are checked too: the test job is what gates a release, and a test
# preset inheriting the wrong slice would build and pass a suite for a different
# architecture than the artifacts, on a runner where Rosetta can hide it.
for preset in macos-arm64-test macos-x86_64-test; do
  check "${preset}" BUILD_SHARED_LIBS "ON" "$(probe_get "${preset}" BUILD_SHARED_LIBS)"
  check "${preset}" BUILD_TEST "ON" "$(probe_get "${preset}" BUILD_TEST)"
  check "${preset}" BUILD_TESTING "ON" "$(probe_get "${preset}" BUILD_TESTING)"
  check "${preset}" VCPKG_MANIFEST_FEATURES "tests" "$(probe_get "${preset}" VCPKG_MANIFEST_FEATURES)"
done

# CMake normalizes the `${sourceDir}/../build-...` form, so the expectation is the
# normalized path; `src` sits one level under the probe root.
expect_slice macos-arm64-test  arm64  11.0 arm64-osx-static-release ON "${probe_root}/build-macos-arm64-test/install"
expect_slice macos-x86_64-test x86_64 11.0 x64-osx-static-release   ON "${probe_root}/build-macos-x86_64-test/install"

# Every $env{...} name the presets read has to be in configure_guard, or a build
# tree configured with one value would be reused for another without anything
# noticing. A name that only ever takes a literal in the file is covered by the
# file's digest, which the guard also holds.
guard_body="$(sed -n '/^configure_guard()/,/^}/p' "${script_dir}/build-one-arch.sh")"
# shellcheck disable=SC2016  # matches the literal $env{...} text in the preset file
while IFS= read -r name; do
  case "${name}" in
    # Set as a literal in the presets' environment blocks, so the digest covers it.
    VCPKG_OSX_DEPLOYMENT_TARGET) continue ;;
  esac
  lowered="$(printf '%s' "${name}" | tr '[:upper:]' '[:lower:]')"
  # Anchored, not a substring search: "wrapper_root=" contains "root=" and the
  # extras contain "dir=", so a plain substring test would accept any name whose
  # lowercase form happened to end in one of those.
  if ! grep -qE "^[[:space:]]*\"${lowered}=" <<< "${guard_body}"; then
    # shellcheck disable=SC2016  # the literal $env{...} spelling is the point
    printf 'FAIL preset reads $env{%s} but configure_guard does not cover it\n' "${name}" >&2
    failures=$((failures + 1))
  fi
done < <(grep -o '\$env{[A-Za-z_]*}' "${preset_file}" | sed 's/^\$env{//; s/}$//' | sort -u)

# Every leaf the build script asks for has to exist, and every leaf in the file
# has to be checked above. Without this a slice added to the script without a
# preset would pass here and fail late, in a run that has already spent a vcpkg
# bootstrap.
declared="$(python3 -c "
import json, sys
names = {p['name'] for p in json.load(open(sys.argv[1]))['configurePresets']}
print('\n'.join(sorted(n for n in names if not n.startswith('slice-') and n != 'wrapper')))
" "${preset_file}")"
while IFS= read -r name; do
  [[ -n "${name}" ]] || continue
  if [[ " ${leaves[*]} " != *" ${name} "* ]]; then
    printf 'FAIL preset %s is not checked by this script\n' "${name}" >&2
    failures=$((failures + 1))
  fi
done <<< "${declared}"
while IFS= read -r name; do
  [[ -n "${name}" ]] || continue
  if ! grep -qxF "${name}" <<< "${declared}"; then
    printf 'FAIL this script checks %s but the preset file has no such preset\n' "${name}" >&2
    failures=$((failures + 1))
  fi
done < <(printf '%s\n' "${leaves[@]}")

if [[ "${failures}" -gt 0 ]]; then
  printf '%d preset check(s) failed\n' "${failures}" >&2
  exit 1
fi

printf 'presets expand as expected (%d leaves checked)\n' "${#leaves[@]}"
