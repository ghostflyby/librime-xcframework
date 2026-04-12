#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${script_dir}/build-one-arch.sh" arm64
"${script_dir}/build-one-arch.sh" x86_64
"${script_dir}/package-xcframework.sh"

