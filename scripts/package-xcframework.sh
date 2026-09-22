#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
out_dir="${OUT_DIR:-${repo_root}/out}"
dist_dir="${DIST_DIR:-${repo_root}/dist}"
static_xcframework_path="${dist_dir}/librime-static.xcframework"
static_zip_path="${dist_dir}/librime-static.xcframework.zip"
dynamic_xcframework_path="${dist_dir}/librime-dynamic.xcframework"
dynamic_zip_path="${dist_dir}/librime-dynamic.xcframework.zip"
stub_xcframework_path="${dist_dir}/librime-stub.xcframework"
stub_zip_path="${dist_dir}/librime-stub.xcframework.zip"
license_output_path="${dist_dir}/LICENSE.txt"
third_party_notice_output_path="${dist_dir}/THIRD_PARTY_NOTICES.md"
third_party_notice_bundle_path="${dist_dir}/third-party-notices"
third_party_notice_zip_path="${dist_dir}/third-party-notices.zip"
legacy_static_xcframework_path="${dist_dir}/librime.xcframework"
legacy_static_zip_path="${dist_dir}/librime.xcframework.zip"
legacy_checksum_path="${dist_dir}/librime.xcframework.sha256"

arm64_static_lib="${out_dir}/macos-arm64/static/lib/librime.a"
arm64_static_headers="${out_dir}/macos-arm64/static/include"
x86_64_static_lib="${out_dir}/macos-x86_64/static/lib/librime.a"
x86_64_static_headers="${out_dir}/macos-x86_64/static/include"
ios_device_static_lib="${out_dir}/ios-arm64/static/lib/librime.a"
ios_device_static_headers="${out_dir}/ios-arm64/static/include"
ios_simulator_arm64_static_lib="${out_dir}/ios-simulator-arm64/static/lib/librime.a"
ios_simulator_arm64_static_headers="${out_dir}/ios-simulator-arm64/static/include"
ios_simulator_x86_64_static_lib="${out_dir}/ios-simulator-x86_64/static/lib/librime.a"
ios_simulator_x86_64_static_headers="${out_dir}/ios-simulator-x86_64/static/include"
arm64_dynamic_lib="${out_dir}/macos-arm64/dynamic/lib/librime.dylib"
arm64_dynamic_headers="${out_dir}/macos-arm64/dynamic/include"
x86_64_dynamic_lib="${out_dir}/macos-x86_64/dynamic/lib/librime.dylib"
x86_64_dynamic_headers="${out_dir}/macos-x86_64/dynamic/include"
ios_device_dynamic_lib="${out_dir}/ios-arm64/dynamic/lib/librime.dylib"
ios_device_dynamic_headers="${out_dir}/ios-arm64/dynamic/include"
ios_simulator_arm64_dynamic_lib="${out_dir}/ios-simulator-arm64/dynamic/lib/librime.dylib"
ios_simulator_arm64_dynamic_headers="${out_dir}/ios-simulator-arm64/dynamic/include"
ios_simulator_x86_64_dynamic_lib="${out_dir}/ios-simulator-x86_64/dynamic/lib/librime.dylib"
ios_simulator_x86_64_dynamic_headers="${out_dir}/ios-simulator-x86_64/dynamic/include"
universal_dir="${out_dir}/macos-universal"
static_universal_lib="${universal_dir}/static/lib/librime.a"
static_universal_headers="${universal_dir}/static/include"
dynamic_universal_lib="${universal_dir}/dynamic/lib/librime.dylib"
dynamic_universal_headers="${universal_dir}/dynamic/include"
ios_simulator_universal_dir="${out_dir}/ios-simulator-universal"
ios_simulator_universal_lib="${ios_simulator_universal_dir}/static/lib/librime.a"
ios_simulator_universal_headers="${ios_simulator_universal_dir}/static/include"
ios_simulator_dynamic_universal_lib="${ios_simulator_universal_dir}/dynamic/lib/librime.dylib"
dynamic_frameworks_dir="${out_dir}/dynamic-frameworks"
macos_dynamic_framework="${dynamic_frameworks_dir}/macos/RimeDynamic.framework"
ios_device_dynamic_framework="${dynamic_frameworks_dir}/ios/RimeDynamic.framework"
ios_simulator_dynamic_framework="${dynamic_frameworks_dir}/ios-simulator/RimeDynamic.framework"

