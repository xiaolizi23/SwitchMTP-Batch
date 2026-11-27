#!/usr/bin/env bash
#
# Packages the built universal (or single-arch) app bundle into a compressed
# read-only DMG for release. The DMG root holds the app beside an /Applications
# symlink, the classic drag-to-install layout. No background image or custom
# icon layout -- the plain hdiutil output matches the upstream SwiftMTP DMG.
#
# Usage:
#   scripts/package-dmg.sh [path/to/App.app]
#
# Output (next to build/):
#   build/SwitchMTP-Batch-<version>-<arch>.dmg
#   build/SwitchMTP-Batch-<version>-<arch>.dmg.sha256
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${ROOT}/build"
APP="${1:-${BUILD}/products/SwitchMTP Batch.app}"
PLIST="${APP}/Contents/Info.plist"
DMG_ROOT="${BUILD}/dmg-root"
MOUNT="${BUILD}/dmg-mount"

info() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v hdiutil >/dev/null 2>&1 || die "hdiutil is not installed."
command -v codesign >/dev/null 2>&1 || die "codesign is not installed."
[[ -d "${APP}" ]] || die "app bundle not found: ${APP}. Run scripts/build-xcode-app.sh first."
[[ -f "${PLIST}" ]] || die "Info.plist not found: ${PLIST}"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLIST}")"
[[ -n "${version}" ]] || die "CFBundleShortVersionString is empty in ${PLIST}"

# Derive the architecture tag from the main executable so the DMG name never
# lies about what is inside (AGENTS: arch must match the real slices).
main_bin="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${PLIST}")"
bin_path="${APP}/Contents/MacOS/${main_bin}"
[[ -f "${bin_path}" ]] || die "main executable missing: ${bin_path}"
slices="$(lipo -info "${bin_path}" | sed -n 's/.*are:\ //p')"
case "${slices}" in
  *arm64*x86_64*|*x86_64*arm64*) arch="universal" ;;
  *arm64*)                        arch="arm64" ;;
  *x86_64*)                       arch="x86_64" ;;
  *) die "could not determine architecture from ${bin_path} (${slices})" ;;
esac

DMG="${BUILD}/SwitchMTP-Batch-${version}-${arch}.dmg"

info "Preparing DMG contents"
rm -rf "${DMG_ROOT}" "${MOUNT}" "${DMG}" "${DMG}.sha256"
mkdir -p "${DMG_ROOT}" "${MOUNT}"
cp -R "${APP}" "${DMG_ROOT}/SwitchMTP Batch.app"
ln -s /Applications "${DMG_ROOT}/Applications"

info "Creating ${DMG}"
hdiutil create \
  -volname "SwitchMTP Batch ${version}" \
  -srcfolder "${DMG_ROOT}" \
  -ov \
  -format UDZO \
  "${DMG}"

info "Writing checksum"
shasum -a 256 "${DMG}" > "${DMG}.sha256"
cat "${DMG}.sha256"

attached=0
cleanup() {
  if (( attached )); then
    hdiutil detach "${MOUNT}" -quiet || true
  fi
  rm -rf "${DMG_ROOT}" "${MOUNT}"
}
trap cleanup EXIT

info "Mounting DMG for verification"
hdiutil attach "${DMG}" -mountpoint "${MOUNT}" -nobrowse -quiet
attached=1

[[ -d "${MOUNT}/SwitchMTP Batch.app" ]] || die "SwitchMTP Batch.app is missing from mounted DMG"
[[ -L "${MOUNT}/Applications" ]] || die "Applications symlink is missing from mounted DMG"
info "Verifying app signature inside DMG"
codesign --verify --deep --strict --verbose=2 "${MOUNT}/SwitchMTP Batch.app"

info "Unmounting DMG"
hdiutil detach "${MOUNT}" -quiet
attached=0

info "Done: ${DMG}"
