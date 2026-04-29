#!/usr/bin/env bash
# Restore the LifeSmart Nature 7 Pro to its original behavior.
set -euo pipefail

TARGET="${1:-192.168.0.180:5555}"

echo "[*] Connecting to $TARGET"
adb connect "$TARGET" >/dev/null
adb -s "$TARGET" root >/dev/null
sleep 1
adb -s "$TARGET" remount >/dev/null

echo "[*] Restoring original /vendor/bin/lifesmart_check.sh"
adb -s "$TARGET" shell 'cp /data/local/tmp/lifesmart_check.sh.orig /vendor/bin/lifesmart_check.sh && chmod 0755 /vendor/bin/lifesmart_check.sh && chcon u:object_r:vendor_file:s0 /vendor/bin/lifesmart_check.sh'

echo "[*] Removing bridge files"
adb -s "$TARGET" shell 'rm -f /data/local/tmp/zb_bridge.lua /data/local/tmp/zb_bridge.log /data/local/tmp/natureinitrd.log'

echo "[*] Done. Reboot to return to stock LifeSmart:"
echo "    adb -s $TARGET reboot"
