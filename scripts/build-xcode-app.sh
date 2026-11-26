#!/usr/bin/env bash
#
# Standard build: XcodeGen generates the project, xcodebuild produces a
# universal Release bundle, and the result is copied into build/products.
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

# Build the headless CLI as a universal binary and bundle it next to hactool /
# nszunpack in Contents/Resources/bin. It reuses the host's nxmtp/libusb dylibs
# in Contents/Frameworks via the @executable_path/../../Frameworks rpath; no
# dylib copy is placed beside the CLI.
CLI_STAGE="${BUILD}/cli-release"
info "Building Release CLI (arm64 + x86_64)"
rm -rf "${CLI_STAGE}"
xcodebuild \
  -project "${APP_DIR}/SwitchMTPBatch.xcodeproj" \
  -scheme switchmtp-cli \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "${BUILD}/cli-release-derived" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CONFIGURATION_BUILD_DIR="${CLI_STAGE}" \
  build > "${BUILD}/xcodebuild-cli.log" 2>&1 || {
    tail -40 "${BUILD}/xcodebuild-cli.log" >&2
    die "CLI xcodebuild failed (full log: ${BUILD}/xcodebuild-cli.log)"
  }
[[ -f "${CLI_STAGE}/switchmtp-cli" ]] || die "expected CLI binary missing: ${CLI_STAGE}/switchmtp-cli"
mkdir -p "${PRODUCT}/Contents/Resources/bin"
cp -f "${CLI_STAGE}/switchmtp-cli" "${PRODUCT}/Contents/Resources/bin/switchmtp-cli"
chmod +x "${PRODUCT}/Contents/Resources/bin/switchmtp-cli"

# Sign the CLI with its own non-sandbox entitlements, then re-sign the host app
# so its CodeResources manifest picks up the newly added binary. --deep is
# avoided: it would re-sign the CLI with the app's entitlements.
codesign --force --sign - --timestamp=none --options runtime \
  --entitlements "${APP_DIR}/Resources/switchmtp-cli.entitlements" \
  "${PRODUCT}/Contents/Resources/bin/switchmtp-cli"
codesign --force --sign - --timestamp=none \
  --entitlements "${APP_DIR}/Resources/SwitchMTPBatch.entitlements" \
  "${PRODUCT}"

info "Installing into ${DEST}"
rm -rf "${DEST}"
ditto "${PRODUCT}" "${DEST}"

info "Verifying"
lipo -info "${DEST}/Contents/MacOS/SwitchMTPBatch"
lipo -info "${DEST}/Contents/Resources/bin/switchmtp-cli"
codesign --verify --deep --strict "${DEST}"
"${DEST}/Contents/Resources/bin/hactool" 2>&1 | head -2
"${DEST}/Contents/Resources/bin/switchmtp-cli" version

info "Done: ${DEST}"
