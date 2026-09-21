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

export RIME_PLUGINS="$("${script_dir}/prepare-plugins.sh" "${source_work_dir}")"

plugin_modules=(${RIME_PLUGINS})
if [[ ${#plugin_modules[@]} -eq 0 ]]; then
  printf 'no plugins were prepared; the artifacts are expected to merge the plugins from plugins.json\n' >&2
  exit 1
fi
printf 'merging plugin modules: %s\n' "${plugin_modules[*]}"

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

prune_exported_headers() {
  local include_dir="$1"

  rm -f "${include_dir}/rime_api_deprecated.h"
}

# Copy the files this repository owns into the exported include directory, so
# they travel with the build output. The release pipeline syncs that directory
# into Sources/RimeHeaders/include/, and because that sync deletes files absent
# from the source it would otherwise remove them from the package.
install_wrapper_headers() {
  local include_dir="$1"

  cp "${repo_root}/Sources/RimeHeaders/include/RimeShim.h" \
    "${include_dir}/RimeShim.h"
  cp "${repo_root}/Sources/RimeHeaders/include/Rime.apinotes" \
    "${include_dir}/Rime.apinotes"
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

  while IFS= read -r -d '' header; do
    header_name="$(basename "${header}")"
    destination="${include_dir}/${header_name}"
    if [[ -e "${destination}" ]]; then
      printf 'plugin header %s would overwrite an exported header: %s\n' \
        "${header}" "${destination}" >&2
      exit 1
    fi
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
fi

collect_vcpkg_notices "${install_dir}/notices"

printf 'built %s at %s\n' "${platform}" "${install_dir}"
