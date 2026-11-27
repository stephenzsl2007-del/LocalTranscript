#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
build="${LOCAL_TRANSCRIPT_BUILD_DIR:-$root/work/build}"
app="$root/LocalTranscript.app"
if [[ ! -f Vendor/whisper.cpp/CMakeLists.txt ]]; then ./Scripts/bootstrap.sh; fi
cmake -S Vendor/whisper.cpp -B "$build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
cmake --build "$build" --config Release -j 6
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$root/work/swift-cache"
xcrun clang++ -std=c++17 -O3 -mmacosx-version-min=14.0 -I Vendor/whisper.cpp/include -I Vendor/whisper.cpp/ggml/include -c Engine/Bridge.cpp -o "$build/Bridge.o"
libs=()
while IFS= read -r lib; do libs+=("$lib"); done < <(find "$build" -name '*.a' | sort)
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 -module-cache-path "$root/work/swift-cache" -import-objc-header Engine/Bridge.h Sources/*.swift "$build/Bridge.o" "${libs[@]}" -lc++ -framework Accelerate -framework Metal -framework MetalKit -framework AVFoundation -framework AppKit -framework SwiftUI -framework SystemConfiguration -o "$app/Contents/MacOS/LocalTranscript"
xcrun swift -module-cache-path "$root/work/swift-cache" Scripts/generate-icon.swift "$root" "$build"
xcrun iconutil -c icns "$build/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
cp Brand/LocalTranscript-mark-white.png "$app/Contents/Resources/LocalTranscriptMark.png"
cp Info.plist "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources/Licenses"
cp Licenses/*.txt "$app/Contents/Resources/Licenses/"
cp LICENSE "$app/Contents/Resources/Licenses/LocalTranscript-MIT.txt"
# Keep the app self-contained without a second 466 MiB copy on this volume.
if [[ -f Models/ggml-small.bin ]]; then
    if [[ ! -f "$app/Contents/Resources/ggml-small.bin" ]] || ! cmp -s Models/ggml-small.bin "$app/Contents/Resources/ggml-small.bin"; then
        rm -f "$app/Contents/Resources/ggml-small.bin"
        ln Models/ggml-small.bin "$app/Contents/Resources/ggml-small.bin" 2>/dev/null || cp Models/ggml-small.bin "$app/Contents/Resources/ggml-small.bin"
    fi
fi
codesign --force --deep --sign - --identifier local.localtranscript.app "$app"
printf '\nBuilt: %s\n' "$app"
