<p align="center">
  <img src="docs/brand/hero.svg" alt="tvlink: a Raspberry Pi 5 connected over HDMI to a TV that shows a web dashboard
    full screen, with a small green live badge in the corner showing when the board last answered.">
</p>

# tvlink

Set-and-forget digital signage for consumer TVs: a Raspberry Pi 5 shows one web page, or a folder of images and
videos, full screen on a TV and turns the TV on and off. It recovers by itself from power cuts, network drops and
browser crashes, and is managed from a console on the unit itself, with no site visits.

![A dashboard full screen on the TV, with the live badge in the bottom-right corner](docs/images/board.jpg)

## What it does

**Screen**
- Any URL full screen in Chromium, eg a dashboard; the page refreshes itself.
- An honest badge: live, or how old what is on screen is. A crashed, frozen or error page goes back to the splash and
  returns by itself; the TV never shows a browser error.
- A splash that says what it is waiting for, with the unit's name and IP for whoever is fixing it.
- A new page link loads in the background and swaps in once loaded; optional daily browser restart.

![The badge: live, cached after a server error, offline](docs/images/badges.png)

<img src="docs/images/splash-setup.png" width="60%" alt="The splash on a new unit: Ready to Set Up, with the
  console's address and claim code">

**TV power**
- HDMI-CEC, infrared (built-in discrete codes for common brands, or learned from the TV's remote) or the HDMI signal.
- Always on, on-hours, a motion sensor, the TV remote, or the remote plus motion wake; overrides (on for 4 h, off until
  07:00) that end by themselves.
- Optional forced HDMI hotplug and a captured EDID, for TVs that are off or on another input at boot.

**Content**
- Images, videos or an `index.html` on the SD card, played with no network, as a fallback or on their own.
- Optionally from a USB stick, or synced from an https manifest with every file's checksum checked.
- Optionally the last good screen, marked Offline, when a unit starts with no network.

**Management**
- A console on every unit: web pages and a JSON API for the screen, health, settings, actions, logs, Wi-Fi and
  updates, from a phone on site. Claimed with a one-time code from the TV.
- Optionally a Cloudflare Tunnel per unit (HTTPS, Access in front, no open ports), and a fleet console on any Linux
  server with every unit on one page.
- One text file on the SD card holds the settings, editable on any PC, in the console or with `tvlink set`.
- Optionally a setup hotspot: a unit with no network opens its own Wi-Fi, so a phone can set the site's.

![The console's Status page: the screen, TV power, health](docs/images/console-status.png)

![The fleet overview: each unit's screen, badge, TV state, last seen and version](docs/images/fleet-overview.png)

**Reliability**
- Nightly reboot (skipped while the page is down), hardware watchdog, staged security updates.
- A boxed-in kiosk user, no browser writes to the card, and optionally a read-only root.

## How it works

```
TV  <── HDMI + CEC ──  Raspberry Pi 5, Raspberry Pi OS Lite (Trixie)
    <───── IR ───────  optional IR LED on a GPIO pin
                         tvlink.service           cage + Chromium on tty1: the splash until the page answers, then the
                                                  page; tvlink-agent drives Chromium over a DevTools pipe (badge,
                                                  recovery, screenshots, page switches)
                         tvlink-power.service     the only process that powers the TV: modes, overrides, motion
                         tvlink-net.service       Wi-Fi networks from the settings file
                         tvlink-console.service   the console on port 80: web pages and JSON API
                         tvlink-hotspot.service   optional setup hotspot after a spell with no network
                         tvlink-tunnel.service    optional cloudflared: a Cloudflare Tunnel to the console
                         tvlink-content.service   optional synced content from an https manifest
                         tvlink-usb@.service      optional USB stick with a tvlink folder, mounted read-only
                         tvlink-reboot.timer      nightly reboot, gated on the page answering
                         tvlink-lastgood.timer    optional hourly copy of the last good screen
                         /boot/firmware           tvlink.conf and the local content folder (FAT: any PC can edit it)
```

Bash, Python 3 and systemd: no build step, no containers, nothing beyond Raspberry Pi OS packages. The only thing
listening on the network is the console. The parts and the reasons behind them: [docs/design.md](docs/design.md).

## Quick start

You need a Raspberry Pi 5 (1 GB is enough) with the official 27 W power supply and Active Cooler, a high-endurance
microSD card, a micro-HDMI cable, and a TV with HDMI-CEC turned on (or an IR LED: [setup](docs/setup.md)).

1. Write Raspberry Pi OS Lite (64-bit, Trixie) with Raspberry Pi Imager; set the hostname, a user, SSH with a key,
   and Wi-Fi if there is no Ethernet.
2. On the Pi, install tvlink (the same line updates it):

   ```bash
   curl -fsSL https://raw.githubusercontent.com/seslhq/tvlink/main/get.sh | sudo bash
   ```

3. Claim its console at `http://tv-lobby-01.local` with the code on the TV, point it at a page in Settings, then
   reboot.

The full guide, including installing from a clone, TV settings and the CEC test: [docs/setup.md](docs/setup.md).

## Try it in a VM

On an Apple silicon Mac, `tests/vm.sh` installs tvlink in a Debian VM with stand-ins for the TV (CEC and IR), Wi-Fi,
the motion sensor and a USB stick, and runs 290 checks against the real services; the VM's window shows the TV
([docs/testing.md](docs/testing.md#the-vm)).

## Documentation

| Guide | Covers |
| --- | --- |
| [Setup](docs/setup.md) | Hardware, installing, TV settings and the CEC test, EDID, wiring a motion sensor and IR |
| [Configuration](docs/configuration.md) | Every setting, power modes and methods, overrides, the setup hotspot, content |
| [Console](docs/console.md) | The unit's web pages and JSON API, claiming, security |
| [Cloudflare](docs/cloudflare.md) | A tunnel per unit, Access in front, a service token for the fleet console |
| [Fleet](docs/fleet.md) | The fleet console: installing it on a server, adding units, security |
| [Operations](docs/operations.md) | Commands, updates, troubleshooting, on-site notes, replacing a unit, the read-only root |
| [Design](docs/design.md) | The parts, the decisions behind them, platform facts |
| [Testing](docs/testing.md) | Checks, the VM and its stand-ins, the checklist for real hardware |
| [Brand](docs/brand.md) | Logo, colours and the trademark policy |

## Status

Tested in CI and in the VM. Not yet proven on a Pi with real TVs: the hardware checklist in
[docs/testing.md](docs/testing.md#on-a-pi) is next, and reports from your own hardware are welcome.

## Contributing and licence

Pull requests and hardware reports welcome: [CONTRIBUTING.md](CONTRIBUTING.md). Security reports:
[SECURITY.md](SECURITY.md).

[Apache-2.0](LICENSE). Copies and forks keep [NOTICE](NOTICE) and the file headers, which point back to this repo.
The licence grants no rights to the tvlink name or logo: a fork that is passed on is renamed and drops the logo
([docs/brand.md](docs/brand.md)).
