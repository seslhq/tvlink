# Design

tvlink is a player, not a signage platform: one page (or one folder) per screen, shown honestly, with the TV's power
handled and no site visits. The page is the content; tvlink keeps it on screen.

## Goals and non-goals

- Zero-touch after install: power cuts, network drops, browser crashes and TV power cycles recover by themselves.
- One setting per unit (the page link); everything else has a working default.
- An honest screen: never a browser error page, and a visible marker when what is shown is not live.
- Remote first: change, restart, check and see the screen without visiting.

Out of scope: playlists and per-item scheduling, video walls, touch or interactive kiosks, anything drawn inside the
page itself (eg pixel shift or a night theme), captive portals and WPA-Enterprise, and TVs without working CEC.

## Parts

| Part | Runs as | Does |
| --- | --- | --- |
| `tvlink` | root or kiosk | The CLI, the settings parser and the kiosk launcher. `tvlink kiosk` starts the status loop and cage. |
| status loop (in `tvlink kiosk`) | kiosk | Probes the page (HTTP below 500 counts as up), scans the local folder, and writes `/run/tvlink/status.js` |
| `splash.html` | Chromium | Shows what the loop reports, plays local content, and hands over to the page once it answers |
| `tvlink-agent` | kiosk | Runs Chromium over a DevTools pipe: draws the badge, recovers crashed, frozen or error pages, takes requests (screenshot, identify, reload) |
| `tvlink-power` | root | The only user of CEC and the motion sensor: power modes, clock trust, power-cut handling |
| `tvlink net` | root | Turns the Wi-Fi keys into NetworkManager profiles held in RAM |
| `tvlink check` | root | Gate for the nightly reboot timer |
| `install.sh` | root | Installs or updates everything; safe to rerun |

One prober feeds everyone: the splash reads `status.js` as JSONP from `file://`, and the agent reads the same file for
the badge. The page never calls the Pi (Chrome's Local Network Access rules would block it); the agent pushes the
badge state in over the DevTools pipe instead.

## Decisions

- **cage and Chromium, Raspberry Pi OS Lite Trixie only.** cage shows one app full screen and hides the cursor
  without a mouse. It ignores `video=`, so the kiosk sets `RESOLUTION` with `wlr-randr` and repeats it every 30 s for
  TVs that come back from standby at their own mode.
- **DevTools over a pipe, not a port.** `--remote-debugging-pipe` gives the agent Chromium's protocol with no TCP
  port, no websocket library and no origin rules. The agent is Python standard library only and needs no root.
- **Recovery.** A crashed tab, two missed health checks in a row, a Chromium error page, or a 5xx page while the probe
  says the server is up: go back to the splash, which hands over again when the page answers. At most once a minute;
  after three tries in 10 minutes the browser restarts. An empty 404 or 410 is the server's own answer, so it stays
  with `Board not found` on the badge.
- **Badge order.** First match wins: `Clock not set`, red `Offline` (no route or no answer), amber `Cached` (the
  server answers with an error), amber `Board not found` (404 or 410); otherwise live, with the network type and the
  time the page last answered.
- **One settings file, never run.** `tvlink` holds the only parser: known keys only, a later line wins, quotes and
  notes handled, odd encodings tolerated. Everything else reads `tvlink show`. Writes go beside the file, then flush,
  rename and flush again, so a power cut leaves the old file or the new one. It lives on the FAT boot partition so
  any PC can edit it.
- **Clock trust.** On-hours run only once NTP has synced this boot or the RTC holds a sane date; until then the TV
  stays on. Motion timing uses the monotonic clock. On-hours compare instants, not wall time, so a `TV_ON` or
  `TV_OFF` in the hour repeated when clocks go back acts once.
- **TV power.** CEC only, through `cec-ctl`, by one process. A TV that drops hotplug in standby is woken from the
  unregistered address, the only message the kernel still lets through.
- **Nightly reboot as the backstop.** At 03:30, never in the first hour after boot, never while an upgrade runs, and
  skipped for up to a week while a configured page is down, so an outage keeps the last good screen.
- **Staged updates.** unattended-upgrades for Debian and the Raspberry Pi repo at 02:30: canary units nightly, the
  rest weekly on `UPDATE_DAY`, so a bad package can be held before it reaches everyone.
- **Cards last.** The kiosk session's `HOME` is the service's runtime dir in RAM, emptied at every start: Chromium's
  profile and crash reports, NSS and Mesa's shader cache (capped at 16 MB) all land there. Component downloads are
  off, so `/run` never fills. The journal is volatile, and boot-partition writes are rare and atomic.
- **The kiosk user is boxed in.** The browser runs as `kiosk`: the render group only, no polkit rights, no cron, a
  home owned by root that it can't write (so nothing it plants runs later: user units, Python's user site,
  autostart), a managed policy blocking DevTools, browser pages, file dialogs and downloads. Root hands it requests
  through files in `/run/tvlink`, without a controlling terminal.
- **Watchdog and Wi-Fi.** systemd's hardware watchdog reboots a hung kernel; Wi-Fi power save is off.
- **Remote access is not tvlink's job.** Raspberry Pi Connect (or any shell) reaches the CLI; tvlink opens no port.

## Platform facts

| Fact | Consequence |
| --- | --- |
| Raspberry Pi OS Lite is Trixie: Python 3.13, NetworkManager, Chromium as `chromium`, cage 0.3 in the Raspberry Pi repo | Trixie only |
| cage takes the TV's preferred mode and ignores `video=`, but supports `wlr-randr` | Mode set inside cage |
| cage has no output power protocol | TV power over CEC, not by blanking the signal |
| Chromium's debugging port has no authentication | Pipe instead of a port |
| The Pi 5 has no hardware H.264 decoder and Chromium has no HEVC path there | Local video is H.264 1080p30 |
| Each HDMI port has a CEC adapter; with hotplug down only Image View On from Unregistered gets through | Unregistered wake |
| The Pi 5 RTC keeps time across a power cut only with a battery | Clock trust rule; battery recommended |
| A Pi 5 boots by itself when power returns, but halt needs a power cycle | Reboot remotely, never halt |
| unattended-upgrades applies only Debian origins by default | install.sh adds `origin=Raspberry Pi Foundation` |
| Wi-Fi power save is on by default | Turned off in raspi-config's own file |
| Trixie keeps the journal in RAM and uses zram swap | Fewer card writes; diagnose live |
