#!/bin/zsh
set -euo pipefail

task_root=${0:A:h:h}
task_app="$task_root/dist/JioJoin for Mac.app"
task_macos="$task_app/Contents/MacOS"
task_frameworks="$task_app/Contents/Frameworks"
task_resources="$task_app/Contents/Resources"
task_engine=$(find "$task_root/vendor/pjproject/pjsip-apps/bin/samples" -type f -name jiojoin_engine -perm +111 | head -1)
task_swift="$task_root/.build/arm64-apple-macosx/release/JioJoinMac"

if [[ -z "$task_engine" || ! -x "$task_swift" ]]; then
  print -u2 "Build outputs are missing; run Scripts/build.sh first."
  exit 2
fi

if [[ "$task_app" != "$task_root/dist/JioJoin for Mac.app" ]]; then
  print -u2 "Refusing unexpected package destination."
  exit 3
fi
/bin/rm -rf -- "$task_app"
mkdir -p "$task_macos" "$task_frameworks" "$task_resources/Licenses"
cp "$task_swift" "$task_macos/JioJoinMac"
cp "$task_engine" "$task_macos/jiojoin-engine"
cp "$task_root/App/Info.plist" "$task_app/Contents/Info.plist"
cp "$task_root/App/JioJoinMac.icns" "$task_resources/JioJoinMac.icns"
cp "$task_root/LICENSE.md" "$task_resources/Licenses/JioJoinMac-LICENSE.md"
cp "$task_root/vendor/pjproject/COPYING" "$task_resources/Licenses/pjproject-COPYING"

task_libraries=(
  /opt/homebrew/opt/openssl@3/lib/libssl.3.dylib
  /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib
  /opt/homebrew/opt/opencore-amr/lib/libopencore-amrnb.0.dylib
  /opt/homebrew/opt/opencore-amr/lib/libopencore-amrwb.0.dylib
  /opt/homebrew/opt/vo-amrwbenc/lib/libvo-amrwbenc.0.dylib
)
for task_library in $task_libraries; do
  cp "$task_library" "$task_frameworks/${task_library:t}"
  install_name_tool -id "@rpath/${task_library:t}" "$task_frameworks/${task_library:t}"
done

install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libssl.3.dylib @rpath/libssl.3.dylib "$task_macos/jiojoin-engine"
install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib @rpath/libcrypto.3.dylib "$task_macos/jiojoin-engine"
install_name_tool -change /opt/homebrew/opt/opencore-amr/lib/libopencore-amrnb.0.dylib @rpath/libopencore-amrnb.0.dylib "$task_macos/jiojoin-engine"
install_name_tool -change /opt/homebrew/opt/opencore-amr/lib/libopencore-amrwb.0.dylib @rpath/libopencore-amrwb.0.dylib "$task_macos/jiojoin-engine"
install_name_tool -change /opt/homebrew/opt/vo-amrwbenc/lib/libvo-amrwbenc.0.dylib @rpath/libvo-amrwbenc.0.dylib "$task_macos/jiojoin-engine"
install_name_tool -add_rpath @executable_path/../Frameworks "$task_macos/jiojoin-engine"
task_ssl_crypto=$(otool -L "$task_frameworks/libssl.3.dylib" | awk '/libcrypto\.3\.dylib/{print $1; exit}')
install_name_tool -change "$task_ssl_crypto" @rpath/libcrypto.3.dylib "$task_frameworks/libssl.3.dylib"

for task_binary in "$task_frameworks"/*.dylib "$task_macos/jiojoin-engine"; do
  codesign --force --sign - "$task_binary"
done
codesign --force --deep --sign - --entitlements "$task_root/App/JioJoinMac.entitlements" "$task_app"
print "$task_app"
