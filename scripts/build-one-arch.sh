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
    deployment_target="${IOS_DEPLOYMENT_TARGET:-13.0}"
    cmake_system_name="iOS"
    osx_sysroot="iphoneos"
    build_dynamic=1
    ;;
  ios-simulator-arm64)
    arch="arm64"
    platform="ios-simulator-arm64"
    triplet="arm64-ios-simulator-static-release"
    deployment_target="${IOS_DEPLOYMENT_TARGET:-13.0}"
    cmake_system_name="iOS"
    osx_sysroot="iphonesimulator"
    build_dynamic=1
    ;;
  ios-simulator-x86_64)
    arch="x86_64"
    platform="ios-simulator-x86_64"
    triplet="x64-ios-simulator-static-release"
    deployment_target="${IOS_DEPLOYMENT_TARGET:-13.0}"
    cmake_system_name="iOS"
    osx_sysroot="iphonesimulator"
    build_dynamic=1
    ;;
  *)
    printf 'unsupported slice: %s\n' "${slice}" >&2
    exit 2
    ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
work_dir="${WORK_DIR:-${repo_root}/.build}"
build_dir="${work_dir}/build-${platform}"
static_build_dir="${build_dir}-static"
dynamic_build_dir="${build_dir}-dynamic"
source_work_dir="${work_dir}/src-${platform}"
install_dir="${OUT_DIR:-${repo_root}/out}/${platform}"
static_install_dir="${install_dir}/static"
dynamic_install_dir="${install_dir}/dynamic"
configuration="${CONFIGURATION:-Release}"
export VCPKG_OSX_DEPLOYMENT_TARGET="${VCPKG_OSX_DEPLOYMENT_TARGET:-${deployment_target}}"

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

upstream_ref="${UPSTREAM_REF:-}"
if [[ -z "${upstream_ref}" && -d "${source_dir}/.git" ]]; then
  upstream_ref="HEAD"
fi
upstream_ref="${upstream_ref:-HEAD}"

vcpkg_root="${VCPKG_ROOT:-}"
if [[ -z "${vcpkg_root}" ]]; then
  if [[ -d "${repo_root}/vcpkg/scripts/buildsystems" ]]; then
    vcpkg_root="${repo_root}/vcpkg"
  else
    printf 'VCPKG_ROOT is required, or checkout vcpkg into %s/vcpkg.\n' "${repo_root}" >&2
    exit 1
  fi
fi

if [[ ! -f "${vcpkg_root}/scripts/buildsystems/vcpkg.cmake" ]]; then
  printf 'vcpkg toolchain file was not found under VCPKG_ROOT: %s\n' "${vcpkg_root}" >&2
  exit 1
fi

rm -rf "${source_work_dir}" "${static_build_dir}" "${dynamic_build_dir}" "${install_dir}"
mkdir -p "${source_work_dir}" "${static_build_dir}" "${dynamic_build_dir}" "${static_install_dir}" "${dynamic_install_dir}"

if [[ -d "${source_dir}/.git" ]] && git -C "${source_dir}" rev-parse "${upstream_ref}^{commit}" >/dev/null 2>&1; then
  printf 'exporting %s from %s\n' "${upstream_ref}" "${source_dir}"
  git -C "${source_dir}" archive "${upstream_ref}" | tar -x -C "${source_work_dir}"
else
  printf 'copying current source checkout from %s\n' "${source_dir}"
  rsync -a --delete --exclude .git "${source_dir}/" "${source_work_dir}/"
fi

"${script_dir}/apply-patches.sh" "${source_work_dir}"

if [[ ! -f "${source_work_dir}/CMakeLists.txt" ]]; then
  printf 'selected source ref does not contain CMakeLists.txt: %s\n' "${source_work_dir}" >&2
  exit 1
fi

configure_common=(
  -S "${source_work_dir}"
  -G Ninja
  -DCMAKE_BUILD_TYPE="${configuration}"
  -DCMAKE_OSX_ARCHITECTURES="${arch}"
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${deployment_target}"
  -DCMAKE_INSTALL_NAME_DIR="@rpath"
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
  -DBUILD_TEST=OFF
  -DBUILD_TESTING=OFF
  -DBUILD_TOOLS=OFF
  -DBUILD_SAMPLE=OFF
  -DENABLE_EXTERNAL_PLUGINS=OFF
)

if [[ -n "${cmake_system_name}" ]]; then
  configure_common+=(-DCMAKE_SYSTEM_NAME="${cmake_system_name}")
fi

if [[ -n "${osx_sysroot}" ]]; then
  configure_common+=(-DCMAKE_OSX_SYSROOT="${osx_sysroot}")
fi

configure_and_install() {
  local output_dir="$1"
  local prefix="$2"
  local shared_libs="$3"

  cmake "${configure_common[@]}" \
    -B "${output_dir}" \
    -DCMAKE_INSTALL_PREFIX="${prefix}" \
    -DBUILD_SHARED_LIBS="${shared_libs}"

  cmake --build "${output_dir}" --config "${configuration}" --target install
}

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

cp "${repo_root}/include/RimeShim.h" "${static_install_dir}/include/RimeShim.h"
cp "${repo_root}/include/module.modulemap" "${static_install_dir}/include/module.modulemap"

if [[ "${build_dynamic}" -eq 1 ]]; then
  configure_and_install "${dynamic_build_dir}" "${dynamic_install_dir}" ON

  dynamic_library="${dynamic_install_dir}/lib/librime.dylib"
  if [[ ! -f "${dynamic_library}" ]]; then
    printf 'expected librime dynamic library was not produced: %s\n' "${dynamic_library}" >&2
    exit 1
  fi

  cp "${repo_root}/include/RimeShim.h" "${dynamic_install_dir}/include/RimeShim.h"
  cp "${repo_root}/include/module.dynamic.modulemap" "${dynamic_install_dir}/include/module.modulemap"
fi

printf 'built %s at %s\n' "${platform}" "${install_dir}"
