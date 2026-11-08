#!/bin/bash
# Install tvlink on Raspberry Pi OS Lite 64-bit (Trixie). Safe to rerun; also how a unit is updated.
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 cpwillis (https://github.com/seslhq/tvlink)
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run as root: sudo ./install.sh" >&2; exit 1; }
# Under the read-only overlay every change here would vanish at the next reboot.
! grep -q ' / overlay ' /proc/mounts || { echo "Overlay file system is on: turn it off and reboot first" >&2; exit 1; }
cd "$(dirname "$0")"
BOOT=/boot/firmware
CONF=$BOOT/tvlink.conf

apt-get update
# --no-upgrade: installed packages update on the unattended-upgrades schedule, and a held one does not stop this.
apt-get install -y --no-upgrade cage wlr-randr chromium v4l-utils unattended-upgrades curl python3-gpiozero \
  python3-lgpio

# Daily security updates, plus the Raspberry Pi repo that ships Chromium.
cat >/etc/apt/apt.conf.d/52tvlink <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
Unattended-Upgrade::Origins-Pattern { "origin=Raspberry Pi Foundation"; };
EOF

# The browser runs as kiosk: never an admin account. Its seat (cage, via logind) needs only render, and it may not
# use polkit actions (power off, network settings) or cron.
! id -nG kiosk 2>/dev/null | grep -qwE 'sudo|adm' ||
  { echo "User kiosk is an admin: image the Pi with another user name" >&2; exit 1; }
id kiosk >/dev/null 2>&1 || useradd -M -d /home/kiosk -s /usr/sbin/nologin kiosk
# Its home is root's and empty, so it can plant nothing that runs later (user units, Python user site, autostart);
# the session's HOME is /run/tvlink (tvlink.service). An older kiosk-owned home goes (rm doesn't follow its links).
[ "$(stat -c %U /home/kiosk 2>/dev/null)" = root ] || rm -rf /home/kiosk
install -d -o root -g root -m 755 /home/kiosk
usermod -G render kiosk
mkdir -p /etc/polkit-1/rules.d
printf 'polkit.addRule(function (a, s) { if (s.user == "kiosk") return polkit.Result.NO; });\n' \
  >/etc/polkit-1/rules.d/10-tvlink.rules
grep -qx kiosk /etc/cron.deny 2>/dev/null || echo kiosk >>/etc/cron.deny

install -m 755 tvlink tvlink-power tvlink-agent /usr/local/bin/
install -m 644 tvlink.service tvlink-power.service tvlink-net.service tvlink-reboot.service tvlink-reboot.timer \
  /etc/systemd/system/
install -D -m 644 splash.html /usr/share/tvlink/splash.html
[ -e "$CONF" ] || install -m 644 tvlink.conf.example "$CONF"
install -d "$BOOT/tvlink" # local content, see SOURCE
settings=$(TVLINK_CONF="$CONF" ./tvlink show)

# Upgrades install at 02:30 so the 03:30 reboot loads them. Canary units (UPDATE_DAY blank) every day; the rest only
# on UPDATE_DAY, days later, leaving time to hold a bad package (apt-mark hold). No mid-day catch-up after a cut.
UPDATE_DAY=$(sed -n 's/^UPDATE_DAY=//p' <<<"$settings")
mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d /etc/systemd/system.conf.d /etc/NetworkManager/conf.d \
  /etc/chromium/policies/managed
printf '[Timer]\nOnCalendar=\nOnCalendar=%s*-*-* 02:30\nRandomizedDelaySec=15m\nPersistent=false\n' \
  "${UPDATE_DAY:+$UPDATE_DAY }" >/etc/systemd/system/apt-daily-upgrade.timer.d/tvlink.conf
# A hung kernel reboots the Pi (15 s is the most every Pi watchdog driver accepts). Applies from the next boot.
printf '[Manager]\nRuntimeWatchdogSec=15\nRebootWatchdogSec=10min\n' >/etc/systemd/system.conf.d/tvlink.conf
# Wi-Fi power save causes most Pi signage drop-outs: off, in raspi-config's own file.
printf '[connection]\nwifi.powersave = 2\n' >/etc/NetworkManager/conf.d/default-wifi-powersave-off.conf
# A keyboard plugged into the Pi can't open DevTools, browser pages or file dialogs, and pages can't download;
# remote debugging (CDP) is unaffected.
printf '{"URLBlocklist": ["devtools://*", "view-source:*", "chrome://*"], "AllowFileSelectionDialogs": false,
 "DownloadRestrictions": 3}\n' >/etc/chromium/policies/managed/tvlink.json

# Kernel command line: HDMI mode, no console blanking, and no boot text or cursor, so the TV goes from black to the
# splash. Boot logs stay in journalctl. Keep the original once.
RESOLUTION=$(sed -n 's/^RESOLUTION=//p' <<<"$settings")
[ -e "$BOOT/cmdline.txt.orig" ] || cp "$BOOT/cmdline.txt" "$BOOT/cmdline.txt.orig"
ours='^(video=HDMI-A-[0-9]+:.*|consoleblank=.*|quiet|loglevel=.*|logo\.nologo|vt\.global_cursor_default=.*)$'
cmd=$(tr ' ' '\n' <"$BOOT/cmdline.txt" | grep -vE "$ours" | paste -sd' ' -)
cmd+=" consoleblank=0 quiet loglevel=3 logo.nologo vt.global_cursor_default=0"
[ "$RESOLUTION" = auto ] || cmd+=" video=HDMI-A-1:$RESOLUTION video=HDMI-A-2:$RESOLUTION"
# Only when it changes, and beside then rename: a cut mid-write must never leave a cmdline.txt the Pi can't boot.
if [ "$cmd" != "$(cat "$BOOT/cmdline.txt")" ]; then
  echo "$cmd" >"$BOOT/cmdline.txt.tmp"
  sync "$BOOT/cmdline.txt.tmp"
  mv -f "$BOOT/cmdline.txt.tmp" "$BOOT/cmdline.txt"
  sync -f "$BOOT/cmdline.txt"
  echo "cmdline.txt changed: reboot to apply it"
fi
# No rainbow screen from the firmware.
grep -q '^disable_splash=1' "$BOOT/config.txt" || printf '\n[all]\ndisable_splash=1\n' >>"$BOOT/config.txt"

# Raspberry Pi Connect (preinstalled on Lite) runs as the admin user's service: keep it up without a login.
[ -z "${SUDO_USER:-}" ] || loginctl enable-linger "$SUDO_USER"

systemctl daemon-reload
systemctl enable tvlink.service tvlink-power.service tvlink-net.service tvlink-reboot.timer
# An update takes effect now; a first install starts at the next boot.
systemctl try-restart tvlink.service tvlink-power.service tvlink-net.service

echo "Installed tvlink $(./tvlink show | sed -n 's/^VERSION=//p'). First install: set BOARD_URL if needed, then reboot."
