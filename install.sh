#!/bin/bash
# Install tvlink on Raspberry Pi OS Lite 64-bit (Trixie). Safe to rerun; also how a unit is updated.
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 cpwillis (https://github.com/seslhq/tvlink)
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run as root: sudo ./install.sh" >&2; exit 1; }
# Under the read-only overlay every change here would vanish at the next reboot.
! grep -q ' / overlay ' /proc/mounts ||
  { echo "The read-only root is on: turn it off (sudo tvlink overlay off) and reboot first" >&2; exit 1; }
cd "$(dirname "$0")"
BOOT=/boot/firmware
CONF=$BOOT/tvlink.conf

apt-get update
# --no-upgrade: installed packages update on the unattended-upgrades schedule, and a held one does not stop this.
apt-get install -y --no-upgrade cage wlr-randr chromium v4l-utils unattended-upgrades curl python3-gpiozero \
  python3-lgpio sudo dnsmasq-base # dnsmasq: addresses for the setup hotspot (NetworkManager's shared mode)

# Daily security updates, plus the Raspberry Pi repo that ships Chromium, and Cloudflare's for cloudflared on units
# with a tunnel (tvlink set TUNNEL_TOKEN adds it).
cat >/etc/apt/apt.conf.d/52tvlink <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
Unattended-Upgrade::Origins-Pattern { "origin=Raspberry Pi Foundation"; "origin=cloudflared"; };
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

# The unit console runs as its own user, with root only for the tvlink commands in its sudoers file.
id tvlink-console >/dev/null 2>&1 || useradd --system -M -d /nonexistent -s /usr/sbin/nologin tvlink-console
visudo -cqf tvlink-console.sudoers || { echo "tvlink-console.sudoers does not parse" >&2; exit 1; }
install -m 440 tvlink-console.sudoers /etc/sudoers.d/tvlink-console

install -m 755 tvlink tvlink-power tvlink-agent tvlink-console tvlink-content tvlink-hotspot /usr/local/bin/
install -m 644 tvlink.service tvlink-power.service tvlink-net.service tvlink-reboot.service tvlink-reboot.timer \
  tvlink-console.service tvlink-tunnel.service tvlink-content.service tvlink-usb@.service tvlink-lastgood.service \
  tvlink-lastgood.timer tvlink-hotspot.service /etc/systemd/system/
# USB sticks go to tvlink-usb@ (USB_CONTENT); /var/lib/tvlink holds synced content and the last good screen, which
# the kiosk reads.
install -m 644 90-tvlink-usb.rules /etc/udev/rules.d/
udevadm control --reload
install -d -m 755 /var/lib/tvlink
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
# Under the read-only root (tvlink overlay) downloads and upgrades would land in RAM and be gone at the next boot: none.
for u in apt-daily apt-daily-upgrade; do
  mkdir -p "/etc/systemd/system/$u.service.d"
  cat >"/etc/systemd/system/$u.service.d/tvlink.conf" <<'EOF'
[Service]
ExecCondition=/bin/sh -c '! grep -q " / overlay " /proc/mounts'
EOF
done
# A hung kernel reboots the Pi (15 s is the most every Pi watchdog driver accepts). Applies from the next boot.
printf '[Manager]\nRuntimeWatchdogSec=15\nRebootWatchdogSec=10min\n' >/etc/systemd/system.conf.d/tvlink.conf
# Wi-Fi power save causes most Pi signage drop-outs: off, in raspi-config's own file.
printf '[connection]\nwifi.powersave = 2\n' >/etc/NetworkManager/conf.d/default-wifi-powersave-off.conf
# A keyboard plugged into the Pi can't open DevTools, browser pages or file dialogs, and pages can't download;
# remote debugging (CDP) is unaffected.
printf '{"URLBlocklist": ["devtools://*", "view-source:*", "chrome://*"], "AllowFileSelectionDialogs": false,
 "DownloadRestrictions": 3}\n' >/etc/chromium/policies/managed/tvlink.json

# No rainbow screen from the firmware.
grep -q '^disable_splash=1' "$BOOT/config.txt" || printf '\n[all]\ndisable_splash=1\n' >>"$BOOT/config.txt"
# cmdline.txt (HDMI mode, hotplug, EDID, a quiet boot) and config.txt (IR overlays) from the settings: tvlink boot.
TVLINK_CONF="$CONF" ./tvlink boot
# Captured EDIDs (tvlink edid capture) go into the initramfs too, for a display driver loaded from it.
mkdir -p /etc/initramfs-tools/hooks
cat >/etc/initramfs-tools/hooks/tvlink-edid <<'EOF'
#!/bin/sh
[ "$1" = prereqs ] && exit 0
. /usr/share/initramfs-tools/hook-functions
for f in /lib/firmware/edid/tvlink-*.bin; do [ -f "$f" ] && copy_file firmware "$f"; done
exit 0
EOF
chmod 755 /etc/initramfs-tools/hooks/tvlink-edid

# Raspberry Pi Connect (preinstalled on Lite) runs as the admin user's service: keep it up without a login.
[ -z "${SUDO_USER:-}" ] || loginctl enable-linger "$SUDO_USER"

systemctl daemon-reload
systemctl enable tvlink.service tvlink-power.service tvlink-net.service tvlink-reboot.timer tvlink-console.service \
  tvlink-content.service tvlink-lastgood.timer tvlink-hotspot.service
# An update takes effect now; a first install starts at the next boot, except the console, so it can be claimed now.
systemctl try-restart tvlink.service tvlink-power.service tvlink-net.service tvlink-tunnel.service \
  tvlink-content.service tvlink-hotspot.service
systemctl restart tvlink-console.service

echo "Installed tvlink $(./tvlink show | sed -n 's/^VERSION=//p'). First install: set BOARD_URL if needed, then reboot."
