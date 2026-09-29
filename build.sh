#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
app="$root/dist/창 가리개.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/Info.plist" "$app/Contents/Info.plist"
cp "$root/WindowShade.icns" "$app/Contents/Resources/WindowShade.icns"
swiftc -O -target arm64-apple-macos14.0 "$root/WindowShade.swift" -o "$app/Contents/MacOS/WindowShade"
codesign --force --sign - --entitlements "$root/WindowShade.entitlements" "$app"
ditto -c -k --keepParent "$app" "$root/dist/WindowShade.zip"
echo "$root/dist/WindowShade.zip"
