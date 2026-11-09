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
- Optional: a motion sensor, an IR LED and receiver (below). PoE needs a third-party Pi 5 PoE+ HAT that clears the
  Active Cooler.
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
2. Boot the Pi with a TV attached and install tvlink from a shell on it (eg `ssh <user>@tv-lobby-01.local`, `<user>`
   being the Imager user):

   ```bash
   curl -fsSL https://raw.githubusercontent.com/seslhq/tvlink/main/get.sh | sudo bash
   ```

   It downloads `main` from GitHub over HTTPS into a temporary folder, unpacks it whole, runs its `install.sh` and
   cleans up. `... | sudo bash -s -- <commit>` installs a commit (or a branch or tag) instead. Anything but Raspberry
   Pi OS or Debian Trixie on arm64 is refused unless given `--force`. Or install from a clone on your computer:

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
`standby`. A model that fails can use infrared (below) or the HDMI signal (`POWER_METHOD=signal`, for a TV that sleeps
without a signal and wakes with one), or `POWER_METHOD=none` with `POWER_MODE=always` or `manual`, relying on its own
settings ([power methods](configuration.md#power-methods)).

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

A TV that drops hotplug in standby, sits on another input, or is off when the Pi boots can leave the Pi with no
screen or the wrong modes. With the TV on and showing the Pi, keep its EDID and ignore hotplug, then reboot:

```bash
sudo tvlink edid capture
sudo tvlink set HDMI_FORCE_HOTPLUG=1
sudo reboot
```

`sudo tvlink doctor` shows both on its `HDMI at boot` line; `sudo tvlink edid clear` and `HDMI_FORCE_HOTPLUG=0` undo
them. The EDID goes to `/lib/firmware/edid/` and into the initramfs, so a display driver loaded from it finds it too.

## Motion sensor

For `POWER_MODE=motion` or `manual+motion` ([power modes](configuration.md#power-modes)).

- An HC-SR501 PIR module: VCC to pin 2 (5 V), GND to pin 6, OUT to pin 11 (GPIO17). Set its delay pot to minimum
  (the Pi times `IDLE_MIN`) and its jumper to repeat trigger. Mount it near the entry, facing into the room, away from
  the TV, vents and windows.
- Where people sit still, an HLK-LD2410 mmWave sensor on the same pins (5 V, at least 200 mA): it holds its output
  high while anyone is present.
- A missing gpiozero or a bad pin is logged; an unwired sensor just reads no motion. Either way `motion` keeps its
  on-hours and `manual+motion` acts as `manual`.

## IR transmitter and receiver

For `POWER_METHOD=ir` ([power methods](configuration.md#power-methods)). Turn off the Pi before wiring.

- Transmitter: a 940 nm IR LED, driven by an NPN transistor (eg 2N2222 or BC337), since a GPIO gives too little
  current. GPIO18 (pin 12) through 1 kΩ to the base; emitter to GND (pin 14); 5 V (pin 4) through 68 Ω to the LED's
  anode, its cathode to the collector (about 50 mA pulses). Put the LED a few centimetres from the TV's IR window, or
  on a lead taped beside it, pointing in.
- Receiver, only to learn codes: a 38 kHz IR receiver module such as a TSOP38238, run from 3.3 V so its output is
  safe for the Pi: VS to 3.3 V (pin 17), GND to pin 20, OUT to GPIO23 (pin 16).
- Other pins: `IR_TX_PIN` and `IR_RX_PIN` (BCM numbers); blank `IR_RX_PIN` for no receiver.

Then set it up and reboot (the overlays go in `config.txt`):

```bash
sudo tvlink set POWER_METHOD=ir IR_CODES=samsung   # or lg, sony, toshiba, or learned
sudo reboot
sudo tvlink ir test off; sudo tvlink ir test on      # the TV should follow each
```

To learn codes instead: `sudo tvlink ir learn on`, press the remote's power on button at the receiver, then the same
for `off`, then `sudo tvlink set IR_CODES=learned`. Learn discrete power on and power off buttons (a universal or
hotel remote often has them); a single power toggle can't work, since the Pi can't see which way the TV went. Learned
codes are in `/var/lib/tvlink/ir/` (root only, on the card's root partition).
