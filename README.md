# nature7pro-zigbee-bridge

Repurpose a **LifeSmart Nature 7 Pro** smart-home hub as a network-attached **Zigbee coordinator** for **Home Assistant** (via the built-in ZHA integration) or **zigbee2mqtt**.

The hub already contains a Silicon Labs **EFR32** Zigbee NCP (LifeSmart part `LSZG02AGTv2.10`) speaking standard EmberZNet **EZSP over ASH** on `/dev/ttyS5` at 115200 8N1. This project replaces LifeSmart's gateway daemon with a tiny **TCP-to-serial bridge** so any EmberZNet-over-TCP client — Home Assistant's ZHA `ember` radio type, or z2m's `ember` adapter — can drive the radio over the network. **No MQTT broker or zigbee2mqtt required**: ZHA ships with native Ember support and talks to the bridge directly.

```
┌──────────────────────┐       TCP :8880          ┌──────────────────────┐
│  Home Assistant ZHA  │  ◄────────────────────►  │  Nature 7 Pro hub    │
│  (ember) — or z2m    │                          │  zb_bridge.lua       │
└──────────────────────┘                          │       │ /dev/ttyS5   │
                                                  │       ▼              │
                                                  │  EFR32 NCP (EZSP)    │
                                                  └──────────────────────┘
```

## What you get

- **No USB dongle needed.** The hub becomes a remote Zigbee coordinator over Ethernet/Wi-Fi.
- **Pure-LuaJIT bridge.** 200 lines, no compiled binaries to sideload, runs out of the hub's existing `/system/xbin/luajit`.
- **Survives reboots.** Hooks into the existing `init.svc.lifesmart_check` service so it comes up automatically.
- **One-command revert.** A backup of the original boot script is saved alongside; flip it back any time.

## Hardware tested

- LifeSmart Nature 7 Pro — Rockchip RK3566, Android 11 `userdebug`, root available over ADB.

## Getting ADB access

ADB is **not enabled over the network by default** on this device, and there is no externally accessible USB port. The trick:

