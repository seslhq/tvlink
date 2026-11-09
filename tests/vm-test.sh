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
no() { ! "$@"; }
quiet() { "$@" >/dev/null 2>&1; }
tv_is() { [ "$(tvlink status)" = "$1" ]; }
on_wifi() { nmcli -t -f DEVICE,STATE,CONNECTION device | grep -qx "wlan0:connected:$1"; }
logged() { journalctl -q -t tvlink --since "$since" | grep "$1" >/dev/null; } # kiosk lines come from its login session
power_said() { journalctl -q -u tvlink-power --since "$since" | grep -q "$1"; }
hm() { date -d "$1" +%H:%M; } # eg hm '+1 hour'

echo "== Install and self-tests"
command rm -f /etc/systemd/system/tvlink.service.d/test-uptime.conf # left by an earlier run
./install.sh >/var/log/tvlink-test-install.log 2>&1 || { tail -20 /var/log/tvlink-test-install.log; exit 1; }
check "tvlink-power test" quiet python3 tvlink-power test
check "tvlink-agent test" quiet python3 tvlink-agent test
check "tvlink-console test" quiet python3 tvlink-console test
check "tvlink-content test" quiet python3 tvlink-content test
# Settings the checks change, as an earlier run that stopped midway may have left them
modprobe -r g_mass_storage 2>/dev/null
tvlink set POWER_METHOD=cec POWER_MODE=schedule IR_CODES=learned HDMI_FORCE_HOTPLUG=0 SOURCE=auto USB_CONTENT=0 \
  CONTENT_URL= LAST_GOOD=0 BROWSER_RESTART= BOARD_URL= >/dev/null
for u in tvlink tvlink-power tvlink-net tvlink-console; do
  check "$u running" within 10 systemctl -q is-active "$u"
done

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

echo "== Overrides (schedule, CEC)"
# A status query while tvlink-power sends can make the send fail (both use the adapter): let it act first
acted() { sleep 5; }
tvlink override clear >/dev/null # left by an earlier run
acted
tvlink set TV_ON="$(hm '+1 hour')" TV_OFF="$(hm '-1 hour')" >/dev/null # off-hours now
acted
check "off-hours: standby" within 20 tv_is standby
out=$(tvlink override on 1m); check "override on for 1 min: says until when" says '^Override: TV on until '
acted
check "... wakes the TV in off-hours" within 15 tv_is on
check "... tvlink override shows it" grep -q '^on until ' <(tvlink override)
check "... stored root only" test "$(stat -c '%U %a' /var/lib/tvlink/override)" = "root 600"
since=$(date '+%F %T')
systemctl restart tvlink-power
check "... survives a tvlink-power restart" within 10 power_said 'Override: TV on until'
acted
check "... the TV still on" tv_is on
check "... expires back to standby" within 90 power_said 'Override over: back to POWER_MODE=schedule'
acted
check "... standby" within 15 tv_is standby
check "... and tvlink override says none" test "$(tvlink override)" = none
tvlink override on 30m >/dev/null
acted
check "override on again" within 15 tv_is on
out=$(tvlink override clear); check "clear" says 'Override cleared'
acted
check "... back to standby" within 15 tv_is standby
tvlink set TV_ON="$(hm '-1 hour')" TV_OFF="$(hm '+1 hour')" >/dev/null # on-hours now
acted
check "on-hours: on" within 20 tv_is on
tvlink override off until "$(hm '+30 min')" >/dev/null
acted
check "override off until a time in on-hours: standby" within 15 tv_is standby
out=$(tvlink override on 4x 2>&1); check "a bad length refused" says 'Give how long'
tvlink override clear >/dev/null
acted
check "... cleared: on again" within 15 tv_is on
tvlink set POWER_MODE=always >/dev/null
out=$(tvlink override off 2>&1); check "always: no default end, a length needed" says 'has no on-hours'
tvlink set POWER_MODE=schedule TV_ON=06:00 TV_OFF=22:00 >/dev/null

