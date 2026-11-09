# Testing

Three levels, from seconds to a real TV.

## Checks

Run before every change; CI runs the same on every push and pull request:

```bash
shellcheck tvlink install.sh tests/*.sh
python3 tvlink-power test
python3 tvlink-agent test
python3 tvlink-console test
python3 tvlink-content test
```

The self-tests cover the settings parser (through `tvlink show`, including `CEC=0` as `POWER_METHOD=none`), the power
modes, presence and clock logic (including clock changes), every power mode with every power method through a day
(no re-wake loop with IR), overrides (over each mode through a day, their end by length, time or the next on-hours boundary across clock
changes, the root-only file, the console's arguments), the badge and the dark-screen check, and the console's password hashing, sessions, CSRF
tokens, login rate limit (and the visitor's address through a tunnel), settings forms, power methods and API tokens;
the daily browser restart's timing (once on the day clocks go back, an hour late when they go forward, never in the
first hour after boot or while dark); synced content's manifest checks, https-only redirects, and syncs against a
stand-in server (only changed files fetched, the rest linked; a bad checksum, an oversized or missing file refused
with the live set kept; older sets pruned) and `manifest`; and the fleet console's unit checks, its calls to stand-in units (the tokens it sends, redirects refused, each
failure's message), the overview not waiting on a slow or dead unit, and its badges.

## The VM

`tests/vm.sh` runs tvlink in a Linux VM on an Apple silicon Mac, using the real `install.sh`, systemd units, cage,
Chromium, NetworkManager, `cec-ctl` and `ir-ctl`. Linux's own test drivers stand in for the TV (CEC and IR) and the
Wi-Fi, and gpiozero's mock pins for the motion sensor. Run it after a change to install.sh, the units, TV power,
HDMI, Wi-Fi or the kiosk; if you can't, say so in the pull request.

```bash
brew install lima
tests/vm.sh
```

- **First run:** makes the VM and installs, about 10 min. It downloads Debian 13's generic arm64 image (about
  0.5 GB) and the packages, including Chromium. A window shows the VM's screen (tty1, where cage runs).
- **Later runs:** reinstall from this checkout and run the checks again, in about 9 min.
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
| IR LED, receiver and the TV's IR sensor | `rc-loopback`: what is sent on `/dev/lirc0` comes back on it, and the kernel's NEC and Sony decoders turn it into scancodes on its input device | `ir-ctl -d /dev/lirc0 -S nec:0x1234` (a remote) |
| HDMI EDID | Apple's virtual display gives `Virtual-1` no EDID: a stand-in connector `/run/tvlink-test-drm/card1-HDMI-A-1` holds vivid's TV EDID | `TVLINK_DRM=...` |
| Motion sensor | gpiozero's MockFactory, through a tvlink-power drop-in; GPIO17 follows the line written to the FIFO | `echo 1 >/run/pir17` (motion), `echo 0` (quiet) |
| Board | `python3 -m http.server` on 127.0.0.1:8080 | `systemctl stop tvlink-test-board` |
| GPU | wlroots software renderer (`WLR_RENDERER=pixman` drop-in) | |
| Cloudflare Tunnel | The real cloudflared from Cloudflare's repo, with a made-up token that Cloudflare refuses (the VM needs internet) | `tvlink set TUNNEL_TOKEN=...` |
| USB stick | `dummy_hcd` (a virtual USB controller) and `g_mass_storage` serving a partitioned FAT image with a `tvlink` folder: a real USB mass storage device, through usb-storage, udev and systemd as on a Pi | `modprobe g_mass_storage file=/run/tvlink-test-stick.img removable=1 ro=1` (plug in), `modprobe -r g_mass_storage` (pull out) |
| Content server | Python's https server on 127.0.0.1:8443 with a certificate from its own CA, which tvlink-content trusts through `SSL_CERT_FILE` (a drop-in) | `systemctl stop tvlink-test-content-server` |
| Time since boot | `TVLINK_UPTIME` (a drop-in for the kiosk) points at a file saying 99999 s, so the browser restart runs however recently the VM started | |
| Fleet server | The VM itself: `tvlink-fleet.service` on port 8081 (a drop-in), pointed at the unit's console on `http://127.0.0.1` | `curl http://127.0.0.1:8081/...` |

