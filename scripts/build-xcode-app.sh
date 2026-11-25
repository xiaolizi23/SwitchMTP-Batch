#!/usr/bin/env bash
#
# Standard build: XcodeGen generates the project, xcodebuild produces a
# universal Release bundle, and the result is copied into build/products.
#
# Prefer this over scripts/build-batch-app.sh when Xcode is installed. The
# swiftc path stays as a fallback for Command Line Tools-only machines; it
# cannot compile the asset catalogue, so the settings favicon is missing there.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT}/app"
BUILD="${ROOT}/build"
PRODUCTS="${BUILD}/products"
DERIVED="${BUILD}/xcode-derived"
STAGE="${BUILD}/xcode-products"
PRODUCT="${STAGE}/SwitchMTPBatch.app"
DEST="${PRODUCTS}/SwitchMTP Batch.app"

info() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v xcodebuild >/dev/null || die "xcodebuild not found; install Xcode"
command -v xcodegen >/dev/null || die "xcodegen not found; install with: brew install xcodegen"

if [[ ! -f "${ROOT}/backend/build/nxmtp.dylib" ]]; then
  info "Building backend"
  "${ROOT}/scripts/build-backend.sh"
fi

info "Generating Xcode project"
(cd "${APP_DIR}" && xcodegen generate >/dev/null)

rm -rf "${STAGE}" "${DERIVED}"
mkdir -p "${STAGE}" "${PRODUCTS}"

info "Building Release (arm64 + x86_64)"
xcodebuild \
  -project "${APP_DIR}/SwitchMTPBatch.xcodeproj" \
  -scheme SwitchMTP \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "${DERIVED}" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CONFIGURATION_BUILD_DIR="${STAGE}" \
  build > "${BUILD}/xcodebuild.log" 2>&1 || {
    tail -40 "${BUILD}/xcodebuild.log" >&2
    die "xcodebuild failed (full log: ${BUILD}/xcodebuild.log)"
  }

[[ -d "${PRODUCT}" ]] || die "expected bundle missing: ${PRODUCT}"

info "Installing into ${DEST}"
rm -rf "${DEST}"
ditto "${PRODUCT}" "${DEST}"

info "Verifying"
lipo -info "${DEST}/Contents/MacOS/SwitchMTPBatch"
codesign --verify --deep --strict "${DEST}"
"${DEST}/Contents/Resources/bin/hactool" 2>&1 | head -2

info "Done: ${DEST}"
