#!/bin/zsh
set -euo pipefail

task_root=${0:A:h:h}
"$task_root/Scripts/build-engine-macos.sh"
swift test
swift build -c release
"$task_root/Scripts/package.sh"