`tests/vm-test.sh` checks:
- install and the self-tests;
- CEC on, off and status;
- an unplugged TV;
- a TV that drops hotplug in standby;
- motion wake in `manual+motion`;
- overrides: on in off-hours wakes the TV, holds through a tvlink-power restart, and ends back in standby; the file
  root-only; clear; off until a time in on-hours; a bad length refused, and `always` asking for one; through the
  console's API (Status shows it, Actions offers Clear Override) and through the fleet;
- IR: the transmitter and receiver overlays in `config.txt` (gone again with `cec`), status `unknown`, each built-in
  brand's on and off codes decoded as sent, a brand without codes refused, learning on and off from a stand-in remote
  (stored root-only) and sending them, and tvlink-power sending the on code at start;
- Wi-Fi join, Wi-Fi country, a rerun that leaves the link up, power save, fallback to the hidden WPA network, and the
  Ethernet-out network check;
- the splash handing over to the board, the live badge, and a screenshot;
- the kiosk user's limits: the render group only, no polkit rights, and a home it can't write;
- nothing written to the kiosk's home, and `/run/tvlink` staying small;
- the console: the claim code from `tvlink console claim` and on the splash, a wrong code refused, claiming sets a
  PBKDF2 password, login (a wrong password refused), a form without its CSRF token and an API call without its CSRF
  header refused, the API refused with no session or token, the console user unable to run other commands as root,
  an API token (stored hashed only) reloading the page and fetching the screenshot, then revoked and refused, a
  settings round trip through the API (`OVERLAY_CORNER`, not logged by sudo, a bad value refused with its key), and
  the claim code gone from the splash once claimed. The checks use curl against `http://127.0.0.1` inside the VM;
- the console behind a tunnel: Access and proxy headers alone don't authenticate, and the cookie is `Secure` with
  `Cf-Visitor` or `X-Forwarded-Proto` saying HTTPS, and not otherwise;
- the tunnel: a malformed token refused; a made-up one set through the console API installs cloudflared from
  Cloudflare's repo, is stored root-only and not in tvlink.conf, shows only as `(set)`, and starts `tvlink-tunnel`
  (not as root, the token not on its command line); Cloudflare refuses it and `tvlink tunnel`, `tvlink doctor` and the
  console's status say `not connected`; the token is in no log; clearing it stops and disables the service and
  removes the file;
