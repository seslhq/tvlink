# Operations

## Remote management

Use the unit's console first ([console](console.md)): `http://<name>.local` on the site network, or from elsewhere
through its tunnel (`TUNNEL_TOKEN`, [Cloudflare](cloudflare.md)). It shows the screen and the unit's health, changes
settings and Wi-Fi, runs the actions below, shows the logs and installs updates. A [fleet console](fleet.md) shows all
units on one page and opens each one's pages.

Keep a shell as break-glass, for when the console can't be reached or its password is lost
(`sudo tvlink console reset`). Raspberry Pi Connect is the recommended one: it is preinstalled on Raspberry Pi OS Lite,
needs no open ports, and install.sh keeps it running without a login. Use a shared fleet Raspberry Pi ID with 2FA, or
Connect for Organisations past a handful of units. Any other remote shell works too; tvlink needs nothing from it.

| Command | Does |
| --- | --- |
| `tvlink show`, `sudo tvlink set KEY=value` | Read and change settings ([configuration](configuration.md)) |
| `sudo tvlink on`, `sudo tvlink off`, `tvlink status` | TV power by `POWER_METHOD`, and what is known of the TV: CEC's answer, the signal last sent, or `unknown` (IR) |
| `sudo tvlink override on\|off [4h\|until 07:00]`, `sudo tvlink override clear` | Force the TV on or off for a while, over the power mode; `sudo tvlink override` shows it ([overrides](configuration.md#overrides)) |
| `sudo tvlink ir learn on\|off`, `sudo tvlink ir test on\|off` | Record a power code from the TV's remote; send one once ([IR](setup.md#ir-transmitter-and-receiver)) |
| `sudo tvlink edid capture\|clear` | Keep the TV's EDID for boot, or forget it; reboot to apply |
| `sudo tvlink doctor` | Health on one screen: page, services, clock, power and heat, memory, disk, HDMI, CEC or IR, Wi-Fi |
| `sudo tvlink screenshot` | Saves what the TV shows to `/run/tvlink/screen.jpg` |
| `sudo tvlink identify` | Puts the unit's name and IP across the screen for up to 60 s |
| `sudo tvlink reload` | Reloads the page |
| `sudo tvlink update URL SHA256` | Installs a commit of `main` (below) |
| `sudo tvlink reboot` | Reboots in 3 s, as a planned reboot (`manual` mode does not wake the TV after it) |
| `sudo tvlink console claim`, `sudo tvlink console reset` | The console's claim code; back to claim mode after a lost password |
| `sudo tvlink overlay on\|off`, `tvlink overlay status` | The read-only root, from the next boot (below) |
| `tvlink tunnel` | The tunnel: `off`, `connected` or `not connected` |
| `sudo tvlink content sync`, `tvlink content status` | Sync `CONTENT_URL` now and print how it went; the last sync's result |
| `tvlink content manifest DIR` | A manifest for the files in DIR, to serve with them ([synced content](configuration.md#synced-content)) |

- Screenshot off the unit: the console's Status page. Without it: `scp` if SSH is on. In a Connect shell, run
  `base64 /run/tvlink/screen.jpg`, copy all of its output, then on your computer run `base64 -d >screen.jpg`, paste
  and press Ctrl-D (on a Mac: `pbpaste | base64 -d >screen.jpg`).
- Wi-Fi changing at a site: add the new network as the second one before the switch, and the Pi moves over by
  itself: `sudo tvlink set WIFI2_SSID='New network' WIFI2_PSK='new password'`. A password containing `'` goes in the
  file by hand, in double quotes.
- Time zone: `sudo timedatectl set-timezone <zone>`, then `sudo systemctl restart tvlink tvlink-power`.
- Restart with the console's Reboot, `sudo tvlink reboot` or `sudo reboot` only. Never `poweroff` or `halt`: the Pi
  then needs someone on site to cycle its power.
- SSH: public-key only. Once Connect works it can be turned off: `sudo systemctl disable --now ssh`.
- Network needs: inbound HTTP (80) from the site network for the console, outbound HTTPS (443), HTTP (80) to
  deb.debian.org and archive.raspberrypi.com for updates, and NTP (UDP 123); with a tunnel, outbound 7844 (UDP, or
  TCP) to Cloudflare; no captive portal; WPA2 Personal or WPA3
  in transition mode. Where public NTP is blocked, put `[Time]` and `NTP=<server>` in
  `/etc/systemd/timesyncd.conf.d/tvlink.conf` (`sudo mkdir -p` the folder first), run
  `sudo systemctl restart systemd-timesyncd`, and check that `timedatectl` says the clock is synchronized.
- A page link that contains a key is readable by anyone with the Pi or its card. If a unit or card is lost, rotate the
  link where it was issued and set the new one.

## Updates

Debian and Raspberry Pi security updates install at 02:30 (every night on canary units, weekly on `UPDATE_DAY` on
the rest) and the 03:30 reboot loads them. Hold a bad package everywhere with `sudo apt-mark hold <package>`.

To update tvlink itself, copy the new folder and rerun the installer, which restarts the services (reboot only if it
says `Reboot to apply`):

```bash
scp -r tvlink <user>@tv-lobby-01.local:
ssh -t <user>@tv-lobby-01.local sudo ./tvlink/install.sh
```

There are no releases: `main` is always the version to install, and CI checks every change to it. From the console's
Update page or a remote shell, with no copy step, install a commit of `main` by its archive URL and SHA-256, so every
unit gets exactly the same code (get the hash on your computer with `curl -sL <url> | shasum -a 256`):

```bash
sudo tvlink update https://github.com/seslhq/tvlink/archive/<commit>.tar.gz <sha256>
```

It refuses a wrong checksum, then runs that commit's install.sh as its own unit, so a dropped session can't stop it
halfway: `journalctl -u tvlink-update -f`.

## Troubleshooting

- The splash says what it is waiting for, and the kiosk log has the same: `journalctl -t tvlink -b`.
  `Splash: network` means no route, `Splash: waiting 000` no answer (DNS, connection, or a wrong clock breaking
  HTTPS: check `timedatectl`), `Splash: waiting 5xx` the server is up but failing. All retry by themselves.
- The console's Logs page shows the kiosk, TV power and Wi-Fi logs below; its Status page shows `tvlink doctor`.
  `journalctl -u tvlink-console -b` has its own log, if the console itself is down: `systemctl status tvlink-console`.
- Badge changes and page recoveries are in the same log: `journalctl -t tvlink -b | grep 'Badge\|Recover'`.
- `Tunnel: not connected` in `tvlink doctor`: `journalctl -u tvlink-tunnel -b` ([Cloudflare](cloudflare.md)).
- `journalctl -u tvlink-power -b`: power mode, clock, wakes and standbys, `TV reports ...`, motion sensor problems.
- Synced content: `tvlink content status`, then `journalctl -u tvlink-content -b` (it logs changes, not every
  unchanged sync). `Failed ...: <file>: checksum does not match` means the server's file and manifest differ:
  regenerate the manifest. The unit keeps playing the set it had.
- A USB stick that does not play: `USB_CONTENT=1`, a `tvlink` folder at its root, FAT or exFAT;
  `journalctl -u 'tvlink-usb@*' -b` says why it was not used, and `tvlink doctor` names the stick in use.
- A new page link that does not show: `journalctl -t tvlink -b | grep 'Page switch'` (the old page stays while the new
  one fails to load).
- `tvlink status` says `unknown`: CEC is off in the TV menu, or the TV does not answer power queries. With
  `POWER_METHOD=ir` it always does: IR is one-way.
- IR does nothing: `sudo tvlink doctor` should name a transmitter on its `TV power` line (else the overlay is not
  loaded: reboot after setting `POWER_METHOD=ir`, check the wiring); point the LED at the TV's IR window; try the other
  brand codes or learn them. A phone camera shows the LED flash during `sudo tvlink ir test on`.
- Signal off but the TV stays on: the TV has no no-signal standby, or it is set long; use CEC or IR. The kiosk log
  shows `HDMI signal off (HDMI-A-1)` when it acts.
- No picture or the wrong modes after a cut while the TV was off or on another input: `tvlink edid capture` and
  `HDMI_FORCE_HOTPLUG=1` ([setup](setup.md#tv-settings-and-hdmi-cec)); `sudo tvlink doctor` says `(reboot to apply)`
  until the kernel uses them.
- A server page such as 404 on the TV: the page answered, so tvlink shows its answer, with `Board not found` on the
  badge.
- Black screen: the HDMI cable in HDMI0, the TV input, and `systemctl status tvlink`.
- Undervoltage or heat: `vcgencmd get_throttled` should say `throttled=0x0`.
- 4K output on a 4K TV: the TV refused `RESOLUTION`; check `journalctl -t tvlink -b | grep "Can't set"`.
- `sudo tvlink doctor` shows the page's host, never its key; redact IP addresses and Wi-Fi names before posting it.
- The mouse cursor shows only while a mouse is plugged in.

## On site

- The TV shows the page, or the tvlink logo with a message saying what is wrong: no network, can't reach the page,
  or no files.
- Check the power supply is in a wall socket, the HDMI cable is in the Pi's port next to the power socket, Ethernet
  is plugged in if the site has it, and the TV is on the right input.
- Wi-Fi password changed: take out the SD card, open `tvlink.conf` on any PC, set `WIFI1_SSID` and `WIFI1_PSK` to the
  new network (in double quotes), put the card back and power on.
- With `USB_CONTENT=1`, a USB stick with a `tvlink` folder of images or videos plays while it is plugged in (when the
  page is down, or with `SOURCE=folder`), no PC needed.
- A full-screen picture with a red `Offline, from ...` badge is the last good screen (`LAST_GOOD=1`): the page has not
  answered since the Pi started.
- To report a fault, give the device name and IP shown at the bottom left of the logo screen.

## Replacing a unit

- Dead Pi: move its card to a spare Pi (same name and settings). Connect is tied to the Pi's serial number and signs
  out, so run `rpi-connect signin` on site.
- Dead card: image a new one and provision it with the same hostname and page link; set `TUNNEL_TOKEN` again (it
  lives on the card's root partition, not in tvlink.conf).

## Read-only root (optional)

Raspberry Pi OS's overlay file system keeps the root partition as it is at every boot: what is written goes to RAM
and is gone at the next reboot, so a power cut can't damage the system. Consider it only where power cuts keep
corrupting cards; it is off by default, as below. Switch it from the console's Actions page or a shell; either way
it takes a reboot:

```bash
sudo tvlink overlay on       # raspi-config nonint enable_overlayfs; needs the network the first time (overlayroot)
sudo tvlink reboot
tvlink overlay status        # on, off, or eg "off, on after a reboot"
sudo tvlink overlay off      # then reboot
```

It covers the root partition only, not the boot partition (that would be raspi-config's `do_overlayfs`, which tvlink
does not use), so tvlink.conf, `tvlink set`, the console's Settings and Wi-Fi pages and the local content folder work
as before. Set the unit up first. While it is on:

| Kept | Gone at the next reboot | Refused or paused |
| --- | --- | --- |
| tvlink.conf and the boot partition's files; everything on the root partition from before it was turned on | Overrides, learned IR codes, a console password or API tokens made while on, the hourly last good screen, the Raspberry Pi Connect sign-in, network changes made outside tvlink.conf | `tvlink update` and install.sh (turn it off, reboot, update, turn it on, reboot); `TUNNEL_TOKEN` changes; content sync (the set from before plays); nightly security updates (the reboot would undo them, and they would fill RAM first) |

`tvlink doctor` and the console's Status page show it; `tvlink override` and `tvlink ir learn` say when what they
keep won't last.
