#!/bin/zsh
set -euo pipefail

task_root=${0:A:h:h}
task_app="$task_root/dist/JioJoin for Mac.app"
task_engine="$task_app/Contents/MacOS/jiojoin-engine"

swift test --package-path "$task_root"
"$task_root/Scripts/test-engine-protocol.sh" "$task_engine"
codesign --verify --deep --strict --verbose=2 "$task_app"
plutil -lint "$task_app/Contents/Info.plist"
[[ -f "$task_app/Contents/Resources/JioJoinMac.icns" ]]
[[ ! -d "$task_app/Contents/Resources/AgentBridge" ]]
[[ $(find "$task_app/Contents/Frameworks" -maxdepth 1 -type f -name '*.dylib' | wc -l | tr -d ' ') == 5 ]]
[[ ! -e "$task_app/Contents/Frameworks/libopus.0.dylib" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$task_app/Contents/Info.plist")" == "true" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$task_app/Contents/Info.plist")" == "JioJoinMac.icns" ]]

task_ready=$(printf 'PING\nSTATUS\nQUIT\n' | "$task_engine")
[[ "$task_ready" == *'no network registration has started'* ]]
[[ "$task_ready" == *'"event":"pong"'* ]]
[[ "$task_ready" == *'"event":"status"'* ]]
[[ "$task_ready" == *'"registered":false'* ]]
[[ "$task_ready" == *'"active_call":false'* ]]

task_self_test=$("$task_engine" --self-test 2>"$task_root/dist/self-test.stderr")
[[ "$task_self_test" == *'"tls":true'* ]]
[[ "$task_self_test" == *'"amr":true'* ]]
[[ "$task_self_test" == *'"amr_wb":true'* ]]

if find "$task_app" -type f \( -name '*.mp3' -o -name '*.wav' \) | grep -q .; then
  print -u2 "Packaged app unexpectedly contains recording or soundboard audio."
  exit 3
fi

if otool -L "$task_engine" | grep -q /opt/homebrew; then
  print -u2 "Packaged engine still links to Homebrew."
  exit 2
fi

print "$task_self_test"
print "verification=passed"
