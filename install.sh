#!/usr/bin/env bash
# Install the Zigbee bridge onto a LifeSmart Nature 7 Pro hub.
# Run from a host machine; targets the hub via ADB-over-TCP at $TARGET.
set -euo pipefail

TARGET="${1:-192.168.0.180:5555}"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "[*] Connecting to $TARGET"
adb connect "$TARGET" >/dev/null
adb -s "$TARGET" root >/dev/null
sleep 1
adb -s "$TARGET" remount >/dev/null

echo "[*] Backing up original /vendor/bin/lifesmart_check.sh -> /data/local/tmp/lifesmart_check.sh.orig"
adb -s "$TARGET" shell '[ -f /data/local/tmp/lifesmart_check.sh.orig ] || cp /vendor/bin/lifesmart_check.sh /data/local/tmp/lifesmart_check.sh.orig'

echo "[*] Pushing zb_bridge.lua"
adb -s "$TARGET" push "$HERE/zb_bridge.lua" /data/local/tmp/zb_bridge.lua >/dev/null
adb -s "$TARGET" shell 'chmod 0755 /data/local/tmp/zb_bridge.lua'

echo "[*] Pushing lifesmart_check.sh"
adb -s "$TARGET" push "$HERE/lifesmart_check.sh" /data/local/tmp/lifesmart_check.sh >/dev/null
adb -s "$TARGET" shell 'cp /data/local/tmp/lifesmart_check.sh /vendor/bin/lifesmart_check.sh && chmod 0755 /vendor/bin/lifesmart_check.sh && chcon u:object_r:vendor_file:s0 /vendor/bin/lifesmart_check.sh'

echo "[*] Done. Reboot the hub to pick up the new boot script:"
echo "    adb -s $TARGET reboot"
echo
echo "After reboot, point zigbee2mqtt at:"
echo "  serial:"
echo "    adapter: ember"
echo "    port: tcp://${TARGET%:*}:8880"
