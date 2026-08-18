#!/usr/bin/env bash
set -euo pipefail

task_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
task_arch=$(uname -m)
task_engine="$task_root/build/headless/linux-$task_arch/jiojoin-engine"
task_build="$task_root/build/linux-desktop"
task_dist="$task_build/dist"

[[ $(uname -s) == Linux ]] || { echo "Linux is required." >&2; exit 2; }
[[ -x "$task_engine" ]] || { echo "Run Scripts/build-engine-linux.sh first." >&2; exit 3; }
command -v pyinstaller >/dev/null || {
  echo "PyInstaller is required only on the release build host." >&2
  exit 4
}

/bin/rm -rf -- "$task_build"
mkdir -p "$task_build"
pyinstaller \
  --noconfirm \
  --clean \
  --onedir \
  --name jiojoin-desktop \
  --paths "$task_root/linux" \
  --distpath "$task_dist" \
  --workpath "$task_build/work" \
  --specpath "$task_build" \
  "$task_root/linux/jiojoin_desktop.py"
cp "$task_engine" "$task_dist/jiojoin-desktop/jiojoin-engine"
chmod 755 "$task_dist/jiojoin-desktop/jiojoin-desktop" "$task_dist/jiojoin-desktop/jiojoin-engine"
"$task_dist/jiojoin-desktop/jiojoin-engine" --version
echo "$task_dist/jiojoin-desktop"
