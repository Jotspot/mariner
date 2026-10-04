#!/bin/bash
# End-to-end captive portal test with simulated radios (run as root on the Pi).
set -uo pipefail
CT="$(dirname "$0")/ct.sh"
C=/usr/local/lib/mariner/bin/mariner-ctl
BOOT='git config --global --add safe.directory /src/mariner/.git; git config --global --add safe.directory /src/mariner; curl -fsS file:///src/mariner/bootstrap.sh | bash -s -- --repo /src/mariner'
st() { bash "$CT" run mar "echo '{}' | $C vpn-get | jq -c '{mode,connection,suspect_portal,login_window_ips}'; jq -c '{state,portal_url}' /run/mariner/portal.json"; }

echo "#### hotel container: AP + click-through portal"
bash "$CT" up hotel 7
cp "$(dirname "$0")/hotel-setup.sh" /var/lib/machines/hotel/root/
bash "$CT" run hotel 'bash /root/hotel-setup.sh'

echo "#### mariner container: install (no Geph), Outline with an unreachable server, VPN on, kill switch on"
bash "$CT" up mar 8
bash "$CT" run mar "($BOOT --yes --no-geph) > /root/inst.log 2>&1; echo install EXIT=\$?"
bash "$CT" run mar "echo '{\"provider\": \"outline\", \"outline_key\": \"ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTpkdW1teXBhc3M@203.0.113.7:8388#Unreachable\"}' | $C vpn-set >/dev/null; $C vpn-enable on >/dev/null; echo vpn on"

echo "#### join the hotel network"
bash "$CT" run mar "echo '{\"ssid\": \"Harbor-Hotel-Guest\"}' | $C wifi-connect; sleep 3; ip -4 -br addr show wlan0"
bash "$CT" run mar "/usr/local/lib/mariner/bin/mariner-check --quiet; true"
st

echo "#### a hotspot device, before the window: blocked"
bash "$CT" run mar "/src/mariner/tests/hotspot-client.sh up 0 >/dev/null; /src/mariner/tests/hotspot-client.sh run 0 curl -s -m 6 -o /dev/null -w 'client http %{http_code}\n' http://example.com/ || echo 'client http blocked'"

echo "#### Allow this device (10.42.0.9) -> it reaches the hotel portal and logs in"
bash "$CT" run mar "$C portal-login-allow 10.42.0.9 >/dev/null; echo allowed"
bash "$CT" run mar "/src/mariner/tests/hotspot-client.sh run 0 curl -s -m 8 -o /dev/null -w 'client http %{http_code} -> %{redirect_url}\n' http://example.com/"
bash "$CT" run mar "/src/mariner/tests/hotspot-client.sh run 0 curl -s -m 8 -X POST http://192.168.77.1:8080/login; echo"
bash "$CT" run hotel 'cat /var/log/hotel-portal.log; nft list set ip hotel authed | grep elements'

echo "#### Mariner notices (watcher checks every 10 s): window closes, VPN resumes"
for i in $(seq 1 9); do
    sleep 10
    s=$(bash "$CT" run mar "jq -r .state /run/mariner/portal.json; [ -e /run/mariner/portal-login.json ] && echo window-open || echo window-closed" | tr '\n' ' ')
    echo "+$((i*10))s: $s"
    case "$s" in *online*window-closed*) break ;; esac
done
st
bash "$CT" run mar "journalctl -t mariner-ctl -t mariner-check --no-pager -o cat | grep -E 'uplink state|login window|Outline' | tail -8"

echo "#### afterwards the device is behind the kill switch again (Outline server unreachable)"
bash "$CT" run mar "/src/mariner/tests/hotspot-client.sh run 0 curl -s -m 6 -o /dev/null -w 'client http %{http_code}\n' http://example.com/ || echo 'client http blocked'"

bash "$CT" down mar 8
bash "$CT" down hotel 7