echo "== TV power by infrared (rc-loopback for the IR LED, the receiver and the TV)"
# What is sent on rc-loopback's /dev/lirc0 comes back on it, and the kernel decodes it to scancodes on its input
# device: heard lists those, so a check sees what reached the TV, as a TV would decode it.
modprobe rc-loopback
for r in /sys/class/rc/rc*; do grep -qx DRV_NAME=rc-loopback "$r/uevent" && lirc=$r; done
echo "+nec +sony" >"$lirc/protocols"
scan='import glob, os, select, struct, sys, time
fd = os.open("/dev/input/" + glob.glob(sys.argv[1] + "/input*/event*")[0].rsplit("/")[-1], os.O_RDONLY | os.O_NONBLOCK)
end, seen = time.time() + 6, []
while time.time() < end:
    if select.select([fd], [], [], 0.2)[0]:
        data = os.read(fd, 24 * 64)
        for i in range(0, len(data), 24):
            kind, code, value = struct.unpack("llHHi", data[i:i + 24])[2:]
            if (kind, code) == (4, 4) and hex(value & 0xffffffff) not in seen:  # EV_MSC, MSC_SCAN
                seen.append(hex(value & 0xffffffff))
print(" ".join(seen))'
heard() { # command...: the scancodes decoded while it runs, and up to 6 s from its start
  python3 -c "$scan" "$lirc" >/run/ir-heard &
  sleep 0.5
  "$@" >/dev/null 2>&1
  wait $!
  cat /run/ir-heard
}
# manual: a restart that is not after a power cut sends nothing, so only the checks send
tvlink set POWER_MODE=manual POWER_METHOD=ir IR_CODES=samsung >/dev/null
check "IR transmitter overlay in config.txt" grep -qx 'dtoverlay=gpio-ir-tx,gpio_pin=18' /boot/firmware/config.txt
check "... and the receiver's, mapping no keys" \
  grep -qx 'dtoverlay=gpio-ir,gpio_pin=23,rc-map-name=rc-empty' /boot/firmware/config.txt
check "IR: status unknown" tv_is unknown
for b in "samsung 0x70799 0x70798" "lg 0x4c4 0x4c5" "sony 0x1002e 0x1002f" "toshiba 0x407e 0x407f"; do
  read -r brand on off <<<"$b"
  tvlink set IR_CODES="$brand" >/dev/null
  check "IR $brand: on" test "$(heard tvlink on)" = "$on"
  check "IR $brand: off" test "$(heard tvlink off)" = "$off"
done
out=$(tvlink set IR_CODES=panasonic 2>&1); check "IR: a brand without built-in codes refused" says 'IR_CODES is'
rm -rf /var/lib/tvlink/ir
learn() { # on|off scancode: learn from a stand-in remote sending the scancode
  tvlink ir learn "$1" >/run/ir-learn 2>&1 &
  sleep 1.5
  ir-ctl -d /dev/lirc0 -S "nec:$2"
  wait $!
}
learn on 0x1234; check "IR learn on" grep -q '^Learned power on' /run/ir-learn
learn off 0x1235; check "IR learn off" grep -q '^Learned power off' /run/ir-learn
check "... kept root only" test "$(stat -c '%U %a' /var/lib/tvlink/ir)" = "root 700"
tvlink set IR_CODES=learned >/dev/null
check "IR learned: on" test "$(heard tvlink ir test on)" = 0x1234
check "IR learned: off" test "$(heard tvlink ir test off)" = 0x1235
check "tvlink-power with IR: always sends on at start" test "$(heard tvlink set POWER_MODE=always)" = 0x1234
tvlink set POWER_METHOD=cec POWER_MODE=schedule >/dev/null
check "back to CEC: the IR overlays go" quiet test "$(grep -c gpio-ir /boot/firmware/config.txt)" = 0

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
check "... shows the power method" grep -q '<dd>[A-Za-z]* (HDMI-CEC)</dd>' "$c/body"
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
check "API override on for 30 min" test "$(web -H "X-CSRF-Token: $t" -d '{"override": "on", "for": "30m"}' \
  /api/override)" = 200
web /api/status >/dev/null
check "... the console's Status says until when" grep -q '^on until ' <(field override)
web /actions >/dev/null
check "... the Actions page offers Clear Override" grep -q 'value="clear">Clear Override<' "$c/body"
check "API override: a bad length refused" test "$(web -H "X-CSRF-Token: $t" -d '{"override": "on", "for": "4x"}' \
  /api/override)" = 400
