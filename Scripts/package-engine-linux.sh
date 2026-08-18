#!/usr/bin/env bash
set -euo pipefail

task_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
task_arch=$(uname -m)
task_engine="$task_root/build/headless/linux-$task_arch/jiojoin-engine"
task_stage="$task_root/build/headless/package-linux-$task_arch"
task_archive="$task_root/dist/jiojoin-engine-0.8.0-linux-$task_arch.tar.gz"

[[ $(uname -s) == Linux ]] || { echo "Linux is required." >&2; exit 2; }
[[ -x "$task_engine" ]] || { echo "Run Scripts/build-engine-linux.sh first." >&2; exit 3; }
[[ "$task_stage" == "$task_root/build/headless/package-linux-$task_arch" ]] || exit 4

/bin/rm -rf -- "$task_stage"
mkdir -p "$task_stage"
cp "$task_engine" "$task_stage/jiojoin-engine"
cp "$task_root/linux/jiojoin_controller.py" "$task_stage/jiojoin-controller"
cp "$task_root/LICENSE.md" "$task_stage/LICENSE.md"
cp "$task_root/vendor/pjproject/COPYING" "$task_stage/pjproject-COPYING"
cp "$task_root/docs/ENGINE_PROTOCOL.md" "$task_stage/ENGINE_PROTOCOL.md"
cp "$task_root/docs/LINUX_HEADLESS.md" "$task_stage/LINUX_HEADLESS.md"
chmod 755 "$task_stage/jiojoin-controller"
ldd "$task_stage/jiojoin-engine" > "$task_stage/runtime-libraries.txt"
tar -C "$task_stage" -czf "$task_archive" .
echo "$task_archive"
