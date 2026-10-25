#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${FRIJA_BUILD_DIR:-$project_dir/.build}"
dist_dir="${FRIJA_DIST_DIR:-$project_dir/dist}"
module_dir="$build_dir/module-cache"
mkdir -p "$module_dir" "$dist_dir"
export CLANG_MODULE_CACHE_PATH="$module_dir"
for arch in arm64 x86_64; do
    swift build --package-path "$project_dir" --scratch-path "$build_dir/$arch" \
        --build-system native --disable-sandbox -c release --triple "$arch-apple-macosx14.0" \
        -Xswiftc -module-cache-path -Xswiftc "$module_dir"
done
stage="$(mktemp -d "${TMPDIR:-/tmp}/frija-mac.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/Frija Mac.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
arm_bin="$(swift build --package-path "$project_dir" --scratch-path "$build_dir/arm64" --build-system native --disable-sandbox -c release --triple arm64-apple-macosx14.0 --show-bin-path)"
intel_bin="$(swift build --package-path "$project_dir" --scratch-path "$build_dir/x86_64" --build-system native --disable-sandbox -c release --triple x86_64-apple-macosx14.0 --show-bin-path)"
lipo -create "$arm_bin/FrijaMac" "$intel_bin/FrijaMac" -output "$app/Contents/MacOS/FrijaMac"
lipo -create "$arm_bin/frija" "$intel_bin/frija" -output "$dist_dir/frija"
cp "$project_dir/scripts/Info.plist" "$app/Contents/Info.plist"
cp "$project_dir/NOTICE" "$project_dir/README.md" "$app/Contents/Resources/"
cp -R "$project_dir/Licenses" "$app/Contents/Resources/"
swift -module-cache-path "$module_dir" "$project_dir/scripts/Icon.swift" "$build_dir/AppIcon.iconset"
cp "$build_dir/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
# Strip Finder-only metadata from our generated bundle before signing.
xattr -r -d com.apple.FinderInfo "$app" 2>/dev/null || true
xattr -r -d com.apple.ResourceFork "$app" 2>/dev/null || true
codesign --force --sign - "$app"
codesign --force --sign - "$dist_dir/frija"
codesign --verify --deep --strict "$app"
ditto -c -k --norsrc --noextattr --keepParent "$app" "$dist_dir/Frija-Mac-0.2.0-universal.zip"
printf 'Built %s\n' "$dist_dir/Frija-Mac-0.2.0-universal.zip"