check "API override clear" test "$(web -H "X-CSRF-Token: $t" -d '{"override": "clear"}' /api/override)" = 200
check "... cleared" test "$(tvlink override)" = none
tvlink set OVERLAY_CORNER=bottom-right >/dev/null
hdr=(-H 'Cf-Access-Authenticated-User-Email: someone@example.com' -H 'Cf-Access-Jwt-Assertion: x.y.z'
  -H 'X-Forwarded-For: 192.0.2.9' -H 'X-Forwarded-User: admin')
check "Access and proxy headers alone don't authenticate (API)" \
  test "$(curl -s -o /dev/null -w '%{http_code}' "${hdr[@]}" http://127.0.0.1/api/status)" = 401
check "... nor pages" test "$(curl -s -o /dev/null -w '%{http_code}' "${hdr[@]}" http://127.0.0.1/settings)" = 303
cookie() { curl -s -D - -o /dev/null "$@" http://127.0.0.1/login | grep -i '^set-cookie:'; }
check "cookie Secure behind a tunnel (Cf-Visitor)" grep -q '; Secure' <(cookie -H 'Cf-Visitor: {"scheme":"https"}')
check "cookie Secure behind a proxy (X-Forwarded-Proto)" grep -q '; Secure' <(cookie -H 'X-Forwarded-Proto: https')
check "cookie not Secure on plain HTTP" quiet test -z "$(cookie | grep '; Secure')"

echo "== Tunnel (cloudflared with a made-up token)"
tvlink set TUNNEL_TOKEN= >/dev/null # left by an earlier run; and cloudflared goes, so the install is checked each run
apt-get purge -y -q cloudflared >/dev/null 2>&1
rm -f /etc/apt/sources.list.d/cloudflared.list
# Well formed (account, tunnel and secret), but no such tunnel: cloudflared reaches Cloudflare and is refused.
fake=$(printf '{"a":"%032d","t":"00000000-0000-4000-8000-000000000000","s":"%s"}' 0 "$(head -c 32 /dev/zero |
  base64)" | base64 -w0)
since=$(date '+%F %T')
check "a malformed token is refused" test "$(web -H "X-CSRF-Token: $t" -d '{"TUNNEL_TOKEN": "not-a-token"}' \
  /api/settings)/$(field key)" = 400/TUNNEL_TOKEN
check "set through the console API (as Settings does)" test "$(web -H "X-CSRF-Token: $t" \
  -d "{\"TUNNEL_TOKEN\": \"$fake\"}" --max-time 300 /api/settings)" = 200
check "... cloudflared installed from Cloudflare's repo" grep -q pkg.cloudflare.com <(apt-cache policy cloudflared)
check "... token file root only" test "$(stat -c '%U %a' /etc/tvlink/tunnel-token)" = "root 600"
check "... not in tvlink.conf" quiet test "$(grep -c TUNNEL /boot/firmware/tvlink.conf)" = 0
check "... tvlink show says (set)" grep -qx 'TUNNEL_TOKEN=(set)' <(tvlink show)
web /api/settings >/dev/null
check "... the API says set, never the token" grep -qx 'True ' <(python3 -c 'import json, sys
k = next(k for k in json.load(open(sys.argv[1]))["keys"] if k["key"] == "TUNNEL_TOKEN"); print(k["set"], k["value"])' \
  "$c/body")
check "tvlink-tunnel running" within 30 systemctl -q is-active tvlink-tunnel
check "... the token is not on its command line" quiet test "$(pgrep -a cloudflared | grep -c -e "${fake:0:40}" \
  -e '--token ')/$(pgrep -a cloudflared | grep -c -- '--token-file')" = 0/1
check "... as its own unprivileged user" test -z "$(pgrep -u root -x cloudflared)"
refused() { journalctl -q -u tvlink-tunnel --since "$since" | grep -q 'Register tunnel error'; }
check "... cloudflared reaches Cloudflare and is refused" within 60 refused
check "... state: not connected" test "$(tvlink tunnel)" = "not connected"
check "... in tvlink doctor" grep -qx 'Tunnel: not connected' <(tvlink doctor)
web /api/status >/dev/null
check "... on the console's Status" test "$(field tunnel)" = "not connected"
check "... the token is in no log" quiet test "$(journalctl -q --since "$since" | grep -c -F "${fake:0:40}")" = 0
out=$(tvlink set TUNNEL_TOKEN=); check "clearing it says so" says '^TUNNEL_TOKEN=$'
check "... stops the tunnel" quiet test "$(systemctl is-active tvlink-tunnel)/$(systemctl is-enabled tvlink-tunnel \
  2>/dev/null)" = inactive/disabled
check "... removes the token file" test ! -e /etc/tvlink/tunnel-token
check "... state: off" test "$(tvlink tunnel)" = off

echo "== Fleet console (port 8081, pointed at this unit's console)"
install -m 644 tvlink-fleet.service /etc/systemd/system/
mkdir -p /etc/systemd/system/tvlink-fleet.service.d
printf '[Service]\nEnvironment=TVLINK_CONSOLE_PORT=8081\n' >/etc/systemd/system/tvlink-fleet.service.d/vm.conf
systemctl daemon-reload
systemctl stop tvlink-fleet
rm -rf /var/lib/private/tvlink-fleet # a new fleet console each run
systemctl start tvlink-fleet
fweb() { curl -s -o "$c/body" -w '%{http_code}' -b "$c/fjar" -c "$c/fjar" "${@:1:$#-1}" "http://127.0.0.1:8081${!#}"; }
check "fleet: running" within 10 quiet fweb /login
check "fleet: on loopback only" quiet test "$(ss -Htln 'sport = :8081' | awk '{print $4}')" = 127.0.0.1:8081
check "fleet: claim code readable by root only" test "$(stat -c %a /run/tvlink-fleet/claim)" = 600
fweb /claim >/dev/null
check "fleet: claimed with its code" test "$(fweb -d "csrf=$(csrf)" -d "code=$(cat /run/tvlink-fleet/claim)" \
  -d password=vm-fleet-password -d repeat=vm-fleet-password /claim)" = 303
web -H "X-CSRF-Token: $t" -X DELETE /api/tokens/vm-fleet >/dev/null
web -H "X-CSRF-Token: $t" -d '{"name": "vm-fleet"}' /api/tokens >/dev/null
token=$(field token)
fweb /units/new >/dev/null
f=$(csrf)
check "fleet: adds the unit" test "$(fweb -d "csrf=$f" -d name=vm-unit -d url=http://127.0.0.1 -d "token=$token" \
  /units/new)" = 303
check "... stored for the fleet user only" test "$(stat -c %a /var/lib/private/tvlink-fleet/units.json)" = 600
fweb -d "csrf=$f" -d name=vm-down -d url=http://192.0.2.1 -d "token=tvl_$(printf %032d 0)" /units/new >/dev/null
start=$(date +%s)
check "fleet: overview" test "$(fweb /)" = 200
check "... the unit is live" grep -q 'class="pill live">Live<' "$c/body"
check "... a unit that is down shows as unreachable" grep -q '>Unreachable<' "$c/body"
check "... and doesn't hold up the page" test $(($(date +%s) - start)) -le 6
check "fleet: Take Screenshot through it" test "$(fweb -d "csrf=$f" -d action=screenshot -d back=/u/vm-unit/ \
  /u/vm-unit/actions)" = 303
check "fleet: the unit's Status page" test "$(fweb /u/vm-unit/)" = 200
check "... with its health" grep -q 'Tunnel: off' "$c/body"
check "... and its screenshot" test "$(fweb /u/vm-unit/screenshot.jpg)" = 200
since=$(date '+%F %T')
check "fleet: an action through it" test "$(fweb -d "csrf=$f" -d action=reload /u/vm-unit/actions)" = 303
check "... the page reloads" within 10 logged 'Request: reload'
check "fleet: the unit's Settings page" test "$(fweb /u/vm-unit/settings)" = 200
check "... a bad value comes back with its error" test "$(fweb -d "csrf=$f" -d OVERLAY_CORNER=middle \
  /u/vm-unit/settings)" = 400
check "fleet: the unit's Logs page" test "$(fweb /u/vm-unit/logs)" = 200
check "fleet: an override through it" test "$(fweb -d "csrf=$f" -d override=off -d for=30m /u/vm-unit/actions)" = 303
check "... set on the unit" grep -q '^off until ' <(tvlink override)
fweb -d "csrf=$f" -d override=clear /u/vm-unit/actions >/dev/null
check "... and cleared" test "$(tvlink override)" = none
rm -f "$c/fjar"
check "fleet: refused without a login" test "$(fweb /u/vm-unit/)" = 303
web -H "X-CSRF-Token: $t" -X DELETE /api/tokens/vm-fleet >/dev/null
systemctl stop tvlink-fleet

echo "== TV power by HDMI signal (cage's output off and on)"
enabled() { # outputs cage has on
  runuser -u kiosk -- env XDG_RUNTIME_DIR="/run/user/$(id -u kiosk)" WAYLAND_DISPLAY=wayland-0 wlr-randr |
    grep -c 'Enabled: yes'
}
signal_is() { [ "$(enabled)" = "$1" ]; }
since=$(date '+%F %T')
tvlink set POWER_METHOD=signal POWER_MODE=always >/dev/null
check "signal: tvlink-power turns it on at start (always)" within 20 power_said 'HDMI signal on'
systemctl stop tvlink-power # its 5-minute check would turn it back on mid-check
check "signal: status on" tv_is on
cage=$(pgrep -u kiosk -o -x cage)
since=$(date '+%F %T')
out=$(tvlink off); check "signal off" says 'HDMI signal off'
check "... the output is off" within 10 signal_is 0
check "... status off" tv_is off
web /api/status >/dev/null
check "... the console says Off (HDMI Signal)" test "$(field tv)/$(field method)" = off/signal
web /actions >/dev/null
check "... and what TV On does with it" grep -q 'Turns the HDMI signal on' "$c/body"
sleep 65 # two health checks and two mode passes
check "... still off after a minute" signal_is 0
check "... the kiosk kept running" test "$(pgrep -u kiosk -o -x cage)" = "$cage"
check "... a dark screen is no fault" quiet test "$(journalctl -q -t tvlink --since "$since" | grep -c Recover)" = 0
since=$(date '+%F %T')
systemctl restart tvlink
check "a kiosk restart keeps it off" within 60 logged 'HDMI signal off'
check "... the page loads first" logged 'Badge: live'
check "... output off" within 5 signal_is 0
since=$(date '+%F %T')
out=$(tvlink on); check "signal on" says 'HDMI signal on'
check "... the output is on" within 10 signal_is 1
check "... status on" tv_is on
out=$(tvlink screenshot); check "... and the page shows" says Saved
tvlink set POWER_METHOD=cec POWER_MODE=schedule >/dev/null

echo "== HDMI: forced hotplug and a captured EDID"
arg() { tr ' ' '\n' </boot/firmware/cmdline.txt | grep -cx "$1"; } # times a kernel argument is there
out=$(tvlink set HDMI_FORCE_HOTPLUG=1); check "force hotplug: reboot to apply" says 'Reboot to apply: cmdline.txt'
check "... vc4.force_hotplug=1, once" test "$(arg vc4.force_hotplug=1)" = 1
check "... the rest of cmdline.txt kept" test "$(arg root=/dev/vda1)$(arg quiet)" = 11
sum=$(md5sum </boot/firmware/cmdline.txt)
out=$(tvlink set HDMI_FORCE_HOTPLUG=1); check "... set again: no change" no says Reboot
check "... cmdline.txt the same" test "$(md5sum </boot/firmware/cmdline.txt)" = "$sum"
check "... in tvlink doctor" grep -q '^HDMI at boot: force hotplug on, EDID from the TV' <(tvlink doctor)
tvlink set HDMI_FORCE_HOTPLUG=0 >/dev/null
check "... off: gone" test "$(arg vc4.force_hotplug=1)" = 0
out=$(tvlink edid capture 2>&1); check "EDID: no HDMI connector in the VM, nothing saved" says 'No EDID captured'
out=$(TVLINK_DRM='/sys/class/drm/card*-*' tvlink edid capture 2>&1)
check "... Virtual-1 has none (vz gives no EDID)" says 'Virtual-1: no valid EDID'
# A connector with vivid's TV EDID stands in for a Pi's HDMI-A-1
drm=/run/tvlink-test-drm/card1-HDMI-A-1
mkdir -p "$drm" && echo connected >"$drm/status"
python3 -c 'import sys; open(sys.argv[2], "wb").write(bytes.fromhex(open(sys.argv[1]).read()))' /run/tv-edid.hex \
  "$drm/edid"
cap() { TVLINK_DRM='/run/tvlink-test-drm/card*-HDMI-A-*' tvlink edid capture 2>&1; }
out=$(cap); check "EDID captured" says 'HDMI-A-1: EDID saved'
check "... byte for byte" cmp -s "$drm/edid" /lib/firmware/edid/tvlink-HDMI-A-1.bin
check "... cmdline.txt loads it, once" test "$(arg drm.edid_firmware=HDMI-A-1:edid/tvlink-HDMI-A-1.bin)" = 1
initrd() { lsinitramfs "/boot/initrd.img-$(uname -r)" 2>/dev/null; }
check "... in the initramfs" grep -q 'edid/tvlink-HDMI-A-1.bin$' <(initrd)
out=$(cap); check "... captured again: cmdline.txt unchanged" no says 'Reboot to apply'
check "... in tvlink doctor" grep -q '^HDMI at boot: force hotplug off, EDID tvlink-HDMI-A-1.bin' <(tvlink doctor)
printf '\x01' | dd of="$drm/edid" bs=1 seek=20 conv=notrunc 2>/dev/null # a bad checksum
out=$(cap); check "... a corrupt EDID refused" says 'no valid EDID'
check "... the saved one kept" test -s /lib/firmware/edid/tvlink-HDMI-A-1.bin
out=$(tvlink edid clear); check "EDID clear" says 'EDID cleared'
check "... file gone" test ! -e /lib/firmware/edid/tvlink-HDMI-A-1.bin
check "... cmdline.txt without it" quiet test "$(grep -c edid_firmware /boot/firmware/cmdline.txt)" = 0
check "... initramfs without it" quiet test "$(initrd | grep -c tvlink-HDMI)" = 0

echo "== Content and screen"
python3 -c 'import PIL' 2>/dev/null || # reads the screenshots
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q python3-pil >/dev/null 2>&1
png() { # RRGGBB: a small PNG of that colour, on stdout
  python3 -c 'import struct, sys, zlib
w, h, rgb = 64, 36, bytes.fromhex(sys.argv[1])
chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
raw = b"".join(b"\0" + rgb * w for _ in range(h))
sys.stdout.buffer.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                       + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))' "$1"
}
# A JPEG's colour at x y (negative: from the right or bottom), as RRGGBB; with a colour, whether the box from there to
# the corner is all near it. near: two colours within JPEG's error. shows: a new screenshot has the colour mid-screen.
img() {
  python3 -c 'import sys
from PIL import Image
im, x, y = Image.open(sys.argv[1]).convert("RGB"), int(sys.argv[2]), int(sys.argv[3])
box = im.crop((x % im.width, y % im.height, im.width, im.height)).getdata()
if len(sys.argv) == 4:
    print("%02x%02x%02x" % box[0])
else:
    sys.exit(max(abs(a - b) for p in box for a, b in zip(p, bytes.fromhex(sys.argv[4]))) > 24)' "$@"
}
near() { python3 -c 'import sys; a, b = (bytes.fromhex(x) for x in sys.argv[1:]); sys.exit(max(abs(i - j) for i, j in
  zip(a, b)) > 24)' "$1" "$2"; }
