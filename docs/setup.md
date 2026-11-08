# Setup

## Hardware

- Raspberry Pi 5, 1 GB.
- Official 27 W USB-C power supply in a wall socket, never a TV's USB port (undervoltage is the most common cause of
  a flaky Pi).
- Official Active Cooler: behind a TV the Pi throttles without it.
- High-endurance A2 microSD card, 32 GB.
- Micro-HDMI to HDMI cable, in HDMI0 (the port next to the USB-C power socket).
- Optional: the official rechargeable RTC battery, for `schedule` and `motion` and for sites without reliable
  internet (it keeps the clock across power cuts). Turn on charging for that rechargeable cell only:
  `dtparam=rtc_bbat_vchg=3000000` in `/boot/firmware/config.txt`.
- Optional: a motion sensor (below). PoE needs a third-party Pi 5 PoE+ HAT that clears the Active Cooler.
- A spare set (Pi, card, power supply, cable) for every handful of units.

## Provisioning a unit

Image every unit fresh; never clone a configured card (clones share SSH host keys and the remote access identity).

1. In Raspberry Pi Imager 2 or later pick Raspberry Pi 5, then Raspberry Pi OS Lite (64-bit), Trixie. In its
   settings set:
   - the hostname, which is also the label on the unit (eg `tv-lobby-01`);
   - a user with a strong, unique password (any name but `kiosk`, which tvlink uses for the browser);
   - the time zone of the site (on-hours use Pi local time);
   - Wi-Fi if there is no Ethernet;
   - SSH with public-key authentication only.
2. Boot the Pi with a TV attached, copy tvlink to it and install (`<user>` is the Imager user):

   ```bash
   git clone https://github.com/seslhq/tvlink
   scp -r tvlink <user>@tv-lobby-01.local:
   ssh -t <user>@tv-lobby-01.local sudo ./tvlink/install.sh
   ```

3. Claim the console: open `http://tv-lobby-01.local` on a phone or laptop on the same network, enter the code the
   TV shows (or `sudo tvlink console claim` prints) and choose its password ([console](console.md)).
4. Set the page in the console's Settings, or `sudo tvlink set BOARD_URL=https://...`; leave it blank for local
   content only ([configuration](configuration.md)).
5. Test the TV: `sudo tvlink off`, wait 10 s, `sudo tvlink on`, then `tvlink status` should say `on`. If not, see
   the CEC section below.
6. Break-glass access: `rpi-connect on`, then `rpi-connect signin` with a shared fleet Raspberry Pi ID (2FA on),
   never a personal one.
7. `sudo reboot`. Check the page comes up and `rpi-connect status` shows signed in, then label the unit with its
   hostname.

## TV settings and HDMI-CEC

tvlink drives the TV with `cec-ctl` over the Pi 5's built-in CEC. Test every TV model before buying more of it:
`sudo tvlink off`, `sudo tvlink on` (note how long the picture takes), and `tvlink status` answering `on` or
`standby`. A model that fails runs with `CEC=0` and `POWER_MODE=always` or `manual`, relying on its own settings.

CEC is usually off by default and has a brand name in the TV menu: Samsung Anynet+, LG SimpLink, Sony BRAVIA Sync,
Panasonic VIERA Link, Philips EasyLink, Toshiba CE-Link or REGZA Link; Hisense and TCL usually HDMI-CEC or T-Link.

Set once in each TV's menu, and photograph the settings for the site record:

- CEC on (the brand name above).
- Auto standby off (often after 4 hours without the remote), except in `manual` mode.
- No-signal auto-off long or off; power-on input: last input or HDMI 1.
- Power state after a power cut: on, or last state.
- Picture size: Just Scan, Screen Fit or 1:1 (overscan off), so nothing at the edges is cut off.
- Energy saving on, backlight about 60%, store or demo mode off, on-screen notifications off.
- An air gap behind the TV, and the Pi out of the TV's exhaust. Buy LCD, not OLED (burn-in).

Some TVs drop HDMI hotplug in standby. The Pi then has no CEC address, and only a wake can still get through:
`tvlink on` sends it from the unregistered address. If the picture comes back at the wrong mode after a wake, the
kiosk sets `RESOLUTION` again within 30 s.

## Motion sensor

For `POWER_MODE=motion` or `manual+motion` ([power modes](configuration.md#power-modes)).

- An HC-SR501 PIR module: VCC to pin 2 (5 V), GND to pin 6, OUT to pin 11 (GPIO17). Set its delay pot to minimum
  (the Pi times `IDLE_MIN`) and its jumper to repeat trigger. Mount it near the entry, facing into the room, away from
  the TV, vents and windows.
- Where people sit still, an HLK-LD2410 mmWave sensor on the same pins (5 V, at least 200 mA): it holds its output
  high while anyone is present.
- A missing gpiozero or a bad pin is logged; an unwired sensor just reads no motion. Either way `motion` keeps its
  on-hours and `manual+motion` acts as `manual`.
