#!/usr/bin/env bash
set -euo pipefail

# Build one platform slice of the RimeDynamic linker stub: a framework that
# satisfies the symbols of the real librime dylib while carrying the *real*
# framework's install name, so a client that links it records a load command for
# @rpath/RimeDynamic.framework/... and loads the app's single embedded copy.
#
# Why a Mach-O and not a .tbd: xpc-service targets make Xcode parse the framework
# binary while building the task graph, and a text-based stub is not a Mach-O, so
# the build fails before the linker ever runs (SWBUtil.BinaryReaderError). A
# real, if empty, dylib is what makes a link-only handle usable there.
#
# usage: build-linker-stub.sh <macos|ios|ios-simulator> <real-dylib|tbd> <output-framework>
#
# The input is a real dylib wherever one exists, and the release pipeline always
# has them. A tbd is accepted too: it is tapi's own description of a dylib and
# carries everything the stub mirrors (install name, per-target exports,
# deployment target, current version), which is what lets a slice be rebuilt on a
# machine that cannot build that platform.

if [[ $# -ne 3 ]]; then
  printf 'usage: %s <macos|ios|ios-simulator> <real-dylib|tbd> <output-framework>\n' "$0" >&2
  exit 2
fi

platform="$1"
input_path="$2"
output_framework="$3"

framework_name="RimeDynamicStub"

case "${platform}" in
  macos) sdk_name="macosx" ;;
  ios) sdk_name="iphoneos" ;;
  ios-simulator) sdk_name="iphonesimulator" ;;
  *)
    printf 'unknown platform: %s\n' "${platform}" >&2
    exit 2
    ;;
esac

if [[ ! -f "${input_path}" ]]; then
  printf 'missing input: %s\n' "${input_path}" >&2
  exit 1
fi

scratch_dir="$(mktemp -d)"
trap 'rm -rf "${scratch_dir}"' EXIT

real_dylib=""
case "${input_path}" in
  *.tbd)
    tbd_path="${input_path}"
    ;;
  *)
    # tapi writes the tbd next to its input, so stub from a copy and keep the
    # input directory untouched.
    real_dylib="${input_path}"
    cp "${real_dylib}" "${scratch_dir}/RimeDynamic"
    (cd "${scratch_dir}" && xcrun tapi stubify RimeDynamic)
    tbd_path="${scratch_dir}/RimeDynamic.tbd"
    ;;
esac

# Everything the stub mirrors is read from the input rather than assumed.
# Written to a file rather than a heredoc inside $(...): bash scans a command
# substitution for its closing paren before it parses the heredoc, and Python
# punctuation such as quotes and brackets derails that scan.
cat > "${scratch_dir}/describe.py" <<'PY'
import json, re, subprocess, sys

tbd_path, dylib = sys.argv[1], sys.argv[2]
main = json.load(open(tbd_path))["main_library"]

install_names = main["install_names"]
if len(install_names) != 1:
    sys.exit(f"expected exactly one install name, got {install_names}")

targets = [t["target"] for t in main["target_info"]]
# A target is <arch>-<platform> and the platform itself contains a dash for the
# simulator (ios-simulator), so the split is on the first dash only.
platforms = {target.split("-", 1)[1] for target in targets}
if len(platforms) != 1:
    sys.exit(f"expected one platform across targets, got {sorted(platforms)}")
platform = platforms.pop()

minimum_os = min(t["min_deployment"] for t in main["target_info"])
current = main["current_versions"][0]["version"]

compatibility = "1.0.0"
if dylib:
    arch = subprocess.run(["lipo", "-archs", dylib],
                          capture_output=True, text=True, check=True).stdout.split()[0]
    otool = subprocess.run(["xcrun", "otool", "-l", "-arch", arch, dylib],
                           capture_output=True, text=True, check=True).stdout
    for line in otool.splitlines():
        match = re.match(r"\s*compatibility version\s+(\S+)", line)
        if match:
            compatibility = match.group(1)
            break

# tapi spells the simulator platform ios-simulator while a clang triple spells it
# <arch>-apple-ios<version>-simulator, and the version sits between them, so the
# clang suffix is assembled here instead of reusing the tbd spelling.
clang_suffix = f"{platform.replace('-simulator', '')}{minimum_os}"
if platform.endswith("-simulator"):
    clang_suffix += "-simulator"

architectures = " ".join(sorted({target.split("-", 1)[0] for target in targets}))
print(install_names[0]["name"], current, compatibility, minimum_os,
      clang_suffix, platform, architectures)
PY

read -r install_name current_version compatibility_version minimum_os \
  target_suffix tbd_platform architectures < <(python3 "${scratch_dir}/describe.py" "${tbd_path}" "${real_dylib}")

case "${platform}" in
  macos) expected_platform="macos" ;;
  ios) expected_platform="ios" ;;
  ios-simulator) expected_platform="ios-simulator" ;;
