#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
out_dir="${OUT_DIR:-${repo_root}/out}"
dist_dir="${DIST_DIR:-${repo_root}/dist}"
static_xcframework_path="${dist_dir}/librime.xcframework"
static_zip_path="${dist_dir}/librime.xcframework.zip"
dynamic_xcframework_path="${dist_dir}/librime-dynamic.xcframework"
dynamic_zip_path="${dist_dir}/librime-dynamic.xcframework.zip"
legacy_checksum_path="${dist_dir}/librime.xcframework.sha256"

arm64_static_lib="${out_dir}/macos-arm64/static/lib/librime.a"
arm64_static_headers="${out_dir}/macos-arm64/static/include"
x86_64_static_lib="${out_dir}/macos-x86_64/static/lib/librime.a"
x86_64_static_headers="${out_dir}/macos-x86_64/static/include"
arm64_dynamic_lib="${out_dir}/macos-arm64/dynamic/lib/librime.dylib"
arm64_dynamic_headers="${out_dir}/macos-arm64/dynamic/include"
x86_64_dynamic_lib="${out_dir}/macos-x86_64/dynamic/lib/librime.dylib"
x86_64_dynamic_headers="${out_dir}/macos-x86_64/dynamic/include"
universal_dir="${out_dir}/macos-universal"
static_universal_lib="${universal_dir}/static/lib/librime.a"
static_universal_headers="${universal_dir}/static/include"
dynamic_universal_lib="${universal_dir}/dynamic/lib/librime.dylib"
dynamic_universal_headers="${universal_dir}/dynamic/include"

for path in \
  "${arm64_static_lib}" "${arm64_static_headers}" \
  "${x86_64_static_lib}" "${x86_64_static_headers}" \
  "${arm64_dynamic_lib}" "${arm64_dynamic_headers}" \
  "${x86_64_dynamic_lib}" "${x86_64_dynamic_headers}"; do
  if [[ ! -e "${path}" ]]; then
    printf 'missing required build output: %s\n' "${path}" >&2
    exit 1
  fi
done

rm -rf \
  "${static_xcframework_path}" "${static_zip_path}" \
  "${dynamic_xcframework_path}" "${dynamic_zip_path}" \
  "${legacy_checksum_path}" "${universal_dir}"
mkdir -p "${dist_dir}"
mkdir -p "${universal_dir}/static/lib" "${universal_dir}/dynamic/lib"

rsync -a --delete "${arm64_static_headers}/" "${static_universal_headers}/"
lipo -create "${arm64_static_lib}" "${x86_64_static_lib}" -output "${static_universal_lib}"

xcodebuild -create-xcframework \
  -library "${static_universal_lib}" \
  -headers "${static_universal_headers}" \
  -output "${static_xcframework_path}"

rsync -a --delete "${arm64_dynamic_headers}/" "${dynamic_universal_headers}/"
lipo -create "${arm64_dynamic_lib}" "${x86_64_dynamic_lib}" -output "${dynamic_universal_lib}"
install_name_tool -id "@rpath/librime.dylib" "${dynamic_universal_lib}"

xcodebuild -create-xcframework \
  -library "${dynamic_universal_lib}" \
  -headers "${dynamic_universal_headers}" \
  -output "${dynamic_xcframework_path}"

(
  cd "${dist_dir}"
  ditto -c -k --sequesterRsrc --keepParent "librime.xcframework" "librime.xcframework.zip"
  ditto -c -k --sequesterRsrc --keepParent "librime-dynamic.xcframework" "librime-dynamic.xcframework.zip"
)

"${script_dir}/write-build-metadata.sh" "${dist_dir}/build-metadata.json"

printf 'packaged %s\n' "${static_zip_path}"
printf 'packaged %s\n' "${dynamic_zip_path}"
