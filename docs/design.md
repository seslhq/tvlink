# Design

tvlink is a player, not a signage platform: one page (or one folder) per screen, shown honestly, with the TV's power
handled and no site visits. The page is the content; tvlink keeps it on screen.

## Goals and non-goals

- Zero-touch after install: power cuts, network drops, browser crashes and TV power cycles recover by themselves.
- One setting per unit (the page link); everything else has a working default.
- An honest screen: never a browser error page, and a visible marker when what is shown is not live.
- Remote first: change, restart, check and see the screen without visiting.

Out of scope: playlists and per-item scheduling, video walls, touch or interactive kiosks, anything drawn inside the
page itself (eg pixel shift or a night theme), captive portals and WPA-Enterprise, and TVs that answer neither CEC,
infrared discrete codes nor the HDMI signal.

## Parts

| Part | Runs as | Does |
| --- | --- | --- |
| `tvlink` | root or kiosk | The CLI, the settings parser and the kiosk launcher. `tvlink kiosk` starts the status loop and cage. |
| status loop (in `tvlink kiosk`) | kiosk | Probes the page (HTTP below 500 counts as up), scans the local folder, and writes `/run/tvlink/status.js` |
| `splash.html` | Chromium | Shows what the loop reports, plays local content, and hands over to the page once it answers |
| `tvlink-agent` | kiosk | Runs Chromium over a DevTools pipe: draws the badge, recovers crashed, frozen or error pages, takes requests (screenshot, identify, reload) |
| `tvlink-power` | root | The only process that turns the TV on and off by itself (CEC, IR or the HDMI signal), and the only user of the motion sensor: power modes, overrides (`tvlink override`), clock trust, power-cut handling |
| `tvlink net` | root | Turns the Wi-Fi keys into NetworkManager profiles held in RAM |
| `tvlink-console` | tvlink-console | The console: web pages and JSON API on port 80 ([console](console.md)); root only through sudo for a fixed list of `tvlink` commands |
| `tvlink-tunnel.service` | a throwaway user | Optional: cloudflared, a Cloudflare Tunnel to the console ([Cloudflare](cloudflare.md)) |
| `tvlink-console --fleet` | a throwaway user, on a server | Optional: the fleet console, every unit's pages through its API ([fleet](fleet.md)) |
| `tvlink-content` | root, no capabilities | Optional: syncs the files `CONTENT_URL`'s manifest lists to `/var/lib/tvlink/content` |
| `tvlink usb` (`tvlink-usb@.service`, from a udev rule) | root | Optional: mounts a USB stick with a `tvlink` folder read-only at `/run/tvlink-usb` |
| `tvlink lastgood` (`tvlink-lastgood.timer`) | root | Optional: copies the kiosk's last live screenshot to the card, hourly |
| `tvlink check` | root | Gate for the nightly reboot timer |
| `tvlink boot` | root | Writes `cmdline.txt` and `config.txt` from the settings; run by install.sh, `tvlink set` and `tvlink edid` |
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
- **TV power.** One process decides (`tvlink-power`), and `tvlink on|off|status` carries it out by `POWER_METHOD`, so
  every power mode works with every method. CEC through `cec-ctl`: a TV that drops hotplug in standby is woken from
  the unregistered address, the only message the kernel still lets through. The modes need only one thing from a
  method: whether `status` can be believed. `unknown` (IR, or a TV that never answered) means no re-wake checks, so a
  one-way method never loops; `standby` or `off` means wake again in on-time.
- **Overrides as instants, in tvlink-power.** An override replaces the mode's answer to "should the TV be on" and
  nothing else, so it reuses on-time and off-hours handling and works with every mode and method; manual modes, which
  have no answer, get one only while it lasts. Its end is stored as an absolute time (Unix seconds), not wall time, so
  restarts, reboots, clock changes and NTP jumps all leave it right; it is honoured only once the clock can be
  trusted. tvlink-power rereads the root-only file every second (cheap, no card writes) instead of being restarted,
  and its `override` subcommand holds the parsing, so the logic and its self-tests sit in one place. Without a length
  it ends at the next `TV_ON` or `TV_OFF`, the thermostat's "hold until the next change"; modes without hours need
  one, rather than a made-up default.
- **Infrared: discrete codes only, sourced or learned.** A toggle code can't be used without knowing the TV's state,
  which IR can't give, so the built-in table holds only discrete on and off codes with a cited source (IRDB, Tasmota's
  code list), and anything else is learned from the TV's own remote as raw pulses, which works for any protocol.
  `ir-ctl` from v4l-utils (already installed) sends through the kernel's `gpio-ir-tx` and records through `gpio-ir`,
  both `config.txt` overlays; the receiver maps no keys, so a remote can't type into the kiosk. Samsung's 32-bit
  protocol has no kernel encoder, so tvlink writes its pulses; the kernel's decoder reads them back as the same code.