esac
if [[ "${tbd_platform}" != "${expected_platform}" ]]; then
  printf 'input describes %s but %s was requested\n' "${tbd_platform}" "${platform}" >&2
  exit 1
fi

if [[ -z "${architectures}" ]]; then
  printf 'input %s names no architectures\n' "${tbd_path}" >&2
  exit 1
fi

asm_dir="${scratch_dir}/asm"
mkdir -p "${asm_dir}"
# architectures is a space-separated list; unquoted on purpose so the Python
# helper receives one argument per architecture.
# shellcheck disable=SC2086
python3 - "${tbd_path}" "${asm_dir}" "${tbd_platform}" ${architectures} <<'PY'
import json, os, sys

tbd_path, asm_dir, tbd_platform = sys.argv[1], sys.argv[2], sys.argv[3]
architectures = sys.argv[4:]
sections = json.load(open(tbd_path))["main_library"].get("exported_symbols", [])

for arch in architectures:
    # The tbd names its targets <arch>-<platform>, e.g. arm64-macos,
    # x86_64-ios-simulator: that is what a section's own "targets" list uses.
    target = f"{arch}-{tbd_platform}"
    text_strong, text_weak, data_strong, data_weak, thread_local = [], [], [], [], []
    seen = set()

    def collect(bucket, names):
        for name in names:
            if name not in seen:
                seen.add(name)
                bucket.append(name)

    for section in sections:
        # A section that names its targets belongs to those architectures only.
        if "targets" in section and target not in section["targets"]:
            continue
        if "text" in section:
            collect(text_weak, section["text"].get("weak", []))
            collect(text_strong, section["text"].get("global", []))
        if "data" in section:
            collect(thread_local, section["data"].get("thread_local", []))
            collect(data_weak, section["data"].get("weak", []))
            collect(data_strong, section["data"].get("global", []))

    lines = [".text"]
    for name in text_strong:
        lines += [f".globl {name}", f"{name}:", "  ret"]
    for name in text_weak:
        lines += [f".weak_definition {name}", f".globl {name}", f"{name}:", "  ret"]
    if data_strong or data_weak:
        lines.append(".section __DATA,__data")
        for name in data_strong:
            lines += [f".globl {name}", f"{name}:", "  .quad 0"]
        for name in data_weak:
            lines += [f".weak_definition {name}", f".globl {name}", f"{name}:", "  .quad 0"]
    if thread_local:
        # Thread-local exports keep their storage class: a client referring to
        # one is compiled for a TLS symbol, so plain data would not link.
        lines.append(".section __DATA,__thread_bss")
        for name in thread_local:
            lines += [f".globl {name}", f"{name}:", "  .space 8"]

    total = len(text_strong) + len(text_weak) + len(data_strong) + len(data_weak) + len(thread_local)
    open(os.path.join(asm_dir, f"{arch}.s"), "w").write("\n".join(lines) + "\n")
    print(f"  {target}: {total} exported symbols, {len(text_weak) + len(data_weak)} weak",
          file=sys.stderr)
PY

sdk_path="$(xcrun --sdk "${sdk_name}" --show-sdk-path)"
binary_path="${scratch_dir}/${framework_name}"
slices=()
for arch in ${architectures}; do
  slice_path="${scratch_dir}/${framework_name}-${arch}"
  xcrun clang -dynamiclib \
    -isysroot "${sdk_path}" \
    -arch "${arch}" \
    -target "${arch}-apple-${target_suffix}" \
    -install_name "${install_name}" \
    -current_version "${current_version}" \
    -compatibility_version "${compatibility_version}" \
    -o "${slice_path}" "${asm_dir}/${arch}.s"
  slices+=("${slice_path}")
done
xcrun lipo -create "${slices[@]}" -output "${binary_path}"

rm -rf "${output_framework}"
if [[ "${platform}" == "macos" ]]; then
  # macOS validates embedded frameworks as versioned bundles, so the stub is a
  # deep bundle too and the framework layout matches the real one.
  bundle_root="${output_framework}/Versions/A"
  mkdir -p "${bundle_root}/Resources"
  mv "${binary_path}" "${bundle_root}/${framework_name}"
  ln -sfn "A" "${output_framework}/Versions/Current"
  ln -sfn "Versions/Current/${framework_name}" "${output_framework}/${framework_name}"
  plist_path="${bundle_root}/Resources/Info.plist"
else
  mkdir -p "${output_framework}"
  mv "${binary_path}" "${output_framework}/${framework_name}"
  plist_path="${output_framework}/Info.plist"
fi

# CFBundleExecutable has to name the file that is actually there: Xcode resolves
# the bundle's binary through it, and a bundle whose executable is missing is
# what turns a link-only handle into a build failure.
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
  <string>com.ghostflyby.librime-xcframework.${framework_name}</string>
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
  <string>${minimum_os}</string>
</dict>
</plist>
PLIST

printf 'built %s stub for %s (%s, minOS %s)\n' \
  "${framework_name}" "${platform}" "${architectures}" "${minimum_os}"