for path in \
  "${arm64_static_lib}" "${arm64_static_headers}" \
  "${x86_64_static_lib}" "${x86_64_static_headers}" \
  "${ios_device_static_lib}" "${ios_device_static_headers}" \
  "${ios_simulator_arm64_static_lib}" "${ios_simulator_arm64_static_headers}" \
  "${ios_simulator_x86_64_static_lib}" "${ios_simulator_x86_64_static_headers}" \
  "${arm64_dynamic_lib}" "${arm64_dynamic_headers}" \
  "${x86_64_dynamic_lib}" "${x86_64_dynamic_headers}" \
  "${ios_device_dynamic_lib}" "${ios_device_dynamic_headers}" \
  "${ios_simulator_arm64_dynamic_lib}" "${ios_simulator_arm64_dynamic_headers}" \
  "${ios_simulator_x86_64_dynamic_lib}" "${ios_simulator_x86_64_dynamic_headers}"; do
  if [[ ! -e "${path}" ]]; then
    printf 'missing required build output: %s\n' "${path}" >&2
    exit 1
  fi
done

rm -rf \
  "${static_xcframework_path}" "${static_zip_path}" \
  "${dynamic_xcframework_path}" "${dynamic_zip_path}" \
  "${stub_xcframework_path}" "${stub_zip_path}" \
  "${license_output_path}" "${third_party_notice_output_path}" \
  "${third_party_notice_bundle_path}" "${third_party_notice_zip_path}" \
  "${legacy_static_xcframework_path}" "${legacy_static_zip_path}" \
  "${legacy_checksum_path}" "${universal_dir}" "${ios_simulator_universal_dir}" "${dynamic_frameworks_dir}"
mkdir -p "${dist_dir}"
mkdir -p "${universal_dir}/static/lib" "${universal_dir}/dynamic/lib" "${ios_simulator_universal_dir}/static/lib" "${ios_simulator_universal_dir}/dynamic/lib"

write_dynamic_info_plist() {
  local plist_path="$1"
  local minimum_os_version="$2"
  local framework_name="RimeDynamic"

  cat > "${plist_path}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${framework_name}</string>
  <key>CFBundleIdentifier</key>
  <string>org.rime.${framework_name}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${framework_name}</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>MinimumOSVersion</key>
  <string>${minimum_os_version}</string>
</dict>
</plist>
PLIST
}

create_dynamic_framework() {
  local framework_path="$1"
  local binary_path="$2"
  local headers_path="$3"
  local minimum_os_version="$4"
  local framework_name="RimeDynamic"

  rm -rf "${framework_path}"
  mkdir -p "${framework_path}/Headers"
  cp "${binary_path}" "${framework_path}/${framework_name}"
  chmod u+w "${framework_path}/${framework_name}"
  install_name_tool -id "@rpath/${framework_name}.framework/${framework_name}" "${framework_path}/${framework_name}"
  rsync -a --delete --exclude module.modulemap "${headers_path}/" "${framework_path}/Headers/"
  write_dynamic_info_plist "${framework_path}/Info.plist" "${minimum_os_version}"
}

# macOS validates embedded frameworks as versioned bundles, so the macOS slice
# must be a deep package (Versions/A) with a Versions/A install name; a shallow
# copy fails app validation after SPM embedding.
create_macos_dynamic_framework() {
  local framework_path="$1"
  local binary_path="$2"
  local headers_path="$3"
  local minimum_os_version="$4"
  local framework_name="RimeDynamic"
  local bundle_root="${framework_path}/Versions/A"

  rm -rf "${framework_path}"
  mkdir -p "${bundle_root}/Headers" "${bundle_root}/Resources"
  cp "${binary_path}" "${bundle_root}/${framework_name}"
  chmod u+w "${bundle_root}/${framework_name}"
  install_name_tool -id "@rpath/${framework_name}.framework/Versions/A/${framework_name}" "${bundle_root}/${framework_name}"
  rsync -a --delete --exclude module.modulemap "${headers_path}/" "${bundle_root}/Headers/"
  write_dynamic_info_plist "${bundle_root}/Resources/Info.plist" "${minimum_os_version}"
  ln -sfn "A" "${framework_path}/Versions/Current"
  ln -sfn "Versions/Current/${framework_name}" "${framework_path}/${framework_name}"
  ln -sfn "Versions/Current/Headers" "${framework_path}/Headers"
  ln -sfn "Versions/Current/Resources" "${framework_path}/Resources"
}

