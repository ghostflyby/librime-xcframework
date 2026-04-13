#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 4 || $# -gt 5 ]]; then
  printf 'usage: %s <static-artifact-url> <static-checksum> <dynamic-artifact-url> <dynamic-checksum> [output]\n' "$0" >&2
  exit 2
fi

static_artifact_url="$1"
static_checksum="$2"
dynamic_artifact_url="$3"
dynamic_checksum="$4"
output_path="${5:-Package.swift}"

cat > "${output_path}" <<SWIFT
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Librime",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .library(name: "Rime", targets: ["Rime"]),
        .library(name: "RimeDynamic", targets: ["RimeDynamic"])
    ],
    targets: [
        .binaryTarget(
            name: "Rime",
            url: "${static_artifact_url}",
            checksum: "${static_checksum}"
        ),
        .binaryTarget(
            name: "RimeDynamic",
            url: "${dynamic_artifact_url}",
            checksum: "${dynamic_checksum}"
        )
    ]
)
SWIFT

printf 'wrote Swift package manifest: %s\n' "${output_path}"