- the fleet console: on loopback only, a root-only claim code, claimed; this unit added with an API token (stored for
  the fleet user only) and an unreachable one (`192.0.2.1`); the overview shows the unit Live and the other
  Unreachable without waiting on it; the screenshot, Status (with health), Settings (a bad value's error) and Logs
  pages through the fleet; a Reload through it reaches the TV; nothing without a login;
- the HDMI signal: tvlink-power turns it on at start, `tvlink off` turns cage's output off and `tvlink on` back on,
  status and the console follow, the kiosk keeps running and logs no recovery for a minute in the dark, a kiosk
  restart keeps it off, and the page shows again after;
- a new `BOARD_URL` swapped in without restarting cage or Chromium and showing on screen, a 404 link refused with the
  old page kept, and back again;
- synced content: `tvlink content manifest`, an http link refused, `tvlink content sync` fetching the files (root's,
  readable by all) that then play and show, a bad checksum refused with the set before kept on screen, and the
  console's Status saying so;
- a USB stick: not mounted with `USB_CONTENT=0`, mounted read-only with `nosuid,nodev,noexec` once it is 1, the kiosk
  unable to write it, played ahead of synced content and on screen; pulled out: unmounted, back to synced content;
  clearing `CONTENT_URL` removes the synced files;
- the last good screen: the agent's screenshot without the badge, copied root-owned by `tvlink lastgood`, a link
  planted in its place not followed; with the board down after a kiosk restart, the splash shows it full screen with
  the red Offline marker; `LAST_GOOD=0` deletes it;
- the daily browser restart: a new Chromium at `BROWSER_RESTART` in the same cage, and the page back;
- HDMI at boot: `HDMI_FORCE_HOTPLUG` adds and removes `vc4.force_hotplug=1` once, leaving the rest of `cmdline.txt`,
  and a second set changes nothing; `tvlink edid capture` refuses the VM's own display (no EDID) and a corrupt EDID,
  saves the stand-in's byte for byte, adds `drm.edid_firmware` once and the file to the initramfs; `clear` removes
  all three; `tvlink doctor` shows both.

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
- IR on a Pi 5: the `gpio-ir-tx` and `gpio-ir` overlays load (`sudo tvlink doctor` names a transmitter and receiver);
  each built-in brand's codes on a TV of that brand from a few centimetres and across the room; learning on and off
  from a real remote, then `IR_CODES=learned`; the remote pressed near the receiver types nothing into the kiosk;
  `schedule` with IR across an on-time start and end, and a power cut in off-hours.
- Signal: on a TV that sleeps without a signal, `tvlink off` puts it to sleep and `tvlink on` wakes it; how long it
  takes; the page and badge after a night dark; a kiosk restart and the nightly reboot while dark (the TV may wake).
- HDMI at boot on a Pi 5: `tvlink edid capture` and `HDMI_FORCE_HOTPLUG=1`, then boot with the TV off, on another
  input and unplugged: the right mode once it is back, and CEC keeps its address; check whether vc4 loads from the
  initramfs (`lsinitramfs`) and that the EDID is found there (`dmesg | grep -i edid`).
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
- Overrides: `tvlink override off until` a time across the nightly reboot and a power cut, and `on` through a clock
  change; each ends on time and the mode takes over (`schedule` turns the TV back, `manual` leaves it).
- Motion: a PIR wakes the TV outside on-hours and standby follows after `IDLE_MIN`; `manual+motion` wakes on arrival
  and leaves a TV switched off by hand alone.
- `tvlink set WIFI2_SSID=... WIFI2_PSK=...` adds the network without a reboot, and the unit joins it when the first
  goes away.
- With a keyboard: F12, Ctrl+Shift+I, Ctrl+O and Ctrl+S do nothing useful.
- `tvlink screenshot` matches the TV; `identify` and `reload` work; `tvlink update` refuses a wrong checksum and
  installs a good commit.
- Console from a phone on the site Wi-Fi: `http://<name>.local` resolves (else the IP), the claim code on the TV
  works once, every page reads well on a phone, the Status screenshot matches the TV, Reboot comes back on its own,
  an update from the Update page restarts the console, and a login takes under 2 s (PBKDF2 on the Pi).
- Tunnel, with a real Cloudflare account ([Cloudflare](cloudflare.md)): the dashboard's token from the console's
  Settings installs cloudflared and says `Tunnel: connected` within a minute; the hostname opens the console over
  HTTPS behind Access, and logging in works (the cookie is `Secure`); it reconnects after a reboot and after the
  network drops; a revoked token says `not connected`; clearing the token stops it.
- Fleet console on a Debian or Ubuntu server behind its own tunnel and Access ([fleet](fleet.md)): units added with a
  service token show Live; a unit unplugged shows Unreachable at the next look without slowing the page; a wrong
  service token says to check it; Settings and Actions through the fleet reach the unit.

- USB stick on a Pi 5: FAT32 and exFAT sticks with a `tvlink` folder play within seconds of plugging in and stop
  cleanly when pulled mid-video; a stick without the folder, a second stick, and a Pi booted from a USB drive are left
  alone; `ls /run/tvlink-usb` empty after.
- Synced content from a real https host (eg a CDN or object storage): a first sync of a few hundred MB, an unchanged
  sync writing nothing (`iostat` or the card's write counter), a changed file fetched alone, a server error keeping the
  set, and a power cut mid-sync leaving the old set playing.
- Last good screen: unplug the network and reboot: the last page shows with its Offline badge, and the time is right
  with and without the RTC battery.
- Link switch: a heavy real dashboard swaps in with no white flash; a link with a login redirect or a 404 keeps the
  old page.
- Browser restart: memory after it (`free -m`), and the page back within a minute.
Reports from your own hardware are welcome as issues: the Pi model, the TV model, and which of these passed.