# The linker stub lets extension-like targets link the dynamic framework without
# embedding it, so every one of them is served by the app's single embedded copy.
# It is a Mach-O dylib that exports the real dylib's symbols under the real
# dylib's install name, which is what makes a client record a load command for
# @rpath/RimeDynamic.framework/... and resolve it at runtime against whatever the
# app embedded.
#
# It ships as a binary target rather than as committed source so the package
# needs no per-consumer framework search path, and that is also why the stub is
# a real binary: a framework holding only a text-based stub cannot be staged or
# embedded, because Xcode reads the framework's binary when it copies one into a
# bundle. build-linker-stub.sh derives every mirrored property from the released
# dylibs. The three slices are assembled into an XCFramework, which the release
# workflow zips and uploads alongside the other two.
generate_linker_stubs() {
  local stubs_dir="${out_dir}/linker-stubs"
  local platform source_binary

  rm -rf "${stubs_dir}"
  for platform in macos ios ios-simulator; do
    case "${platform}" in
      macos) source_binary="${macos_dynamic_framework}/Versions/A/RimeDynamic" ;;
      ios) source_binary="${ios_device_dynamic_framework}/RimeDynamic" ;;
      ios-simulator) source_binary="${ios_simulator_dynamic_framework}/RimeDynamic" ;;
    esac
    "${script_dir}/build-linker-stub.sh" \
      "${platform}" "${source_binary}" "${stubs_dir}/${platform}/RimeDynamicStub.framework"
  done

  rm -rf "${stub_xcframework_path}"
  xcodebuild -create-xcframework \
    -framework "${stubs_dir}/macos/RimeDynamicStub.framework" \
    -framework "${stubs_dir}/ios/RimeDynamicStub.framework" \
    -framework "${stubs_dir}/ios-simulator/RimeDynamicStub.framework" \
    -output "${stub_xcframework_path}"
}

copy_distribution_notices() {
  local notices_readme_path="${third_party_notice_bundle_path}/README.md"
  local notice_file port_name destination

  cp "${repo_root}/LICENSE" "${license_output_path}"
  cp "${repo_root}/THIRD_PARTY_NOTICES.md" "${third_party_notice_output_path}"

  mkdir -p "${third_party_notice_bundle_path}/vcpkg" "${third_party_notice_bundle_path}/librime"
  cat > "${notices_readme_path}" <<'README'
# Third-Party Dependency Notices

This directory contains vcpkg-provided license texts for third-party dependency
code that may be linked into the librime XCFramework binary artifacts, plus the
license texts of the upstream Rime plugins statically merged into librime (see
`plugins/`). A merged plugin that is a source directory of the packaging
repository itself is covered by LICENSE.txt instead.

The release also includes LICENSE.txt for this packaging wrapper and
THIRD_PARTY_NOTICES.md for the upstream librime notice.
README

  while IFS= read -r -d '' notice_file; do
    port_name="$(basename "${notice_file}" .txt)"
    destination="${third_party_notice_bundle_path}/vcpkg/${port_name}.txt"
    if [[ ! -f "${destination}" ]]; then
      cp "${notice_file}" "${destination}"
    fi
  done < <(find "${out_dir}" -path '*/notices/vcpkg/*.txt' -type f -print0)

  while IFS= read -r -d '' notice_file; do
    name="$(basename "${notice_file}" .txt)"
    destination="${third_party_notice_bundle_path}/librime/${name}.txt"
    if [[ ! -f "${destination}" ]]; then
      cp "${notice_file}" "${destination}"
    fi
  done < <(find "${out_dir}" -path '*/notices/librime/*.txt' -type f -print0)

  "${script_dir}/collect-plugin-notices.sh" "${third_party_notice_bundle_path}"

  # Every slice ships its own notices/, so a missing category means the bundle
  # would silently under-report what the binaries contain.
  local category
  for category in vcpkg librime plugins; do
    if [[ -z "$(find "${third_party_notice_bundle_path}/${category}" -type f -print -quit 2>/dev/null)" ]]; then
      printf 'third-party notices bundle has no %s license texts; was a slice built?\n' "${category}" >&2
      exit 1
    fi
  done
}