shows() { tvlink screenshot >/dev/null 2>&1 && near "$(img /run/tvlink/screen.jpg 960 540)" "$1"; }
from() { grep -q "\"source\":\"$1\"" /run/tvlink/status.js; }
pids() { echo "$(pgrep -u kiosk -o -x cage) $(pgrep -u kiosk -o -x chromium)"; }
board=112233 # the test board's background

echo "-- Link switch without a restart"
echo '<!doctype html><title>B</title><body style="background:#a13;color:#fff;font:80px sans-serif">B' \
  >/run/board/b.html
check "the board is up" within 60 shows "$board"
was=$(pids)
out=$(tvlink set BOARD_URL=http://127.0.0.1:8080/b.html); check "a new BOARD_URL loads in the background" \
  says 'Page switch: the new page is showing'
check "... the kiosk and Chromium kept running" test "$(pids)" = "$was"
check "... the new page on screen" within 10 shows aa1133
out=$(tvlink set BOARD_URL=http://127.0.0.1:8080/missing.html)
check "a page that fails to load (404) is refused" says 'Page switch failed (HTTP 404): keeping the old page'
check "... the old page stays" shows aa1133
out=$(tvlink set BOARD_URL=http://127.0.0.1:8080/); check "back to the first" says 'Page switch: the new page'
check "... without a restart" test "$(pids)" = "$was"
check "... on screen" within 10 shows "$board"

echo "-- Synced content (an https server with its own CA)"
d=/run/tvlink-test-content
mkdir -p "$d/src" && command rm -f "$d"/src/*
[ -e "$d/ca.pem" ] || openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 \
  -subj /CN=127.0.0.1 -addext subjectAltName=IP:127.0.0.1 -keyout "$d/key.pem" -out "$d/ca.pem" 2>/dev/null
systemctl -q is-active tvlink-test-content-server || systemd-run -q --unit tvlink-test-content-server python3 -c '
import http.server, ssl, sys
s = http.server.ThreadingHTTPServer(("127.0.0.1", 8443),
    lambda *a: http.server.SimpleHTTPRequestHandler(*a, directory=sys.argv[1] + "/src"))
c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
c.load_cert_chain(sys.argv[1] + "/ca.pem", sys.argv[1] + "/key.pem")
s.socket = c.wrap_socket(s.socket, server_side=True)
s.serve_forever()' "$d"
# Python checks certificates against SSL_CERT_FILE when it is set: the test's CA, for this service only
mkdir -p /etc/systemd/system/tvlink-content.service.d
printf '[Service]\nEnvironment=SSL_CERT_FILE=%s/ca.pem\n' "$d" >/etc/systemd/system/tvlink-content.service.d/vm.conf
systemctl daemon-reload
png 3311aa >"$d/src/01-synced.png"
tvlink content manifest "$d/src" >"$d/manifest.json" && mv "$d/manifest.json" "$d/src/"
check "tvlink content manifest lists the folder" grep -q '"name": "01-synced.png"' "$d/src/manifest.json"
out=$(tvlink set CONTENT_URL=http://127.0.0.1:8443/manifest.json 2>&1); check "CONTENT_URL: http refused" says https
tvlink set CONTENT_URL=https://127.0.0.1:8443/manifest.json SOURCE=folder >/dev/null
out=$(tvlink content sync); check "content sync" says '^OK .*: 1 file, under 1 MB'
check "... root's files, readable by all" test "$(stat -c '%U %a' /var/lib/tvlink/content/current/01-synced.png)" = \
  "root 644"
check "... played as local content" within 10 from synced
check "... on screen" within 30 shows 3311aa
set=$(readlink /var/lib/tvlink/content/current)
png 3311aa >"$d/src/02-bad.png"
tvlink content manifest "$d/src" >"$d/manifest.json" && mv "$d/manifest.json" "$d/src/"
printf x | dd of="$d/src/02-bad.png" bs=1 seek=60 conv=notrunc 2>/dev/null # changed, same size: checksum wrong
out=$(tvlink content sync); check "a bad checksum is refused" says '^Failed .*02-bad.png: checksum does not match'
check "... the set before kept" test "$(readlink /var/lib/tvlink/content/current)" = "$set"
check "... and still on screen" shows 3311aa
web /api/status >/dev/null
check "console Status: content and sync" test "$(field content)/$(field sync)" = "Synced, 1 file/$out"

echo "-- USB stick (dummy_hcd and g_mass_storage: a real USB mass storage device)"
stick=/run/tvlink-test-stick.img
if [ ! -e "$stick" ]; then
  truncate -s 64M "$stick"
  echo 'start=2048, type=c' | sfdisk -q "$stick"
  loop=$(losetup -fP --show "$stick")
  mkfs.vfat -n STICK "${loop}p1" >/dev/null
  mkdir -p /run/tvlink-test-mnt && mount "${loop}p1" /run/tvlink-test-mnt
  mkdir /run/tvlink-test-mnt/tvlink && png 33aa11 >/run/tvlink-test-mnt/tvlink/stick.png
  umount /run/tvlink-test-mnt && losetup -d "$loop"
fi
usb_part() { lsblk -nro NAME,TRAN | awk '$2 == "usb" {print $1 "1"}' | grep -q .; }
tvlink set USB_CONTENT=0 >/dev/null
modprobe dummy_hcd && modprobe g_mass_storage file="$stick" removable=1 ro=1
check "a stick plugged in" within 15 usb_part
sleep 2
check "USB_CONTENT=0: not mounted" no mountpoint -q /run/tvlink-usb
tvlink set USB_CONTENT=1 >/dev/null
check "USB_CONTENT=1: mounted" within 10 mountpoint -q /run/tvlink-usb
check "... read-only, no devices, setuid or programs" grep -q '^ro,nosuid,nodev,noexec' <(findmnt -no OPTIONS \
  /run/tvlink-usb)
check "... the kiosk can't write to it" quiet test "$(runuser -u kiosk -- touch /run/tvlink-usb/tvlink/x \
  >/dev/null 2>&1; echo $?)" != 0
check "... played ahead of synced content" within 10 from usb
check "... on screen" within 30 shows 33aa11
modprobe -r g_mass_storage
check "pulled out: unmounted" within 10 no mountpoint -q /run/tvlink-usb
check "... back to synced content" within 10 from synced
check "... on screen" within 30 shows 3311aa
tvlink set CONTENT_URL= USB_CONTENT=0 SOURCE=auto >/dev/null
empty() { [ -z "$(ls -A "$1")" ]; }
check "CONTENT_URL cleared: synced content removed" within 10 empty /var/lib/tvlink/content

echo "-- Last good screen"
tvlink set LAST_GOOD=1 >/dev/null
check "the agent keeps the live page" within 120 test -s /run/tvlink/last.jpg
systemctl start tvlink-lastgood
check "... root copies it to the card" test "$(stat -c '%U %a' /var/lib/tvlink/last.jpg)" = "root 644"
check "... the page, without the badge" img /var/lib/tvlink/last.jpg -400 -100 "$board"
sum=$(md5sum </var/lib/tvlink/last.jpg)
runuser -u kiosk -- ln -sf /etc/shadow /run/tvlink/last.jpg
systemctl start tvlink-lastgood
check "... a link planted there is not followed" test "$(md5sum </var/lib/tvlink/last.jpg)" = "$sum"
runuser -u kiosk -- rm -f /run/tvlink/last.jpg
systemctl stop tvlink-test-board
systemctl restart tvlink
check "board down, kiosk restarted: the splash has it" within 60 grep -qs '"state":"waiting".*"last":[1-9]' \
  /run/tvlink/status.js
check "... full screen" within 30 shows "$board"
check "... marked Offline" near "$(img /run/tvlink/screen.jpg -30 -40)" f04438
systemd-run -q --unit tvlink-test-board python3 -m http.server 8080 --bind 127.0.0.1 --directory /run/board
tvlink set LAST_GOOD=0 >/dev/null
check "LAST_GOOD=0 removes it" test ! -e /var/lib/tvlink/last.jpg

echo "-- Daily browser restart"
echo '99999 0' >/run/tvlink-test-uptime # past the first hour after boot, whenever the VM started
printf '[Service]\nEnvironment=TVLINK_UPTIME=/run/tvlink-test-uptime\n' \
  >/etc/systemd/system/tvlink.service.d/test-uptime.conf
systemctl daemon-reload
since=$(date '+%F %T')
tvlink set BROWSER_RESTART="$(date -d '+2 min' +%H:%M)" >/dev/null
check "the page is up" within 60 logged 'Badge: live'
was=$(pids)
check "Chromium restarts at BROWSER_RESTART" within 150 logged 'Daily browser restart'
new_chromium() { [ -n "$(pgrep -u kiosk -o -x chromium)" ] && [ "$(pids)" != "$was" ]; }
check "... a new Chromium" within 30 new_chromium
check "... the same cage" test "$(pids | cut -d' ' -f1)" = "${was%% *}"
check "... the page comes back" within 60 shows "$board"
command rm -f /etc/systemd/system/tvlink.service.d/test-uptime.conf
systemctl daemon-reload
tvlink set BROWSER_RESTART= >/dev/null

echo "== $fails failed"
[ "$fails" = 0 ]
