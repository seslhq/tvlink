# Testing

Three levels, from seconds to a real TV.

## Checks

Run before every change; CI runs the same on every push and pull request:

```bash
shellcheck tvlink install.sh tests/*.sh
python3 tvlink-power test
python3 tvlink-agent test
```

The self-tests cover the settings parser (through `tvlink show`), the power modes, presence and clock logic (including
clock changes), and the badge.

## The VM

`tests/vm.sh` runs tvlink in a Linux VM on an Apple silicon Mac, using the real `install.sh`, systemd units, cage,
Chromium, NetworkManager and `cec-ctl`. Linux's own test drivers stand in for the TV and the Wi-Fi, and gpiozero's
mock pins for the motion sensor. Run it after a change to install.sh, the units, CEC, Wi-Fi or the kiosk; if you
can't, say so in the pull request.

```bash
brew install lima
tests/vm.sh
```

- **First run:** makes the VM and installs, about 10 min. It downloads Debian 13's generic arm64 image (about
  0.5 GB) and the packages, including Chromium. A window shows the VM's screen (tty1, where cage runs).
- **Later runs:** reinstall from this checkout and run the checks again, in about 3 min.
- **Exploring:** `limactl shell tvlink` opens a shell in the VM. The repo is mounted read-only at the same path.
- **Starting over:** `limactl delete -f tvlink`.

### Stand-ins

| On the Pi | In the VM | Driven by |
|---|---|---|
| Pi 5 1 GB, Pi OS Lite | Debian 13 arm64, 4 CPUs, 1 GiB, zram swap, Raspberry Pi apt repo (its cage, Chromium, gpiozero and lgpio builds) | `tests/vm.yaml`, `tests/vm-setup.sh` |
| Boot partition | 512 MiB FAT32 loop image at `/boot/firmware` | |
| TV on HDMI-CEC | `vivid`: its HDMI input is the TV, its output is the Pi, and `cec-follower` acts as the TV. The TV side's node is moved to `/dev/tvside`, so tvlink sees one adapter | `tv` in `tests/vm-test.sh` |
| Site Wi-Fi | `mac80211_hwsim`: `wlan0` is the Pi's radio; two access points run in the `ap` network namespace: `tvlink-open` (open) and `tvlink-hidden` (hidden, WPA2) | `ip netns exec ap ...` |
| Ethernet unplugged | `ip route del default dev eth0`; plug it back in with `networkctl reconfigure eth0` | |
| Motion sensor | gpiozero's MockFactory, through a tvlink-power drop-in; GPIO17 follows the line written to the FIFO | `echo 1 >/run/pir17` (motion), `echo 0` (quiet) |
| Board | `python3 -m http.server` on 127.0.0.1:8080 | `systemctl stop tvlink-test-board` |
| GPU | wlroots software renderer (`WLR_RENDERER=pixman` drop-in) | |

`tests/vm-test.sh` checks:
- install and the self-tests;
- CEC on, off and status;
- an unplugged TV;
- a TV that drops hotplug in standby;
- motion wake in `manual+motion`;
- Wi-Fi join, Wi-Fi country, a rerun that leaves the link up, power save, fallback to the hidden WPA network, and the
  Ethernet-out network check;
- the splash handing over to the board, the live badge, and a screenshot;
- the kiosk user's limits: the render group only, no polkit rights, and a home it can't write;
- nothing written to the kiosk's home, and `/run/tvlink` staying small.

Faults to try by hand, as root in the VM (the power cut runs on the Mac):
- **TV unplugged at the wall:** `pkill cec-follower; cec-ctl -d /dev/tvside --clear`.
- **TV that acknowledges CEC but ignores it:** `pkill -x cec-follower; cec-ctl -d /dev/tvside --clear; cec-ctl -d
  /dev/tvside --tv`, then `cec-follower -d /dev/tvside --ignore-standby 1 --ignore-view-on 1 &`.
- **TV that drops hotplug in standby:** `v4l2-ctl -d /dev/videoN --clear-edid pad=0`. Restore it with
  `--set-edid pad=0,file=/run/tv-edid.hex`.
- **HDMI cable pulled:** `v4l2-ctl -d /dev/videoN --set-ctrl=hdmi_000_0_is_connected_to=1`. Plug it back in with
  `=2`.
- **Power cut:** `limactl stop --force tvlink`, then `limactl start tvlink`.

`/dev/videoN` is vivid's capture node, named `vivid-000-vid-cap`.

Restarts and the stand-ins:
- Restart the VM from the Mac with `limactl restart tvlink`. A reboot from inside it may just stop it, and that
  includes the 03:30 nightly reboot.
- After a restart, vivid, hwsim and the access points are gone until `tests/vm-test.sh` runs again.

## On a Pi

The VM can't show each TV model's CEC quirks, HDMI hotplug, EDID and overscan, Chromium's speed and memory on a 1 GB
Pi, the Pi's Wi-Fi chip, real motion sensors, or SD card behaviour after a power cut. Before relying on a TV model,
or after a change that touches them, check on the bench with a fresh card and record the results with
`sudo tvlink doctor`:

- Boot to the live page; a quiet boot; each splash state on the TV (setup, no network, waiting, empty, broken files,
  slideshow).
- Each TV model: `tvlink on`, `off` and `status`; wake time; auto standby can be turned off; `sudo cec-ctl -M` during
  repeated `tvlink on` shows no on-screen banners.
- TV standby with the Pi running: does it drop hotplug, and are the CEC address and picture size right after a wake.
- A 4K TV: the default `1920x1080@60` holds after boot and after a wake; `RESOLUTION=auto` runs 4K.
- 10 power cuts mid-page: it recovers by itself, the settings file is intact, one standby in off-hours, and `manual`
  retries its wake.
- `tvlink set` in a loop while pulling power: the settings file is always whole.
- The clock after a cut without the RTC battery: the TV stays on until NTP syncs.
- The nightly reboot runs with the page up, folder-only and blank; it is skipped while a configured page is down.
- A 1080p30 H.264 MP4 plays smoothly for an hour; an `index.html`; the broken-files message.
- A 72 h soak on 1 GB with a real page: lowest available memory, zram use, OOM kills, temperature,
  `vcgencmd get_throttled`; `/home/kiosk` still empty and `du -sh /run/tvlink` small (the GPU's shader cache).
- Connect survives a reboot and a power cut; `wdctl` shows the watchdog; Wi-Fi power save is off.
- Motion: a PIR wakes the TV outside on-hours and standby follows after `IDLE_MIN`; `manual+motion` wakes on arrival
  and leaves a TV switched off by hand alone.
- `tvlink set WIFI2_SSID=... WIFI2_PSK=...` adds the network without a reboot, and the unit joins it when the first
  goes away.
- With a keyboard: F12, Ctrl+Shift+I, Ctrl+O and Ctrl+S do nothing useful.
- `tvlink screenshot` matches the TV; `identify` and `reload` work; `tvlink update` refuses a wrong checksum and
  installs a good commit.

Reports from your own hardware are welcome as issues: the Pi model, the TV model, and which of these passed.
