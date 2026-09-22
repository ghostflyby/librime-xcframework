#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 6 || $# -gt 7 ]]; then
  printf 'usage: %s <static-url> <static-checksum> <dynamic-url> <dynamic-checksum> <stub-url> <stub-checksum> [output]\n' "$0" >&2
  exit 2
fi

static_artifact_url="$1"
static_checksum="$2"
dynamic_artifact_url="$3"
dynamic_checksum="$4"
stub_artifact_url="$5"
stub_checksum="$6"
output_path="${7:-Package.swift}"

cat > "${output_path}" <<SWIFT
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Librime",
    platforms: [
        .macOS(.v11),
        .iOS(.v15)
    ],
    products: [
        .library(name: "Rime", targets: ["RimeHeaders"]),
        .library(name: "RimeStatic", targets: ["RimeStatic"]),
        .library(name: "RimeDynamic", targets: ["RimeDynamic"]),
        .library(name: "RimeDynamicStub", targets: ["RimeDynamicStub"]),
        .library(name: "RimeSystem", targets: ["RimeSystem"])
    ],
    targets: [
        .systemLibrary(
            name: "RimeHeaders",
            path: "Sources/RimeHeaders/include"
        ),
        .binaryTarget(
            name: "RimeStatic",
            url: "${static_artifact_url}",
            checksum: "${static_checksum}"
        ),
        .binaryTarget(
            name: "RimeDynamic",
            url: "${dynamic_artifact_url}",
            checksum: "${dynamic_checksum}"
        ),
        .binaryTarget(
            name: "RimeDynamicStub",
            url: "${stub_artifact_url}",
            checksum: "${stub_checksum}"
        ),
        .systemLibrary(
            name: "RimeSystem",
            path: "Sources/RimeSystem",
            pkgConfig: "rime"
        )
    ]
)
SWIFT

printf 'wrote Swift package manifest: %s\n' "${output_path}"
