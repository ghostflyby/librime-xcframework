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

# Linker stubs let XPC and extension targets link the dynamic framework without
# embedding it and share the app's single embedded copy. Each platform gets a
# skeleton framework in the SDK style: the tbd sits at the binary's position
# inside RimeDynamic.framework (deep Versions/A layout for macOS, flat for
# iOS), and the release workflow commits the skeletons under
# Sources/RimeDynamicStub. tapi writes the tbd next to its input, so each
# binary is copied to scratch first to keep the framework directories clean.
generate_linker_stubs() {
  local stubs_dir="${out_dir}/linker-stubs"
  local platform binary tbd

  rm -rf "${stubs_dir}"
  for platform in macos ios ios-simulator; do
    case "${platform}" in
      macos) binary="${macos_dynamic_framework}/Versions/A/RimeDynamic" ;;
      ios) binary="${ios_device_dynamic_framework}/RimeDynamic" ;;
      ios-simulator) binary="${ios_simulator_dynamic_framework}/RimeDynamic" ;;
    esac
    mkdir -p "${stubs_dir}/.scratch/${platform}" "${stubs_dir}/${platform}/RimeDynamic.framework"
    cp "${binary}" "${stubs_dir}/.scratch/${platform}/RimeDynamic"
    (cd "${stubs_dir}/.scratch/${platform}" && xcrun tapi stubify RimeDynamic)
    tbd="${stubs_dir}/.scratch/${platform}/RimeDynamic.tbd"
    if [[ "${platform}" == "macos" ]]; then
      mkdir -p "${stubs_dir}/${platform}/RimeDynamic.framework/Versions/A"
      mv "${tbd}" "${stubs_dir}/${platform}/RimeDynamic.framework/Versions/A/RimeDynamic.tbd"
      ln -sfn "A" "${stubs_dir}/${platform}/RimeDynamic.framework/Versions/Current"
      ln -sfn "Versions/Current/RimeDynamic.tbd" "${stubs_dir}/${platform}/RimeDynamic.framework/RimeDynamic"
    else
      mv "${tbd}" "${stubs_dir}/${platform}/RimeDynamic.framework/RimeDynamic.tbd"
    fi
  done
  rm -rf "${stubs_dir}/.scratch"
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

copy_distribution_notices

(
  cd "${dist_dir}"
  ditto -c -k --sequesterRsrc --keepParent "librime-static.xcframework" "librime-static.xcframework.zip"
  ditto -c -k --sequesterRsrc --keepParent "librime-dynamic.xcframework" "librime-dynamic.xcframework.zip"
  ditto -c -k --sequesterRsrc --keepParent "third-party-notices" "third-party-notices.zip"
)

"${script_dir}/write-build-metadata.sh" "${dist_dir}/build-metadata.json"

printf 'packaged %s\n' "${static_zip_path}"
printf 'packaged %s\n' "${dynamic_zip_path}"
printf 'packaged %s\n' "${third_party_notice_zip_path}"
