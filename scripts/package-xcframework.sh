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
  "${legacy_static_xcframework_path}" "${legacy_static_zip_path}" \
  "${legacy_checksum_path}" "${universal_dir}" "${ios_simulator_universal_dir}" "${dynamic_frameworks_dir}"
mkdir -p "${dist_dir}"
mkdir -p "${universal_dir}/static/lib" "${universal_dir}/dynamic/lib" "${ios_simulator_universal_dir}/static/lib" "${ios_simulator_universal_dir}/dynamic/lib"

create_dynamic_framework() {
  local framework_path="$1"
  local binary_path="$2"
  local headers_path="$3"
  local minimum_os_version="$4"
  local framework_name="RimeDynamic"

  rm -rf "${framework_path}"
  mkdir -p "${framework_path}/Headers" "${framework_path}/Modules"
  cp "${binary_path}" "${framework_path}/${framework_name}"
  chmod u+w "${framework_path}/${framework_name}"
  install_name_tool -id "@rpath/${framework_name}.framework/${framework_name}" "${framework_path}/${framework_name}"
  rsync -a --delete --exclude module.modulemap "${headers_path}/" "${framework_path}/Headers/"
  cp "${repo_root}/include/module.dynamic.modulemap" "${framework_path}/Modules/module.modulemap"
  cat > "${framework_path}/Info.plist" <<PLIST
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

write_dynamic_slice_modulemaps() {
  local framework_path
  local slice_dir

  while IFS= read -r -d '' framework_path; do
    slice_dir="$(dirname "${framework_path}")"
    cat > "${slice_dir}/module.modulemap" <<MODULEMAP
module RimeDynamic {
  umbrella header "RimeDynamic.framework/Headers/RimeShim.h"
  link framework "RimeDynamic"
  export *
}
MODULEMAP
  done < <(find "${dynamic_xcframework_path}" -mindepth 2 -maxdepth 2 -name 'RimeDynamic.framework' -type d -print0)
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

create_dynamic_framework "${macos_dynamic_framework}" "${dynamic_universal_lib}" "${dynamic_universal_headers}" "11.0"
create_dynamic_framework "${ios_device_dynamic_framework}" "${ios_device_dynamic_lib}" "${ios_device_dynamic_headers}" "13.0"
create_dynamic_framework "${ios_simulator_dynamic_framework}" "${ios_simulator_dynamic_universal_lib}" "${ios_simulator_arm64_dynamic_headers}" "13.0"

xcodebuild -create-xcframework \
  -framework "${macos_dynamic_framework}" \
  -framework "${ios_device_dynamic_framework}" \
  -framework "${ios_simulator_dynamic_framework}" \
  -output "${dynamic_xcframework_path}"

write_dynamic_slice_modulemaps

(
  cd "${dist_dir}"
  ditto -c -k --sequesterRsrc --keepParent "librime-static.xcframework" "librime-static.xcframework.zip"
  ditto -c -k --sequesterRsrc --keepParent "librime-dynamic.xcframework" "librime-dynamic.xcframework.zip"
)

"${script_dir}/write-build-metadata.sh" "${dist_dir}/build-metadata.json"

printf 'packaged %s\n' "${static_zip_path}"
printf 'packaged %s\n' "${dynamic_zip_path}"