- **Signal off through the kiosk.** tvlink-power is root and stays out of the kiosk's Wayland session: `tvlink on|off`
  writes the wanted signal to `/run/tvlink-display` (root's, readable by all) and asks the agent through the request
  file; the agent runs `tvlink mode` as the kiosk, which turns cage's outputs off or on with `wlr-randr`. It runs every
  30 s and after every kiosk start too, so the signal stays as asked across browser restarts. cage keeps running with
  no output on; Chromium does too, but makes no page without one, so the kiosk starts with the output on and the
  agent turns it off once the page is up. The agent skips the frozen-page check while the signal is off.
- **Boot files from the settings.** `tvlink boot` owns tvlink's arguments on `cmdline.txt` (mode, quiet boot,
  `vc4.force_hotplug`, `drm.edid_firmware`) and a marked block at the end of `config.txt` (IR overlays), leaves the
  rest alone, and writes only on a change, beside then renamed. `vc4.force_hotplug` is a bitmask per port (bit 0:
  HDMI0, in the Pi kernel's `vc4_hdmi.c`): tvlink sets 1, HDMI0 only, so the free port never shows as a screen.
  Captured EDIDs live in `/lib/firmware/edid/` (where `drm.edid_firmware` looks) and an initramfs-tools hook copies
  them into the initramfs, for a display driver loaded before the root file system.
- **Local content: one source, never merged.** A USB stick, synced content, then the SD card's folder: the first with
  files plays, so the screen shows one whole set and a half-copied stick never mixes with the fallback. The stick wins
  because someone put it there on purpose; synced content beats the card because it is the managed copy. The status
  loop rescans every 2 s (cheap: one folder listing each), so a stick pulled out stops playing within seconds.
- **USB sticks through udev and systemd, not udisks.** A rule hands a USB drive's FAT or exFAT file system to
  `tvlink-usb@.service`, bound to the device, so pulling it out stops the unit, which unmounts. `tvlink usb` mounts
  only with `USB_CONTENT=1`, only a disk with nothing else mounted (never a Pi booted from USB), one stick at a time,
  read-only with `nosuid,nodev,noexec`, files readable by all, owned by root; a stick without a `tvlink` folder is let
  go. Nothing is mounted for the kiosk user or by it.
- **Synced content: https only, checked, swapped whole.** `tvlink-content` runs as root with no capabilities and
  writes only its own folders, so the kiosk can read the files and change none. Manifest and files come over https
  only, redirects included; there is no switch for plain HTTP, not even for tests: the VM test serves https with its
  own CA, through `SSL_CERT_FILE`, which Python's `ssl` honours. Each file is checked against its listed size while it
  downloads and its SHA-256 after, into a new set beside the live one; a symlink renamed over `current` swaps the set
  in one step, and any failure keeps the old one. Unchanged files are hard links to the live set, and an unchanged
  manifest writes nothing. The set before stays until the next sync, so the splash never loses a file mid-show. A
  service with its own loop, not a timer: the interval is a setting, and a restart is "sync now".
- **Last good screen: the kiosk takes it, root keeps it.** The agent saves the live page (badge hidden) to its own
  `/run/tvlink` every 10 min; an hourly timer has root copy it to `/var/lib/tvlink/last.jpg`, which the kiosk can
  read but not write. Root reads the kiosk's file as the kiosk (`runuser`, with a timeout), so a link or FIFO planted
  there gets root nothing, and keeps only a newer JPEG. The card sees one small write an hour at most.
- **New links without the splash.** The status loop rereads the settings every 2 s, so `tvlink set BOARD_URL` needs no
  kiosk restart; the agent notes which link the page on screen came from, and when status.js says a different one
  answers, it opens it in a background tab (with the badge script in first), waits for the load to finish, checks it
  is no error page or 4xx/5xx, then activates it and closes the old tab. A failure keeps the old page and is retried
  each minute. `tvlink set` waits up to 45 s for the agent's word in the journal and prints it.
- **Daily browser restart in the agent.** The agent runs Chromium, so it restarts it alone: cage and the agent stay,
  the splash shows until the page answers. The time is an instant, as in tvlink-power; never in the first hour after
  boot, and not while the HDMI signal is off (Chromium makes no page then).
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
- **A console on every unit, on by default, claimed with a code.** Day-to-day management is the unit's own console;
  Raspberry Pi Connect or SSH stay as break-glass. It is on from the first install so a unit can be set up from a
  phone, but until a password is set it serves only the claim page, which needs a one-time code shown on the TV (and
  printed by `sudo tvlink console claim`): being on the network is not enough to take a unit. The code lives in
  `/run/tvlink-console`, readable by the splash; it is no secret from anyone who can read the TV.
- **Port 80, not 8080.** People type a unit's name, and a tunnel maps a hostname to it either way. The console binds
  port 80 as an unprivileged user through `AmbientCapabilities=CAP_NET_BIND_SERVICE`; nothing else on the unit
  listens. Plain HTTP on the LAN; HTTPS is the tunnel's job.
- **Privilege model.** The console runs as `tvlink-console` in a systemd sandbox (read-only system, private `/tmp`, no
  home directories, other users' processes hidden). Root is reachable only through `/etc/sudoers.d/tvlink-console`: an
  exact list of `/usr/local/bin/tvlink` subcommands, with wildcards only after `set`, `update` and `override`,
  which check every argument themselves. sudo is setuid, so the unit can't use `NoNewPrivileges` or the settings that imply it. A
  process started by sudo inherits the sandbox, so `tvlink` reruns itself with `systemd-run` when sudo starts it for
  the console: its commands then run as from a root shell. sudo does not log these commands, since `tvlink set` can
  carry a Wi-Fi password. Machine-readable subcommands (`tvlink keys --json`, `tvlink logs`) keep the console from
  parsing human output; the settings form is built from `tvlink keys --json`, so a new key shows up by itself.
- **Tunnel: Cloudflare, one per unit, opt-in.** `TUNNEL_TOKEN` is the only setting: a unit without it has no
  cloudflared and no extra apt repo, so behaviour is unchanged. Setting it installs cloudflared from Cloudflare's own
  apt repo on demand (not in install.sh: most units never need it, and the token is set after install anyway), and
  unattended-upgrades then keeps it current with the staged updates. The token lives in `/etc/tvlink`, root-only,
  not on the FAT card any PC can read; systemd passes it to cloudflared (a `DynamicUser`) as a credential file for
  `--token-file`, so it is never on a command line. Remotely managed tunnels keep the hostname and the route to
  `http://localhost:80` in the dashboard, so the unit holds one secret and no tunnel config. cloudflared's `/ready`
  on loopback gives the state for `tvlink doctor` and the console. A tunnel per unit, not one shared: each can be
  revoked alone, and each unit gets a first-level hostname that Cloudflare's free certificate covers.
- **No trusted headers.** Cloudflare Access is a gate in front, not the console's login: a session or an API token is
  always needed. Headers only decide the cookie's `Secure` flag (`Cf-Visitor`, `X-Forwarded-Proto`) and, from
  loopback only, which visitor the login limit counts (`Cf-Connecting-IP`).
- **Fleet mode in the same file.** `tvlink-console --fleet` serves the same pages for any unit: the page code takes its
  data from a backend with the same calls, `LOCAL` (this unit, through `tvlink`) or `Remote` (a unit's JSON API with
  its API token and an Access service token), so there is one set of forms and one place to fix them. The fleet keeps
  its own password, claim code and units list (fleet user only), never follows redirects (they would carry the
  tokens), and asks all units at once with a 4 s cap, keeping what each said last in memory. It needs nothing but
  Python 3, so it runs on any server; it listens on loopback for its own tunnel.
- **Logins kept simple.** One password per unit (PBKDF2-SHA256), sessions in memory, a CSRF token on every change, a
  login rate limit, and per-unit API tokens stored hashed for fleet tools. No accounts, no roles: anyone who can log
  in can do everything, including updates.

## Platform facts

| Fact | Consequence |
| --- | --- |
| Raspberry Pi OS Lite is Trixie: Python 3.13, NetworkManager, Chromium as `chromium`, cage 0.3 in the Raspberry Pi repo | Trixie only |
| cage takes the TV's preferred mode and ignores `video=`, but supports `wlr-randr` | Mode set inside cage |
| cage has no output power protocol, but `wlr-randr` can turn its only output off and on, and it keeps running | `POWER_METHOD=signal`; CEC by default |
| Chromium makes no page while no output is on | The kiosk starts with the signal on, then turns it off |
| `ir-ctl` encodes NEC, RC5, RC6, Sony, JVC, Sanyo, Sharp, iMON and RC-MM, not Samsung32 or Kaseikyo (Panasonic) | Samsung pulses built by tvlink; Panasonic learned |
| Chromium's debugging port has no authentication | Pipe instead of a port |
| The Pi 5 has no hardware H.264 decoder and Chromium has no HEVC path there | Local video is H.264 1080p30 |
| Each HDMI port has a CEC adapter; with hotplug down only Image View On from Unregistered gets through | Unregistered wake |
| The Pi 5 RTC keeps time across a power cut only with a battery | Clock trust rule; battery recommended |
| A Pi 5 boots by itself when power returns, but halt needs a power cycle | Reboot remotely, never halt |
| unattended-upgrades applies only Debian origins by default | install.sh adds `origin=Raspberry Pi Foundation` |
| Wi-Fi power save is on by default | Turned off in raspi-config's own file |
| Trixie keeps the journal in RAM and uses zram swap | Fewer card writes; diagnose live |
