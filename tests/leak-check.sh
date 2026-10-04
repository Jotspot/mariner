#!/bin/bash
# Kill-switch and DNS-leak check from fake hotspot clients (tests/hotspot-client.sh).
#
#   sudo tests/leak-check.sh LABEL [N...]     clients to test (default: 0)
#
# Each client looks up the router's own name, a unique random name, and
# fetches a unique plain-HTTP URL from 1.1.1.1, while tcpdump watches wlan0
# and eth0. Traffic that went through the VPN is encrypted there, so if a
# client's marker shows up in either capture, that client's traffic or DNS
# left in the clear. One line per client:
#
#   LABEL client=IP name=<router name answer> dns=<rcode> http=<ok|fail> wlan0=<clean|SEEN> eth0=<clean|SEEN>
set -uo pipefail
LABEL=${1:?usage: leak-check.sh LABEL [N...]}
shift
CLIENTS=("$@")
[ ${#CLIENTS[@]} -gt 0 ] || CLIENTS=(0)
HERE=$(cd "$(dirname "$0")" && pwd)
NAME=$(hostname -s)
TMP=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$TMP"' EXIT

command -v tcpdump >/dev/null || { echo "tcpdump isn't installed (apt install tcpdump)" >&2; exit 2; }
declare -A CAP
for dev in wlan0 eth0; do
    if [ ! -e "/sys/class/net/$dev" ]; then CAP[$dev]=absent; continue; fi
    tcpdump -i "$dev" -nn -l -A -s 0 'port 53 or port 80' >"$TMP/$dev.txt" 2>"$TMP/$dev.err" &
    CAP[$dev]=$!
done
sleep 2
for dev in wlan0 eth0; do  # a capture that isn't running would make everything look clean
    pid=${CAP[$dev]}
    if [ "$pid" != absent ] && ! kill -0 "$pid" 2>/dev/null; then
        echo "tcpdump on $dev isn't running: $(head -c 200 "$TMP/$dev.err")" >&2
        exit 2
    fi
done

for n in "${CLIENTS[@]}"; do
    m="mleak$RANDOM$RANDOM"
    echo "$m" > "$TMP/marker.$n"
    run() { "$HERE/hotspot-client.sh" run "$n" "$@"; }
    ip=$(run ip -4 -o addr show | awk '/mpeer/ {print $4}' | cut -d/ -f1)
    name=$(run dig +short +time=3 +tries=1 "$NAME" @10.42.0.1 | head -1)
    rc=$(run dig +time=4 +tries=1 "$m.example.com" @10.42.0.1 | awk '/status:/ {gsub(",", "", $6); print $6}')
    if run curl -s -m 6 -o /dev/null "http://1.1.1.1/$m"; then http=ok; else http=fail; fi
    echo "$n $ip ${name:-none} ${rc:-timeout} $http" >> "$TMP/results"
done
sleep 2
kill $(jobs -p) 2>/dev/null
wait 2>/dev/null

while read -r n ip name rc http; do
    m=$(cat "$TMP/marker.$n")
    w=clean; e=clean
    [ "${CAP[wlan0]}" = absent ] && w=absent
    [ "${CAP[eth0]}" = absent ] && e=absent
    grep -q "$m" "$TMP/wlan0.txt" 2>/dev/null && w=SEEN
    grep -q "$m" "$TMP/eth0.txt" 2>/dev/null && e=SEEN
    echo "$LABEL client=$ip name=$name dns=$rc http=$http wlan0=$w eth0=$e"
done < "$TMP/results"