# Keep the sources committed in this repository in step with the artifacts this
# run produced. Sources/RimeHeaders/include is what downstream checks out to
# build against, so it is refreshed as part of packaging - the same place the
# artifacts are assembled - rather than as a separate operation someone has to
# remember. The linker stub is not committed: it ships as a binary target, so it
# is produced and zipped with the other artifacts instead.
sync_repository_sources() {
  local headers_dir="${repo_root}/Sources/RimeHeaders/include"
  local smoke_dir

  # The artifact's own notes are validated before anything is copied over the
  # committed ones: the shipped XCFramework must carry notes that match its
  # headers, and rendering a fresh file first would make that check pass
  # regardless. Reading the build output directly also keeps a failure from
  # leaving the tracked file deleted or replaced in the working tree.
  "${script_dir}/sync-apinotes.sh" --check --headers "${arm64_dynamic_headers}"

  # --delete is deliberate: the committed headers must be exactly what the
  # artifacts carry, so a header that disappeared from the build output must
  # disappear here too. module.modulemap is excluded because it is written by
  # hand below rather than shipped in the artifacts (the XCFrameworks
  # intentionally carry no module map).
  mkdir -p "${headers_dir}"
  rsync -a --delete --exclude module.modulemap "${arm64_dynamic_headers}/" "${headers_dir}/"
  cat > "${headers_dir}/module.modulemap" <<'MODULEMAP'
module Rime {
  umbrella header "RimeShim.h"
  export *
}
MODULEMAP

  # Compile the umbrella as a module: catches a header the sync dropped or broke
  # before anything is committed.
  smoke_dir="$(mktemp -d)"
  printf '#include "RimeShim.h"\n' > "${smoke_dir}/rime-module-smoke.c"
  xcrun clang -fmodules -fsyntax-only -I "${headers_dir}" "${smoke_dir}/rime-module-smoke.c"
  rm -rf "${smoke_dir}"

  # Both committed copies then follow the synced set, so a release cannot tag one
  # copy of the file while the other describes different headers.
  "${script_dir}/sync-apinotes.sh" --headers "${headers_dir}"

  # The sync above deletes files absent from the build output, so this also
  # proves Rime.apinotes travelled with the artifacts and that the un-suffixed
  # Swift names still resolve against them.
  "${script_dir}/verify-swift-names.sh" "${headers_dir}"

  printf 'synced repository sources: headers\n'
}

rsync -a --delete "${arm64_static_headers}/" "${static_universal_headers}/"
lipo -create "${arm64_static_lib}" "${x86_64_static_lib}" -output "${static_universal_lib}"
rsync -a --delete "${ios_simulator_arm64_static_headers}/" "${ios_simulator_universal_headers}/"
lipo -create \
  "${ios_simulator_arm64_static_lib}" \
  "${ios_simulator_x86_64_static_lib}" \
  -output "${ios_simulator_universal_lib}"

xcodebuild -create-xcframework \
  -library "${static_universal_lib}" \
  -headers "${static_universal_headers}" \
  -library "${ios_device_static_lib}" \
  -headers "${ios_device_static_headers}" \
  -library "${ios_simulator_universal_lib}" \
  -headers "${ios_simulator_universal_headers}" \
  -output "${static_xcframework_path}"

rsync -a --delete "${arm64_dynamic_headers}/" "${dynamic_universal_headers}/"
lipo -create "${arm64_dynamic_lib}" "${x86_64_dynamic_lib}" -output "${dynamic_universal_lib}"
lipo -create \
  "${ios_simulator_arm64_dynamic_lib}" \
  "${ios_simulator_x86_64_dynamic_lib}" \
  -output "${ios_simulator_dynamic_universal_lib}"

create_macos_dynamic_framework "${macos_dynamic_framework}" "${dynamic_universal_lib}" "${dynamic_universal_headers}" "11.0"
create_dynamic_framework "${ios_device_dynamic_framework}" "${ios_device_dynamic_lib}" "${ios_device_dynamic_headers}" "15.0"
create_dynamic_framework "${ios_simulator_dynamic_framework}" "${ios_simulator_dynamic_universal_lib}" "${ios_simulator_arm64_dynamic_headers}" "15.0"

xcodebuild -create-xcframework \
  -framework "${macos_dynamic_framework}" \
  -framework "${ios_device_dynamic_framework}" \
  -framework "${ios_simulator_dynamic_framework}" \
  -output "${dynamic_xcframework_path}"

generate_linker_stubs

sync_repository_sources

copy_distribution_notices

(
  cd "${dist_dir}"
  ditto -c -k --sequesterRsrc --keepParent "librime-static.xcframework" "librime-static.xcframework.zip"
  ditto -c -k --sequesterRsrc --keepParent "librime-dynamic.xcframework" "librime-dynamic.xcframework.zip"
  ditto -c -k --sequesterRsrc --keepParent "librime-stub.xcframework" "librime-stub.xcframework.zip"
  ditto -c -k --sequesterRsrc --keepParent "third-party-notices" "third-party-notices.zip"
)

"${script_dir}/write-build-metadata.sh" "${dist_dir}/build-metadata.json"

printf 'packaged %s\n' "${static_zip_path}"
printf 'packaged %s\n' "${dynamic_zip_path}"
printf 'packaged %s\n' "${stub_zip_path}"
printf 'packaged %s\n' "${third_party_notice_zip_path}"
