#!/bin/bash
# One-time setup in the tests/vm.sh VM, as root: what Pi OS Lite has and Debian's image lacks, the stand-ins' tools,
# then the real install.sh.
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 cpwillis (https://github.com/seslhq/tvlink)
set -euo pipefail
cd "$(dirname "$0")/.."
export DEBIAN_FRONTEND=noninteractive

# Raspberry Pi repo, as on Pi OS: its cage, Chromium and gpiozero builds, and python3-lgpio, which Debian lacks. The key
# comes from Pi OS's keyring package: the site's raspberrypi.gpg.key has a SHA1 binding Debian 13 rejects.
key=/usr/share/keyrings/raspberrypi-archive-keyring.pgp
if [ ! -e "$key" ]; then
  tmp=$(mktemp -d)
  pool=https://archive.raspberrypi.com/debian/pool/main/r/raspberrypi-archive-keyring
  curl -fsSL -o "$tmp/keyring.deb" "$pool/raspberrypi-archive-keyring_2025.1+rpt1_all.deb"
  dpkg-deb -x "$tmp/keyring.deb" "$tmp"
  install -m 644 "$tmp$key" "$key"
fi
printf 'Types: deb\nURIs: http://archive.raspberrypi.com/debian/\nSuites: trixie\nComponents: main\nSigned-By: %s\n' \
  "$key" >/etc/apt/sources.list.d/raspi.sources
apt-mark hold cloud-init # the Pi build would redo its first boot at every Lima start
apt-get update
# Pi OS Lite has NetworkManager and zram swap. hostapd and dnsmasq run the test Wi-Fi networks.
apt-get install -y dosfstools network-manager iw wireless-regdb hostapd dnsmasq-base systemd-zram-generator
printf '[zram0]\nzram-size = min(ram, 2048)\n' >/etc/systemd/zram-generator.conf

# The Pi's boot partition is FAT32: a loop image, so tvlink set and install.sh write to FAT as on the Pi.
if ! grep -q ' /boot/firmware ' /etc/fstab; then
  truncate -s 512M /var/lib/bootfs.img
  mkfs.vfat -F 32 -s 1 -n bootfs /var/lib/bootfs.img
  mkdir -p /boot/firmware
  echo '/var/lib/bootfs.img /boot/firmware vfat loop,defaults 0 0' >>/etc/fstab
  systemctl daemon-reload
  mount /boot/firmware
  echo 'console=serial0,115200 console=tty1 root=/dev/vda1 rootfstype=ext4 fsck.repair=yes rootwait' \
    >/boot/firmware/cmdline.txt
  touch /boot/firmware/config.txt
fi

# The VM's GPU has no 3D: wlroots draws in software (the Pi uses its GPU).
mkdir -p /etc/systemd/system/tvlink.service.d /etc/systemd/system/tvlink-power.service.d
printf '[Service]\nEnvironment=WLR_RENDERER=pixman\n' >/etc/systemd/system/tvlink.service.d/vm.conf
# Motion sensor: the real tvlink-power on gpiozero's mock pins; echo 1 (or 0) >/run/pir17 drives GPIO17.
cat >/usr/local/sbin/tvlink-power-mock <<'EOF'
#!/usr/bin/python3
import os, runpy, threading
from gpiozero import Device
from gpiozero.pins.mock import MockFactory

Device.pin_factory = MockFactory()
if not os.path.exists("/run/pir17"):
    os.mkfifo("/run/pir17")


def pump():
    while True:
        with open("/run/pir17") as f:
            for line in f:
                pin = Device.pin_factory.pin(17)
                pin.drive_high() if line.strip() == "1" else pin.drive_low()


threading.Thread(target=pump, daemon=True).start()
runpy.run_path("/usr/local/bin/tvlink-power", run_name="__main__")
EOF
chmod 755 /usr/local/sbin/tvlink-power-mock
printf '[Service]\nExecStart=\nExecStart=/usr/local/sbin/tvlink-power-mock\n' \
  >/etc/systemd/system/tvlink-power.service.d/vm.conf

./install.sh
