# Configuration

All settings live in `/boot/firmware/tvlink.conf`, on the SD card's boot partition (the drive called `bootfs` on any
PC). Change them in the console's Settings and Wi-Fi pages ([console](console.md)) or with `tvlink set`, which checks
each value, writes the file safely and restarts what uses it:

```bash
sudo tvlink set POWER_MODE=motion IDLE_MIN=20
sudo tvlink set TV_ON=07:00 TV_OFF=21:30
sudo tvlink set BOARD_URL=https://dashboard.example.com/board
tvlink show
```

After a hand edit, reboot or run `sudo systemctl restart tvlink tvlink-power tvlink-net`. Put notes on their own
line starting with `#`; quote values with spaces or `#`. `tvlink show` prints what tvlink actually reads, with
passwords and the tunnel token masked. The file is only ever read, never run, and a bad value falls back to its default.

| Key | Default | Meaning |
| --- | --- | --- |
| `BOARD_URL` | (blank) | http(s) page to show full screen. Blank: local content only. |
| `SOURCE` | `auto` | `auto` (the page, else local content) or `folder` (local content only). |
| `SLIDE_SECONDS` | `10` | Seconds per image in local content. |
| `FIT` | `contain` | `contain` (whole image) or `cover` (fill, crop the edges). |
| `POWER_MODE` | `schedule` | `always`, `schedule`, `motion`, `manual` or `manual+motion` (below). |
| `TV_ON` | `06:00` | Start of on-hours, Pi local time. Blank: always on. |
| `TV_OFF` | `22:00` | End of on-hours. Earlier than `TV_ON` runs past midnight. |
| `IDLE_MIN` | `15` | `motion`: minutes without motion before standby outside on-hours. `manual+motion`: quiet minutes before motion wakes the TV again. |
| `MOTION_PIN` | `17` | GPIO (BCM number) wired to the motion sensor's output. |
| `POWER_METHOD` | `cec` | How the Pi turns the TV on and off: `cec`, `ir`, `signal` or `none` ([below](#power-methods)). The old `CEC=0` still means `none` when this key is absent. |
| `IR_CODES` | `learned` | `ir`: a brand's built-in codes (`lg`, `samsung`, `sony`, `toshiba`), or `learned` (`tvlink ir learn`). |
| `IR_TX_PIN` | `18` | `ir`: GPIO (BCM number) driving the IR LED. Reboot to apply. |
| `IR_RX_PIN` | `23` | `ir`: GPIO (BCM number) of the IR receiver, to learn codes; blank: none. Reboot to apply. |
| `RESOLUTION` | `1920x1080@60` | HDMI mode, eg `1280x720@60`; `auto`: the TV's preferred mode. |
| `OVERLAY_CORNER` | `bottom-right` | Corner of the status badge: `bottom-right`, `bottom-left`, `top-right`, `top-left` or `off`. |
| `WIFI_COUNTRY` | (blank) | Wi-Fi country code, eg `AU`. Blank keeps the one set in Imager. |
| `WIFI1_SSID`, `WIFI1_PSK` | (blank) | A Wi-Fi network and its password (blank password: an open network). Hidden networks work. |
| `WIFI2_SSID`, `WIFI2_PSK` | (blank) | A second network, eg the next one when a site changes its Wi-Fi. |
| `TUNNEL_TOKEN` | (blank) | A Cloudflare Tunnel token: the console from anywhere over HTTPS ([Cloudflare](cloudflare.md)). Kept root-only in `/etc/tvlink/tunnel-token`, never in this file; set and cleared only with `tvlink set` or the console. Blank: no tunnel. |
| `UPDATE_DAY` | (blank) | Blank: security updates every night (canary units). `Mon` to `Sun`: weekly on that day, after the canaries. Applied by rerunning install.sh. |

Settings that change `cmdline.txt` or `config.txt` (`RESOLUTION`, `POWER_METHOD`, the IR pins) say `Reboot to
apply` when they do; `tvlink set` writes those files the same safe way as the settings file.

Pages are best designed at 1920x1080: 1080p keeps a 4K TV sharp enough and the Pi cool. A mode the TV refuses is
logged and the TV's own mode stays.

## Power modes

Consumer TVs are built for a few hours a day, so pick the least on-time that suits the room.

| Mode | The TV is on | The Pi sends standby | Use when |
| --- | --- | --- | --- |
| `always` | 24/7 | Never | The page must be visible at all hours |
| `schedule` | `TV_ON` to `TV_OFF` | At `TV_OFF` | The site is staffed at set hours |
| `motion` | As `schedule`, plus whenever the sensor sees someone outside those hours | At `TV_OFF`, and after `IDLE_MIN` without motion outside on-hours | Anyone who walks in should see the page |
| `manual` | Whenever someone turns it on with the TV remote | Never | People decide; the Pi stays out of the way |
| `manual+motion` | As `manual`, and the sensor wakes it when someone arrives after `IDLE_MIN` with nobody seen | Never | No fixed hours, but people should see the page as they come in |

- On-time starts by waking a TV in standby and switching it to the Pi's input; a TV already on keeps its input.
  During on-time a TV that reports standby, or that answered before and went silent, is woken again within 5 min,
  whatever put it there, including the remote.
- A TV that never answers CEC power queries is woken when on-time starts only, so its input is not grabbed every
  5 min.
- Any start in off-hours sends one standby. After a power cut it is re-sent for 10 min, because many TVs come back
  on by themselves a little later.
- On-hours need the right time: until the clock has synced over the network (or the RTC battery holds it), the TV
  stays on and the log says so.
- `manual` wakes the TV after a power cut (any boot that was not the nightly reboot), retrying for up to 10 min.
- `manual+motion` never sends standby: a TV switched off while people are still in the room stays off until the next
  arrival. With a PIR, people sitting still for `IDLE_MIN` count as gone; use an mmWave sensor where people sit.
- `schedule` and `motion` need different `TV_ON` and `TV_OFF`; otherwise, or with an unknown mode, the Pi uses
  `always` and logs why.

## Power methods

Every power mode works with every method; only what the Pi can learn about the TV differs.

| Method | On and off | `tvlink status` | Use when |
| --- | --- | --- | --- |
| `cec` | HDMI-CEC: wake and switch to the Pi's input, standby | `on`, `standby` or `unknown`, from the TV | The TV's CEC works (test it first: [setup](setup.md#tv-settings-and-hdmi-cec)) |
| `ir` | Infrared discrete power on and power off codes, from an IR LED on `IR_TX_PIN` | `unknown`: IR is one-way | CEC is missing or unreliable and the TV has discrete codes ([wiring](setup.md#ir-transmitter-and-receiver)) |
| `signal` | The Pi's HDMI output off and on | `on` or `off`, as last sent | The TV sleeps when it loses the signal and wakes when it comes back |
| `none` | Nothing | `unknown` | The TV's own timers or people handle it |

- `ir` with a TV that never reports its state: codes are sent when on-time starts and ends, at any start in off-hours,
  and after a power cut (standby re-sent for 10 min, `manual` wakes retried for 10 min), as for a TV that never
  answers CEC. There is no 5-minute re-wake: the Pi can't see a TV turned off by hand.
- `ir` codes: built-in discrete codes for `lg`, `samsung`, `sony` and `toshiba` (sources in `tvlink`), sent three
  times 40 ms apart. Other brands, or a model that ignores them, use learned codes: `sudo tvlink ir learn on`, then
  `off`, pressing the TV remote's discrete power on and off buttons (a universal or service remote has them; a
  single power toggle can't work, as the Pi can't tell which way it went). `sudo tvlink ir test on` sends once.
  Panasonic (Kaseikyo, which `ir-ctl` can't encode), Philips, Hisense and TCL have no built-in codes: learn them.
- `signal`: the Pi knows only what it sent. A signal turned off from the console in on-time comes back within 5 min;
  a TV turned off with its own remote still has a signal, so the Pi can't wake it. The signal also comes on whenever
  the Pi boots (including the nightly reboot at 03:30) and for a few seconds when the kiosk restarts, so such a TV may
  wake then and sleep again on its own no-signal timer. The page keeps running in the dark; a crashed page is still
  recovered, and the frozen-page check pauses, so a dark screen is never taken for a fault.

## Local content

Put files in the `tvlink` folder on the boot partition (`/boot/firmware/tvlink/` on the Pi). New files show within
90 s.

- Images (`jpg`, `png`, `webp`, `gif`, `svg`) show for `SLIDE_SECONDS` each; `name.30s.jpg` sets its own time. Size
  them to 1920x1080.
- Videos: MP4, H.264, 1080p at 30 fps, about 8 Mb/s or less. They play muted to the end; a single video loops. HEVC,
  VP9 and 4K do not play in Chromium on a Pi 5.
- Files play in name order, so prefix numbers: `01-welcome.png`, `02-safety.mp4`.
- An `index.html` there is shown as a web page.
- Keep the folder under 200 MB: kernel updates share that partition.

With `SOURCE=auto` the folder covers outages: on a cold boot without network it plays until the page answers. Once
the page is up it stays on the page. A single fallback image is a good default for any site.
