#!/bin/bash
# tvlink's checks in the tests/vm.sh VM, as root: reinstall from this checkout, bring up the stand-ins (TV, Wi-Fi,
# board), then drive the real services. One line per check; exits 1 if any fail.
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 cpwillis (https://github.com/seslhq/tvlink)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fails=0
check() { # name command...
  local name=$1
  shift
  if "$@"; then echo "ok    $name"; else echo "FAIL  $name" && fails=$((fails + 1)); fi
}
within() { # seconds command...: retry until it passes
  local n=$1
  shift
  until "$@"; do ((n-- > 0)) || return 1; sleep 1; done
}
says() { grep -q "$1" <<<"$out"; }
quiet() { "$@" >/dev/null 2>&1; }
tv_is() { [ "$(tvlink status)" = "$1" ]; }
on_wifi() { nmcli -t -f DEVICE,STATE,CONNECTION device | grep -qx "wlan0:connected:$1"; }
logged() { journalctl -q -t tvlink --since "$since" | grep "$1" >/dev/null; } # kiosk lines come from its login session

echo "== Install and self-tests"
./install.sh >/var/log/tvlink-test-install.log 2>&1 || { tail -20 /var/log/tvlink-test-install.log; exit 1; }
check "tvlink-power test" quiet python3 tvlink-power test
check "tvlink-agent test" quiet python3 tvlink-agent test
check "tvlink-console test" quiet python3 tvlink-console test
for u in tvlink tvlink-power tvlink-net tvlink-console; do check "$u running" systemctl -q is-active "$u"; done

echo "== TV over HDMI-CEC"
# vivid's HDMI input is the TV and its HDMI output the Pi, cabled together; cec-follower answers as the TV. The TV
# side's node moves out of /dev/cec*, so tvlink only sees the Pi's.
if [ ! -e /dev/tvside ]; then
  modprobe vivid n_devs=1 node_types=0x101 num_inputs=1 input_types=3 num_outputs=1 output_types=1
  mv "$(cec-ctl -D vivid -a vivid-000-vid-cap0 -A)" /dev/tvside
fi
for d in /sys/class/video4linux/video*; do [ "$(cat "$d/name")" = vivid-000-vid-cap ] && cap=/dev/${d##*/}; done
v4l2-ctl -d "$cap" --set-ctrl=hdmi_000_0_is_connected_to=2
[ -e /run/tv-edid.hex ] || v4l2-ctl -d "$cap" --get-edid pad=0,file=/run/tv-edid.hex
tv() { # cec-follower options for the TV, or "unplugged" (nothing on the bus answers)
  pkill -x cec-follower && sleep 0.5
  cec-ctl -d /dev/tvside --clear >/dev/null
  [ "$1" = unplugged ] && return
  cec-ctl -d /dev/tvside --tv >/dev/null
  cec-follower -d /dev/tvside "$@" >>/run/tv.log 2>&1 &
  sleep 1
}
systemctl stop tvlink-power # it would wake the TV mid-check
tv --show-state
check "status: on" within 10 tv_is on
out=$(tvlink off); check "off: standby sent" says 'standby sent'
check "status: standby" within 15 tv_is standby
out=$(tvlink on); check "on: TV woken" says 'TV woken'
check "status: on again" within 15 tv_is on
tv unplugged
check "TV unplugged: status unknown" tv_is unknown
out=$(tvlink on); check "TV unplugged: on says no answer" says 'no answer'
out=$(tvlink off); check "TV unplugged: off says no answer" says 'no answer'
tv --show-state --standby
v4l2-ctl -d "$cap" --clear-edid pad=0 # a TV that drops hotplug in standby
out=$(tvlink on); check "hotplug low: on still wakes the TV" says 'TV woken'
v4l2-ctl -d "$cap" --set-edid pad=0,file=/run/tv-edid.hex
check "hotplug back: status on" within 15 tv_is on

echo "== Motion sensor (manual+motion, mock GPIO17)"
tvlink off >/dev/null
tvlink set POWER_MODE=manual+motion IDLE_MIN=1 >/dev/null
sleep 62
check "a quiet minute: TV left in standby" tv_is standby
echo 1 >/run/pir17
check "motion after the quiet minute wakes the TV" within 15 tv_is on
echo 0 >/run/pir17
tvlink set POWER_MODE=schedule IDLE_MIN=15 >/dev/null

echo "== Wi-Fi"
# Three hwsim radios: wlan0 is the Pi's; wlan1 and wlan2 move to their own namespace as the site's access points.
if ! ip netns list | grep -qw ap; then
  modprobe mac80211_hwsim radios=3
  ip netns add ap
  for i in 1 2; do iw phy "$(cat /sys/class/net/wlan$i/phy80211/name)" set netns name ap; done
  printf 'interface=wlan1\ndriver=nl80211\nssid=tvlink-open\nhw_mode=g\nchannel=1\n' >/run/ap1.conf
  printf 'interface=wlan2\ndriver=nl80211\nssid=tvlink-hidden\nhw_mode=g\nchannel=6\nignore_broadcast_ssid=1
wpa=2\nwpa_key_mgmt=WPA-PSK\nrsn_pairwise=CCMP\nwpa_passphrase=correct-horse-2\n' >/run/ap2.conf
  ip netns exec ap ip addr add 192.0.2.1/24 dev wlan1
  ip netns exec ap ip addr add 198.51.100.1/24 dev wlan2
  ip netns exec ap hostapd -B -P /run/ap1.pid /run/ap1.conf >/dev/null
  ip netns exec ap hostapd -B -P /run/ap2.pid /run/ap2.conf >/dev/null
  ip netns exec ap dnsmasq --conf-file=/dev/null --pid-file=/run/ap-dnsmasq.pid --bind-interfaces \
    --interface=wlan1 --interface=wlan2 --dhcp-range=192.0.2.50,192.0.2.99 --dhcp-range=198.51.100.50,198.51.100.99
fi
tvlink set WIFI_COUNTRY=AU WIFI1_SSID=tvlink-open WIFI1_PSK= WIFI2_SSID=tvlink-hidden WIFI2_PSK=correct-horse-2 \
  >/dev/null
check "joins WIFI1 (open)" within 60 on_wifi tvlink-wifi1
check "country AU" grep -q 'country AU' <(iw reg get)
uuid=$(nmcli -g connection.uuid connection show tvlink-wifi1)
systemctl restart tvlink-net
check "a rerun leaves the open network up" test "$(nmcli -g connection.uuid connection show tvlink-wifi1)" = "$uuid"
check "power save off" grep -q off <(iw dev wlan0 get power_save)
nic=$(ip -4 route show default | awk '$5 !~ /^wl/ {print $5; exit}')
ip route del default dev "$nic" # Ethernet out (not carrier off: the route stays)
check "Ethernet out: badge network is Wi-Fi" test "$(python3 -c 'import runpy, sys
print(runpy.run_path(sys.argv[1])["network"]())' tvlink-agent)" = Wi-Fi
networkctl reconfigure "$nic"
kill "$(cat /run/ap1.pid)"
check "WIFI1 gone: falls back to WIFI2 (hidden, WPA)" within 90 on_wifi tvlink-wifi2
ip netns exec ap hostapd -B -P /run/ap1.pid /run/ap1.conf >/dev/null
nmcli -w 60 connection up tvlink-wifi1 >/dev/null # back as it was, for a rerun

echo "== Kiosk"
mkdir -p /run/board
echo '<!doctype html><title>Board</title><body style="background:#123;color:#fff;font:80px sans-serif">BOARD' \
  >/run/board/index.html
systemctl -q is-active tvlink-test-board ||
  systemd-run -q --unit tvlink-test-board python3 -m http.server 8080 --bind 127.0.0.1 --directory /run/board
since=$(date '+%F %T')
tvlink set BOARD_URL=http://127.0.0.1:8080/ >/dev/null
check "splash hands over to the board" within 60 logged 'Splash: ready'
check "badge shows live" within 60 logged 'Badge: live'
out=$(tvlink screenshot); check "screenshot" says Saved
cage=$(pgrep -u kiosk -o -x cage)
check "kiosk runs with only the render group" grep -qE '^Groups:\s+[0-9]+ [0-9]+ ?$' "/proc/$cage/status"
check "kiosk can't power off the Pi (polkit)" quiet test "$(pkcheck --action-id org.freedesktop.login1.power-off \
  --process "$cage" >/dev/null 2>&1; echo $?)" != 0
check "kiosk can't plant a user unit in its home" quiet test "$(runuser -u kiosk -- \
  mkdir -p /home/kiosk/.config/systemd/user >/dev/null 2>&1; echo $?)" != 0
check "the session wrote nothing to the kiosk's home" test -z "$(ls -A /home/kiosk)"
check "/run/tvlink stays under 40 MB" test "$(du -sm /run/tvlink | cut -f1)" -lt 40

echo "== Unit console"
c=/run/tvlink-test-console
mkdir -p "$c" && rm -f "$c"/*
web() { # [curl options...] path: the HTTP code; body in $c/body, cookies in $c/jar
  curl -s -o "$c/body" -w '%{http_code}' -b "$c/jar" -c "$c/jar" "${@:1:$#-1}" "http://127.0.0.1${!#}"
}
csrf() { sed -n 's/.*name="csrf" value="\([^"]*\)".*/\1/p' "$c/body" | head -n 1; }
field() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$c/body" "$1"; }
splash_claim() { grep -q "\"claim\":\"$1\"" /run/tvlink/status.js; }
tvlink console reset >/dev/null # back to claim mode, as on a new unit
code=$(tvlink console claim | sed -n 's/.*Code: //p')
check "claim code from tvlink console claim" grep -qE '^[A-Z0-9]{3}-[A-Z0-9]{3}$' <<<"$code"
check "claim code on the splash" within 70 splash_claim "$code"
check "claim mode: pages lead to the claim page" test "$(web /settings)" = 303
web /claim >/dev/null
check "claim refuses a wrong code" test "$(web -d "csrf=$(csrf)" -d code=ZZZ-ZZ -d password=vm-test-password \
  -d repeat=vm-test-password /claim)" = 400
check "claiming sets a password" test "$(web -d "csrf=$(csrf)" -d "code=$code" -d password=vm-test-password \
  -d repeat=vm-test-password /claim)" = 303
check "password stored as a PBKDF2 hash" grep -q '^pbkdf2_sha256[$]600000[$]' /var/lib/tvlink-console/password
check "claimed: no claim code to print" quiet test "$(tvlink console claim >/dev/null 2>&1; echo $?)" = 1
rm -f "$c/jar"
web /login >/dev/null
check "login refuses a wrong password" test "$(web -d "csrf=$(csrf)" -d password=wrong-password /login)" = 401
check "login works" test "$(web -d "csrf=$(csrf)" -d password=vm-test-password /login)" = 303
check "logged in: Status page" test "$(web /)" = 200
t=$(csrf)
check "a form without its CSRF token is refused" test "$(web -d action=identify /actions)" = 403
check "API with a session but no CSRF header is refused" test "$(web -d '{"action":"identify"}' /api/action)" = 403
check "API with neither session nor token is refused" \
  test "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/api/status)" = 401
check "the console user can't run other commands as root" \
  quiet test "$(runuser -u tvlink-console -- sudo -n /usr/local/bin/tvlink show >/dev/null 2>&1; echo $?)" != 0
web -H "X-CSRF-Token: $t" -X DELETE /api/tokens/vm-test >/dev/null # left by an earlier run
web -H "X-CSRF-Token: $t" -d '{"name": "vm-test"}' /api/tokens >/dev/null
token=$(field token)
bearer() { curl -s -o "$c/body" -w '%{http_code}' -H "Authorization: Bearer $token" "$@"; }
check "API token stored hashed only" quiet test -n "$token" -a \
  "$(grep -c "$token" /var/lib/tvlink-console/tokens.json)" = 0
since=$(date '+%F %T')
check "API token: reload" test "$(bearer -d '{"action": "reload"}' http://127.0.0.1/api/action)" = 200
check "... the page reloads" within 10 logged 'Request: reload'
check "API token: last screenshot" test "$(bearer http://127.0.0.1/api/screenshot)" = 200
check "API token revoked" test "$(web -H "X-CSRF-Token: $t" -X DELETE /api/tokens/vm-test)" = 200
check "... and refused after" test "$(bearer http://127.0.0.1/api/status)" = 401
since=$(date '+%F %T')
check "API sets OVERLAY_CORNER" test "$(web -H "X-CSRF-Token: $t" -d '{"OVERLAY_CORNER": "top-left"}' \
  /api/settings)" = 200
check "... tvlink reads it" grep -qx OVERLAY_CORNER=top-left <(tvlink show)
web /api/settings >/dev/null
check "... the API reads it back" grep -qx top-left <(python3 -c 'import json, sys
print(next(k["value"] for k in json.load(open(sys.argv[1]))["keys"] if k["key"] == "OVERLAY_CORNER"))' "$c/body")
check "... and sudo did not log the command" quiet test "$(journalctl -q --since "$since" | grep -c OVERLAY_CORNER)" = 0
check "API refuses a bad value, naming the key" test "$(web -H "X-CSRF-Token: $t" -d '{"OVERLAY_CORNER": "middle"}' \
  /api/settings)/$(field key)" = 400/OVERLAY_CORNER
check "claimed: the code is gone from the splash" within 60 splash_claim ''
tvlink set OVERLAY_CORNER=bottom-right >/dev/null

echo "== $fails failed"
[ "$fails" = 0 ]
