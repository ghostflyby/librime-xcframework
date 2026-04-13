#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  printf 'usage: %s <artifact-url> <checksum> [output]\n' "$0" >&2
  exit 2
fi

artifact_url="$1"
checksum="$2"
output_path="${3:-Package.swift}"

cat > "${output_path}" <<SWIFT
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Librime",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .library(name: "Rime", targets: ["Rime"])
    ],
    targets: [
        .binaryTarget(
            name: "Rime",
            url: "${artifact_url}",
            checksum: "${checksum}"
        )
    ]
)
SWIFT

printf 'wrote Swift package manifest: %s\n' "${output_path}"
