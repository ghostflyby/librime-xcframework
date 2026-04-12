#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
out_dir="${OUT_DIR:-${repo_root}/out}"
dist_dir="${DIST_DIR:-${repo_root}/dist}"
xcframework_path="${dist_dir}/librime.xcframework"
zip_path="${dist_dir}/librime.xcframework.zip"
checksum_path="${dist_dir}/librime.xcframework.sha256"

arm64_lib="${out_dir}/macos-arm64/lib/librime.a"
arm64_headers="${out_dir}/macos-arm64/include"
x86_64_lib="${out_dir}/macos-x86_64/lib/librime.a"
x86_64_headers="${out_dir}/macos-x86_64/include"

for path in "${arm64_lib}" "${arm64_headers}" "${x86_64_lib}" "${x86_64_headers}"; do
  if [[ ! -e "${path}" ]]; then
    printf 'missing required build output: %s\n' "${path}" >&2
    exit 1
  fi
done

rm -rf "${xcframework_path}" "${zip_path}" "${checksum_path}"
mkdir -p "${dist_dir}"

xcodebuild -create-xcframework \
  -library "${arm64_lib}" \
  -headers "${arm64_headers}" \
  -library "${x86_64_lib}" \
  -headers "${x86_64_headers}" \
  -output "${xcframework_path}"

(
  cd "${dist_dir}"
  ditto -c -k --sequesterRsrc --keepParent "librime.xcframework" "librime.xcframework.zip"
)

(
  cd "${dist_dir}"
  shasum -a 256 "librime.xcframework.zip" > "librime.xcframework.sha256"
)
"${script_dir}/write-build-metadata.sh" "${dist_dir}/build-metadata.json"

printf 'packaged %s\n' "${zip_path}"
