#!/usr/bin/env bash
set -euo pipefail
package_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[[ -x "$package_dir/jiojoin-engine" && -f "$package_dir/jiojoin-desktop" ]] || {
  echo "Run this installer from the extracted JioJoin Linux package." >&2; exit 2;
}
install -d -m 755 /opt/jiojoin /usr/share/applications
install -m 755 "$package_dir/jiojoin-engine" /opt/jiojoin/jiojoin-engine
install -m 755 "$package_dir/jiojoin-controller" /opt/jiojoin/jiojoin_controller.py
install -m 755 "$package_dir/jiojoin-desktop" /opt/jiojoin/jiojoin-desktop
install -m 644 "$package_dir/io.github.pruthvii1.JioJoin.desktop" /usr/share/applications/io.github.pruthvii1.JioJoin.desktop
echo "Installed JioJoin Desktop. No credentials were copied."