1. **Open the hub.** Pop the case (a few clips and screws — no glue). On the motherboard there is a hidden, unpopulated-looking **micro-USB port labeled `OTG`**. This is a functional ADB port.
2. **Plug a USB cable into `OTG` *before* powering the device on.** Android debugging on this image only initializes if the cable is detected at boot — hot-plugging after boot does nothing.
3. **Power on with the cable connected** to your host machine. `adb devices` should now list the hub.
4. **Enable ADB over TCP** so you don't have to keep the case open:
   ```sh
   adb root
   adb tcpip 5555
   adb connect <hub-ip>:5555
   ```
   You can then unplug USB, close the hub, and use ADB-over-LAN from now on. (Note: `adb tcpip` does not always survive a reboot on this image; if it doesn't stick, persist it via a property or an init hook of your choice.)

## Install

Requirements on the host: `adb`, the hub reachable on the LAN with ADB-over-TCP enabled (see above).

```sh
git clone https://github.com/<you>/nature7pro-zigbee-bridge
cd nature7pro-zigbee-bridge
./install.sh 192.168.0.180:5555     # IP:port of your hub's adb-tcp
adb -s 192.168.0.180:5555 reboot
```

Then point Home Assistant or zigbee2mqtt at it.

**Home Assistant (ZHA)** — Settings → Devices & Services → Add Integration → *Zigbee Home Automation*:

- Radio type: **EZSP** (a.k.a. Silicon Labs Ember)
- Serial device path: `socket://192.168.0.180:8880`

**zigbee2mqtt** — in `configuration.yaml`:

```yaml
serial:
  adapter: ember
  port: tcp://192.168.0.180:8880
```

The first time the coordinator forms its network it will wipe any LifeSmart-paired devices — re-pair them through ZHA / z2m.

## Revert

```sh
./uninstall.sh 192.168.0.180:5555
adb -s 192.168.0.180:5555 reboot
```

This restores `/vendor/bin/lifesmart_check.sh` from the on-device backup and removes the bridge files. The hub returns to being a normal LifeSmart hub.

## Files

| File | On-device location | What it does |
|---|---|---|
| `zb_bridge.lua` | `/data/local/tmp/zb_bridge.lua` | The TCP↔serial bridge. Pure LuaJIT FFI: opens `/dev/ttyS5`, sets termios via `TCSETSF`, sends an ASH wake (`1A C0 38 BC 7E`), then `poll(2)`-shuttles bytes between a single TCP client and the serial port. |
| `lifesmart_check.sh` | `/vendor/bin/lifesmart_check.sh` (replaces stock) | Boot script. Runs LifeSmart's `natureinitrd.lua` for ~12 s to wake the EFR32, kills it, then launches `zb_bridge.lua` under a `while true` watchdog. |
| `install.sh` / `uninstall.sh` | host-side | One-shot deploy/revert via `adb`. |

## Architecture / how it works

### Persistence

Android's init system on this hub defines a oneshot service `lifesmart_check`:

```
# /system/etc/init/hw/init.rc
service lifesmart_check /vendor/bin/lifesmart_check.sh
    seclabel u:r:lifesmart_check:s0
    oneshot
    disabled
on …
    start lifesmart_check
```

We don't touch init.rc; we just replace the script the service runs. `/vendor` is overlayfs, so `adb remount` is required before the write — `install.sh` handles that.

### The cold-boot wake problem

The non-obvious part. On cold boot the EFR32 sits in its custom Gecko Bootloader, which presents a serial menu:

```
LSZG02AGT Bootloader Start...
Gecko Bootloader v1.12.00
1. upload gbl
2. run
3. ebl info
BL >
```

In this firmware, **only menu option `1` (XMODEM upload) actually works** — `2. run` and `3. ebl info` just reprint the banner regardless of input, and there is no auto-launch timeout. The standard ASH wake `1A C0 38 BC 7E` doesn't escape the bootloader either.

Empirically, **running LifeSmart's `natureinitrd.lua` for ~10–12 s reliably transitions the chip into app mode**, after which UART wake works normally and our bridge can take over. The exact mechanism is unclear: `zdogd_c`'s zigbee child only writes the same wake bytes we do, but its RF-radio sibling claims three GPIOs (`gpio-82` chip2:18, `gpio-149` chip4:21, `gpio-150` chip4:22 — none referenced in device tree) and likely toggles one of these as the EFR32 reset/boot pin. We did not find a minimal pure-UART wake sequence; if you do, PRs welcome.

So `lifesmart_check.sh` proceeds in three phases:

1. **Wake** — fork LifeSmart's `natureinitrd.lua` and sleep 12 s while it brings the chip up.
2. **Kill** — `pkill -9 zdogd_c zdogd luajit` three times (zdogd forks into multiple children that respawn each other).
3. **Bridge** — start `zb_bridge.lua` under a `while true; ...; sleep 2; done` watchdog.

### The bridge itself

`zb_bridge.lua` is intentionally minimal. A few things worth noting:

- **Termios is set inside the bridge** via `ioctl(TCSETSF)`, not via external `stty`. Toybox `stty` on this device silently fails to disable input flags (`istrip`, `icrnl` etc.) when many options are combined on one command line, leading to bytes like `0xC1` arriving as `0x41` — a long detour to debug.
- It uses `__errno()` (Bionic), not `__errno_location()` (glibc).
- `poll(2)` with a 30 s timeout drives both directions; one TCP client at a time, which is all z2m needs.
- The wake (`1A C0 38 BC 7E`, ASH SUBSTITUTE + RST + CRC + flag) is sent on every bridge startup. When the chip is in app mode this returns the banner `   LSZG02AGTv2.10 Start...` followed by an ASH RSTACK frame `1A C1 02 0B 0A 52 7E` (reset code `SOFTWARE`).

## Caveats

- **You will lose your LifeSmart Zigbee pairings.** ZHA / z2m forms its own network, which wipes the chip's network keys.
- **This specific Nature 7 Pro stops acting as a LifeSmart hub.** Your wider LifeSmart setup is unaffected: the LifeSmart cloud, the app, and any **CoSS** (LifeSmart's proprietary sub-GHz RF protocol) devices keep working as long as you have another LifeSmart Smart Station — or another hub acting as a sub-station — on the account. It's only this unit that loses its gateway role: the LifeSmart `zdogd` daemon is killed at boot, so this Nature 7 Pro will no longer bridge CoSS or its onboard Zigbee radio into LifeSmart cloud while the bridge is running.
- **During each boot's 12 s wake window, `mga.lua` briefly attempts to connect to LifeSmart cloud** (`47.88.78.117:18894`). The first connect timeout is 5 s, so the second attempt usually doesn't complete before our `pkill` lands — but if you want hard isolation, blackhole that IP via `iptables`.
- **EZSP version not measured.** `LSZG02AGTv2.10` is likely EmberZNet ~6.7–6.10. If your client (ZHA / z2m) demands a newer NCP, you can OTA-flash the EFR32 via bootloader option `1` (XMODEM upload of a `.gbl`) — but you'll need to source a compatible image.
- **The bridge handles one TCP client at a time.** Fine for ZHA or z2m.
- **Tested on exactly one hub.** Yours may differ; verify with ADB before relying on this in production.

## Investigation notes

If you're curious how this was reverse-engineered, the short version:

1. ADB onto the hub as root, look for the LifeSmart gateway: `/data/mgaopt/xzyq/mganature/mga/lib/android/armeabi-v7a/zdogd_c`. `strings` it and find symbols like `silabszbsdk`, `bootloadCheckMenu`, `ezspLaunchStandaloneBootloader` — confirmation that it's a vanilla Silicon Labs host SDK with a custom branding layer.
2. Probe `/dev/ttyS5` directly: send `1A C0 38 BC 7E` and read back `1A C1 02 0B 0A 52 7E` (RSTACK with `SOFTWARE` reset code). That's textbook ASH/EZSP — the chip is a stock EFR32 NCP underneath.
3. Replace `/vendor/bin/lifesmart_check.sh` with a minimal wrapper that runs the bridge instead of `zdogd_c`. Reboot. Discover the chip is stuck in its bootloader.
4. Brute-force-test all plausible single-byte menu inputs by sending each one through the bridge and watching the response. Result: `1` enters XMODEM upload mode (`begin upload\r\n\x00CCCC...`); every other byte just reprints the banner. Conclusion: the "run" option is broken in this bootloader build.
5. Try running `natureinitrd.lua` manually — chip wakes up. Try running just `zdogd_c` — chip wakes up. The wake mechanism lives somewhere in the LifeSmart stack but isn't the UART bytes alone. Best guess: a GPIO toggle by the RF-radio sub-process. Ship the workaround (12 s `natureinitrd` warmup) and move on.

## License

MIT — see `LICENSE`.

## Disclaimer

This modifies system files on a device you own. It will void any warranty, may break LifeSmart cloud features permanently, and was tested on a single unit. Read the scripts before running them.
