#!/usr/bin/env bash
set -euo pipefail

task_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
task_arch=$(dpkg --print-architecture)
task_bundle="$task_root/build/linux-desktop/dist/jiojoin-desktop"
task_stage="$task_root/build/linux-desktop/deb-root"
task_artifact="$task_root/dist/JioJoin-Desktop-0.8.0-linux-$task_arch.deb"

[[ $(uname -s) == Linux ]] || { echo "Linux is required." >&2; exit 2; }
[[ -x "$task_bundle/jiojoin-desktop" && -x "$task_bundle/jiojoin-engine" ]] || {
  echo "Run Scripts/build-linux-desktop.sh first." >&2; exit 3;
}

/bin/rm -rf -- "$task_stage"
mkdir -p \
  "$task_stage/DEBIAN" \
  "$task_stage/opt/jiojoin" \
  "$task_stage/usr/share/applications" \
  "$task_stage/usr/share/doc/jiojoin-desktop" \
  "$(dirname "$task_artifact")"
cp -R "$task_bundle/." "$task_stage/opt/jiojoin/"
cp "$task_root/linux/io.github.pruthvii1.JioJoin.desktop" "$task_stage/usr/share/applications/"
cp "$task_root/LICENSE.md" "$task_stage/usr/share/doc/jiojoin-desktop/copyright"
cp "$task_root/vendor/pjproject/COPYING" "$task_stage/usr/share/doc/jiojoin-desktop/pjproject-COPYING"

cat > "$task_stage/DEBIAN/control" <<EOF
Package: jiojoin-desktop
Version: 0.8.0
Section: net
Priority: optional
Architecture: $task_arch
Maintainer: JioJoin contributors
Depends: curl, libasound2, libssl3, libopencore-amrnb0, libopencore-amrwb0, libvo-amrwbenc0
Description: Unofficial calling-only JioFiberVoice desktop client
 A local desktop controller and native PJSIP engine. Provisioning credentials,
 OTPs, cookies, and SIP passwords are never stored by the application.
EOF
dpkg-deb --root-owner-group --build "$task_stage" "$task_artifact"
dpkg-deb --info "$task_artifact"
echo "$task_artifact"
