#!/usr/bin/env bash
#
# Runs the container-inspector tests against synthetic samples. No Xcode
# needed; it reuses the same Command Line Tools workaround as
# build-batch-app.sh and compiles only the files the inspector needs.
#
#   ./scripts/test-inspector.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${ROOT}/build"
WORK="${BUILD}/inspector-tests"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
CLT="/Library/Developer/CommandLineTools"

prepare_overlay() {
  local dir="${BUILD}/swift-resource"
  [[ -d "${dir}/include/swift" && -e "${dir}/macosx" ]] && return
  rm -rf "${dir}"
  mkdir -p "${dir}/include/swift"
  cp "${CLT}/usr/include/swift/bridging" "${dir}/include/swift/"
  cp "${CLT}/usr/include/swift/bridging.modulemap" "${dir}/include/swift/"
  ln -sfn "${CLT}/usr/lib" "${dir}/lib"
  [[ -d "${CLT}/usr/lib/clang/16" ]] && ln -sfn "${CLT}/usr/lib/clang/16" "${dir}/clang"
  ln -sfn "${CLT}/usr/lib/swift/macosx" "${dir}/macosx"
}

prepare_overlay
mkdir -p "${WORK}"

echo "==> Generating synthetic samples"
python3 "${ROOT}/tests/make_samples.py" "${WORK}/samples" >/dev/null

echo "==> Compiling inspector tests"
swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macos12.0" \
  -sdk "${SDK}" -resource-dir "${BUILD}/swift-resource" \
  "${ROOT}/app/SwitchMTP/Models/"*.swift \
  "${ROOT}/app/SwitchMTP/Services/PackageInspector.swift" \
  "${ROOT}/app/SwitchMTP/Services/DeepVerifier.swift" \
  "${ROOT}/app/SwitchMTP/Services/NSZUnpacker.swift" \
  "${ROOT}/tests/InspectorTests.swift" \
  -o "${WORK}/inspector-tests"

echo "==> Running"
"${WORK}/inspector-tests" "${WORK}/samples"
