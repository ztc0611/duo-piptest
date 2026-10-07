#!/bin/zsh
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
repo_dir="$(cd -- "$script_dir/.." && pwd -P)"
source_file="$repo_dir/Sources/DuoPiPTest.swift"
info_file="$repo_dir/Resources/Info.plist"
videos_dir="$repo_dir/Resources/Videos"
build_dir="$repo_dir/build"
app="$build_dir/DuoPiPTest.app"

[[ -f "$source_file" ]] || { print -u2 "Missing source: $source_file"; exit 1; }
[[ -f "$info_file" ]] || { print -u2 "Missing Info.plist: $info_file"; exit 1; }
for ratio in 21x9 16x9 4x3 1x1 9x16; do
    video="$videos_dir/gradient-$ratio.mp4"
    [[ -s "$video" ]] || { print -u2 "Missing video asset: $video"; exit 1; }
done

sdk_version="$(xcrun --sdk iphonesimulator --show-sdk-version)"
sdk_major="$(print -r -- "$sdk_version" | cut -d. -f1)"
sdk_minor="$(print -r -- "$sdk_version" | cut -d. -f2)"
if [[ "$sdk_major" != <-> || "$sdk_minor" != <-> ]] ||
   (( sdk_major < 27 || (sdk_major == 27 && sdk_minor < 1) )); then
    print -u2 "iPhone Simulator SDK 27.1 or newer is required; found $sdk_version"
    exit 1
fi
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
plutil -lint "$info_file" >/dev/null

mkdir -p "$build_dir"
scratch="$(mktemp -d "$build_dir/.DuoPiPTest-build.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
staging="$scratch/DuoPiPTest.app"
mkdir -p "$staging"
cp "$info_file" "$staging/Info.plist"
for ratio in 21x9 16x9 4x3 1x1 9x16; do
    cp "$videos_dir/gradient-$ratio.mp4" "$staging/gradient-$ratio.mp4"
done

xcrun --sdk iphonesimulator swiftc \
    -parse-as-library \
    -target arm64-apple-ios27.1-simulator \
    -sdk "$sdk" \
    -module-cache-path "$scratch/ModuleCache" \
    -o "$staging/DuoPiPTest" \
    "$source_file"

codesign --force --sign - "$staging"
codesign --verify --deep --strict --verbose=2 "$staging"
rm -rf "$app"
mv "$staging" "$app"
print "Built and signed $app with five video aspect ratios."
