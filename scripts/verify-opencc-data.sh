#!/usr/bin/env bash
set -euo pipefail

# Verifies the OpenCC data this repository commits under Sources/RimeOpenCCData,
# without building anything. The manifest.json the build's collection step
# writes states the opencc version and a sha256 per file, and this re-hashes the
# committed copies against it.
#
# Nothing else checks that the committed data is intact: the files are binary
# dictionaries no compiler reads, so a corrupted or hand-edited copy would ship
# and only fail at a consumer's runtime, as a simplifier that cannot load its
# config.
#
# usage: verify-opencc-data.sh [target-dir]

target_dir="${1:-}"
if [[ -z "${target_dir}" ]]; then
  target_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Sources/RimeOpenCCData"
fi
if [[ ! -f "${target_dir}/manifest.json" ]]; then
  printf 'no manifest at %s; run the build that collects the data first\n' \
    "${target_dir}/manifest.json" >&2
  exit 1
fi
if [[ ! -d "${target_dir}/opencc" ]]; then
  printf 'no data directory at %s\n' "${target_dir}/opencc" >&2
  exit 1
fi

python3 - "${target_dir}" <<'PY'
import hashlib
import json
import os
import sys

target = sys.argv[1]
try:
    with open(os.path.join(target, "manifest.json"), encoding="utf-8") as f:
        manifest = json.load(f)
except (OSError, ValueError) as e:
    sys.exit(f"manifest.json is not readable JSON: {e}")

version = manifest.get("opencc_version")
files = manifest.get("files")
if not isinstance(version, str) or not version:
    sys.exit("manifest.json states no opencc_version")
if not isinstance(files, dict) or not files:
    sys.exit("manifest.json lists no files")

data_dir = os.path.join(target, "opencc")
committed = sorted(
    name for name in os.listdir(data_dir)
    if os.path.isfile(os.path.join(data_dir, name))
)
# A directory under opencc/ would ship with the .copy resource yet be invisible
# to the per-file comparison below, so its presence is always a disagreement.
subdirectories = sorted(
    name for name in os.listdir(data_dir)
    if os.path.isdir(os.path.join(data_dir, name))
)
if subdirectories:
    sys.exit(f"unexpected directories under opencc/: {subdirectories}")
expected = sorted(files)
if committed != expected:
    missing = sorted(set(expected) - set(committed))
    extra = sorted(set(committed) - set(expected))
    sys.exit(f"manifest and data directory disagree; missing: {missing}; unexpected: {extra}")

for name in expected:
    with open(os.path.join(data_dir, name), "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    if digest != files[name]:
        sys.exit(f"{name} does not match its manifest checksum")

if not any(name.endswith(".ocd2") for name in expected):
    sys.exit("no compiled dictionary (*.ocd2) in the committed data")
if not any(name.endswith(".json") for name in expected):
    sys.exit("no conversion config (*.json) in the committed data")

print(f"verified {len(expected)} committed opencc data files (opencc {version})")
PY
