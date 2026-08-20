#!/usr/bin/env bash
set -euo pipefail
rm -f -- /usr/share/applications/io.github.pruthvii1.JioJoin.desktop
rm -f -- /opt/jiojoin/jiojoin-engine /opt/jiojoin/jiojoin-controller /opt/jiojoin/jiojoin_controller.py /opt/jiojoin/jiojoin-desktop
rmdir /opt/jiojoin 2>/dev/null || true
echo "Removed JioJoin application files. User configuration was preserved."
