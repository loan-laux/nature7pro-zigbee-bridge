#!/system/bin/sh
# Replacement for /vendor/bin/lifesmart_check.sh
# Boots LifeSmart's stack briefly to wake the EFR32 zigbee chip out of its
# Gecko bootloader, then kills it and runs our TCP-serial bridge for z2m.
#
# To revert: cp /data/local/tmp/lifesmart_check.sh.orig /vendor/bin/lifesmart_check.sh
#
SERIAL=/dev/ttyS5
PORT=8880
WAKE_SECS=12

# Preserve LifeSmart files: restore from /system/vendor/mgaopt.tar.gz if missing.
if [ ! -d /data/mgaopt/ ] || [ ! -d /data/mgaopt/bin ] || [ ! -d /data/mgaopt/xzyq ]; then
  /system/bin/busybox tar -zxvf /system/vendor/mgaopt.tar.gz -C /data/ >/dev/null 2>&1
fi

# Network rule from the original script (preserved as-is)
ip rule add from all lookup main pref 9999 2>/dev/null

# === Phase 1: wake the EFR32 ===
# The LSZG02AGT bootloader's "2. run" menu option is broken in this firmware,
# so the chip cannot be woken from cold boot via UART alone. Running zdogd_c
# (LifeSmart's gateway daemon) briefly transitions the chip from bootloader
# into app mode. Mechanism is unclear (possibly a GPIO toggle by zdogd_c's
# RF-radio sub-process), but empirically reliable.
(
  cd /data/mgaopt/natureloader
  export PATH=/data/mgaopt/bin:$PATH
  /system/xbin/luajit -e"package.path='./?.lua;./lua/?.lua;';package.cpath='./?.so;./clib/?.so;'" natureinitrd.lua >/data/local/tmp/natureinitrd.log 2>&1
) &
sleep "$WAKE_SECS"

# === Phase 2: kill the LifeSmart stack ===
# Kill repeatedly because zdogd_c forks into 3+ children and luajit watchdogs
# can respawn. Three passes is empirically sufficient.
for i in 1 2 3; do
  pkill -9 zdogd_c 2>/dev/null
  pkill -9 zdogd 2>/dev/null
  pkill -9 luajit 2>/dev/null
  sleep 1
done

# === Phase 3: launch the bridge under a watchdog with chip-rewake on wedge ===
# The bridge exits with code 1 when it detects the EFR32 stopped responding
# (N consecutive sessions where HA sent data but the chip was silent). On that
# signal, re-run the natureinitrd.lua wake sequence before restarting the bridge.
# Log appends across restarts so the wedge/recovery history is preserved.
( while true; do
    /system/xbin/luajit /data/local/tmp/zb_bridge.lua "$SERIAL" "$PORT" \
      >>/data/local/tmp/zb_bridge.log 2>&1
    rc=$?
    if [ "$rc" -eq 1 ]; then
      echo "$(date) [watchdog] chip wedge detected — re-running EFR32 wake sequence" \
        >>/data/local/tmp/zb_bridge.log
      (
        cd /data/mgaopt/natureloader
        export PATH=/data/mgaopt/bin:$PATH
        /system/xbin/luajit \
          -e"package.path='./?.lua;./lua/?.lua;';package.cpath='./?.so;./clib/?.so;'" \
          natureinitrd.lua >/data/local/tmp/natureinitrd_rewake.log 2>&1
      ) &
      sleep "$WAKE_SECS"
      pkill -9 zdogd_c 2>/dev/null
      pkill -9 zdogd 2>/dev/null
      pkill -9 luajit 2>/dev/null
      echo "$(date) [watchdog] rewake done — restarting bridge" \
        >>/data/local/tmp/zb_bridge.log
    fi
    sleep 2
  done ) &

exit 0
