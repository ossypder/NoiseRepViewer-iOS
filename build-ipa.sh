#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT
xcodebuild -project NoiseRepViewer.xcodeproj -target NoiseRepViewer \
  -configuration Release -sdk iphoneos -derivedDataPath "$build_dir/build" \
  CODE_SIGNING_ALLOWED=NO build
mkdir -p "$build_dir/ipa/Payload"
cp -R "$build_dir/build/Build/Products/Release-iphoneos/NoiseRepViewer.app" "$build_dir/ipa/Payload/"
(cd "$build_dir/ipa" && zip -qry "$OLDPWD/NoiseRepViewer-AltStore.ipa" Payload)
echo "Created NoiseRepViewer-AltStore.ipa"
