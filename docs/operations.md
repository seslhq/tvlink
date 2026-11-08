# Operations

## Remote management

Raspberry Pi Connect is the recommended remote shell: it is preinstalled on Raspberry Pi OS Lite, needs no open
ports, and install.sh keeps it running without a login. Use a shared fleet Raspberry Pi ID with 2FA, or Connect for
Organisations past a handful of units. Any other remote shell works too; tvlink needs nothing from it.

| Command | Does |
| --- | --- |
| `tvlink show`, `sudo tvlink set KEY=value` | Read and change settings ([configuration](configuration.md)) |
| `sudo tvlink on`, `sudo tvlink off`, `tvlink status` | TV power over CEC, and what the TV reports |
| `sudo tvlink doctor` | Health on one screen: page, services, clock, power and heat, memory, disk, HDMI, CEC, Wi-Fi |
| `sudo tvlink screenshot` | Saves what the TV shows to `/run/tvlink/screen.jpg` |
| `sudo tvlink identify` | Puts the unit's name and IP across the screen for up to 60 s |
| `sudo tvlink reload` | Reloads the page |
| `sudo tvlink update URL SHA256` | Installs a commit of `main` (below) |

- Screenshot off the unit: `scp` if SSH is on. In a Connect shell, run `base64 /run/tvlink/screen.jpg`, copy all of
  its output, then on your computer run `base64 -d >screen.jpg`, paste and press Ctrl-D (on a Mac:
  `pbpaste | base64 -d >screen.jpg`).
- Wi-Fi changing at a site: add the new network as the second one before the switch, and the Pi moves over by
  itself: `sudo tvlink set WIFI2_SSID='New network' WIFI2_PSK='new password'`. A password containing `'` goes in the
  file by hand, in double quotes.
- Time zone: `sudo timedatectl set-timezone <zone>`, then `sudo systemctl restart tvlink tvlink-power`.
- Restart with `sudo reboot` only. Never `poweroff` or `halt`: the Pi then needs someone on site to cycle its power.
- SSH: public-key only. Once Connect works it can be turned off: `sudo systemctl disable --now ssh`.
- Network needs: outbound HTTPS (443), HTTP (80) to deb.debian.org and archive.raspberrypi.com for updates, and NTP
  (UDP 123); no captive portal; WPA2 Personal or WPA3 in transition mode. Where public NTP is blocked, put `[Time]`
  and `NTP=<server>` in `/etc/systemd/timesyncd.conf.d/tvlink.conf` (`sudo mkdir -p` the folder first), run
  `sudo systemctl restart systemd-timesyncd`, and check that `timedatectl` says the clock is synchronized.
- A page link that contains a key is readable by anyone with the Pi or its card. If a unit or card is lost, rotate the
  link where it was issued and set the new one.

## Updates

Debian and Raspberry Pi security updates install at 02:30 (every night on canary units, weekly on `UPDATE_DAY` on
the rest) and the 03:30 reboot loads them. Hold a bad package everywhere with `sudo apt-mark hold <package>`.

To update tvlink itself, copy the new folder and rerun the installer, which restarts the services (reboot only if it
says `cmdline.txt` changed):

```bash
scp -r tvlink <user>@tv-lobby-01.local:
ssh -t <user>@tv-lobby-01.local sudo ./tvlink/install.sh
```

There are no releases: `main` is always the version to install, and CI checks every change to it. From a remote
shell with no copy step, install a commit of `main` by its archive URL and SHA-256, so every unit gets exactly the
same code (get the hash on your computer with `curl -sL <url> | shasum -a 256`):

```bash
sudo tvlink update https://github.com/seslhq/tvlink/archive/<commit>.tar.gz <sha256>
```

It refuses a wrong checksum, then runs that commit's install.sh as its own unit, so a dropped session can't stop it
halfway: `journalctl -u tvlink-update -f`.

## Troubleshooting

- The splash says what it is waiting for, and the kiosk log has the same: `journalctl -t tvlink -b`.
  `Splash: network` means no route, `Splash: waiting 000` no answer (DNS, connection, or a wrong clock breaking
  HTTPS: check `timedatectl`), `Splash: waiting 5xx` the server is up but failing. All retry by themselves.
- Badge changes and page recoveries are in the same log: `journalctl -t tvlink -b | grep 'Badge\|Recover'`.
- `journalctl -u tvlink-power -b`: power mode, clock, wakes and standbys, `TV reports ...`, motion sensor problems.
- `tvlink status` says `unknown`: CEC is off in the TV menu, or the TV does not answer power queries.
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
- To report a fault, give the device name and IP shown at the bottom left of the logo screen.

## Replacing a unit

- Dead Pi: move its card to a spare Pi (same name and settings). Connect is tied to the Pi's serial number and signs
  out, so run `rpi-connect signin` on site.
- Dead card: image a new one and provision it with the same hostname and page link.

## Read-only root (optional)

Not recommended by default: security updates, network changes made outside tvlink.conf and the Connect sign-in all
vanish at each reboot. Consider it only where power cuts keep corrupting cards. While online, run
`sudo raspi-config nonint enable_overlayfs` and reboot; undo it with `disable_overlayfs`. Do not use `do_overlayfs`:
it also write-protects the boot partition, which breaks `tvlink set` and local content. install.sh refuses to run
under the overlay: turn it off, reboot, update, turn it on, reboot.
