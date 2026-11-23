#!/bin/bash
set -euo pipefail

if [[ $# -gt 1 || ${1:-} == --help || ${1:-} == -h ]]; then
    echo "Usage: $0 [destination-directory]"
    echo "Defaults to the build directory next to this script."
    if [[ $# -gt 1 ]]; then exit 2; fi
    exit 0
fi

root="$(cd "$(dirname "$0")" && pwd -P)"
dest="${1:-$root/build}"
sources=("$root"/Sources/VoxelStudio/*.swift)
sdk="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$dest"
dest="$(cd "$dest" && pwd -P)"
app="$dest/Forma.app"

if [[ -L "$app" || ( -e "$app" && "$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)" != studio.forma.voxel ) ]]; then
    echo "A different item named Forma.app already exists in the destination directory." >&2
    exit 1
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/forma-build.XXXXXX")"
stage=""
cleanup() {
    if [[ -n "$stage" ]]; then rm -rf "$stage"; fi
    rm -rf "$scratch"
}
trap cleanup EXIT
stage="$(mktemp -d "$dest/.forma-stage.XXXXXX")"
contents="$stage/Forma.app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
install -m 644 "$root/Resources/Info.plist" "$contents/Info.plist"
install -m 644 "$root/Resources/AppIcon.icns" "$contents/Resources/AppIcon.icns"
plutil -lint "$contents/Info.plist" >/dev/null

for arch in arm64 x86_64; do
    echo "Building Forma ($arch)…"
    xcrun --sdk macosx swiftc \
        -swift-version 5 -parse-as-library -O -whole-module-optimization \
        -module-name VoxelStudio -module-cache-path "$scratch/cache" \
        -target "$arch-apple-macosx13.0" -sdk "$sdk" \
        "${sources[@]}" -o "$scratch/Forma-$arch"
done

xcrun lipo -create "$scratch/Forma-arm64" "$scratch/Forma-x86_64" -output "$contents/MacOS/Forma"
for arch in arm64 x86_64; do
    xcrun lipo "$contents/MacOS/Forma" -verify_arch "$arch"
done
chmod 755 "$contents/MacOS/Forma"
codesign --force --sign - --timestamp=none "$stage/Forma.app"
codesign --verify --deep --strict "$stage/Forma.app"

# Both bundles are on the destination volume. Swap in the verified build atomically.
xcrun --sdk macosx swift -module-cache-path "$scratch/cache" - "$stage/Forma.app" "$app" <<'SWIFT'
import Darwin
import Foundation

let source = CommandLine.arguments[1]
let destination = CommandLine.arguments[2]
let exists = FileManager.default.fileExists(atPath: destination)
let flag = UInt32(exists ? RENAME_SWAP : RENAME_EXCL)
guard renamex_np(source, destination, flag) == 0 else {
    perror("Forma.app")
    exit(1)
}
SWIFT
echo "Built: $app"
