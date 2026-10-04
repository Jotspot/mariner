#!/bin/bash
# Fake hotspot clients for testing routing, kill switch and DNS without a phone.
#
#   sudo tests/hotspot-client.sh up [N]       create client N (default 0)
#   sudo tests/hotspot-client.sh run [N] CMD  run CMD inside it (e.g. curl ...)
#   sudo tests/hotspot-client.sh down [N]     remove it again
#
# Client 0 is netns "mclient" at 10.42.0.9 on veth mtest0; client N > 0 is
# "mclientN" at 10.42.0.(9-N) on mtestN: below NetworkManager's DHCP range
# (.10-.254), so a test client never steals a real phone's address. mariner-ctl treats the mtest*
# interfaces exactly like the real hotspot interface uap0, via
# /run/mariner/test-hotspot-ifs.
set -euo pipefail
TEST_FILE=/run/mariner/test-hotspot-ifs

client() {  # sets NS HOST_IF PEER CLIENT_IP for client $1
    local n=$1
    [[ "$n" =~ ^[0-7]$ ]] || { echo "client number must be 0-7" >&2; exit 1; }
    if [ "$n" = 0 ]; then NS=mclient PEER=mpeer; else NS=mclient$n PEER=mpeer$n; fi
    HOST_IF=mtest$n
    CLIENT_IP=10.42.0.$((9 - n))
}

cmd=${1:-}
shift || true
n=0
if [[ "${1:-}" =~ ^[0-7]$ ]]; then n=$1; shift; fi
client "$n"

case "$cmd" in
up)
    ip netns add "$NS"
    ip link add "$HOST_IF" type veth peer name "$PEER"
    ip link set "$PEER" netns "$NS"
    ip addr add 10.42.0.1/32 dev "$HOST_IF"
    ip link set "$HOST_IF" up
    ip route add "$CLIENT_IP/32" dev "$HOST_IF"
    nsenter --net="/run/netns/$NS" ip link set lo up
    nsenter --net="/run/netns/$NS" ip addr add "$CLIENT_IP/24" dev "$PEER"
    nsenter --net="/run/netns/$NS" ip link set "$PEER" up
    nsenter --net="/run/netns/$NS" ip route add default via 10.42.0.1
    mkdir -p "/etc/netns/$NS"
    echo "nameserver 10.42.0.1" > "/etc/netns/$NS/resolv.conf"
    mkdir -p "$(dirname "$TEST_FILE")"
    { cat "$TEST_FILE" 2>/dev/null || true; echo "$HOST_IF"; } | sort -u > "$TEST_FILE.new"
    mv "$TEST_FILE.new" "$TEST_FILE"
    /usr/local/lib/mariner/bin/mariner-ctl reconcile >/dev/null
    echo "client $CLIENT_IP ready in netns $NS"
    ;;
run)
    # Like `ip netns exec` (the client's own resolv.conf), but without its
    # /sys remount, which containers refuse.
    exec nsenter --net="/run/netns/$NS" unshare --mount sh -c \
        'mount --bind "/etc/netns/$0/resolv.conf" /etc/resolv.conf && exec "$@"' "$NS" "$@"
    ;;
down)
    if [ -f "$TEST_FILE" ]; then
        { grep -vx "$HOST_IF" "$TEST_FILE" || true; } > "$TEST_FILE.new"
        if [ -s "$TEST_FILE.new" ]; then mv "$TEST_FILE.new" "$TEST_FILE"; else rm -f "$TEST_FILE" "$TEST_FILE.new"; fi
    fi
    ip link del "$HOST_IF" 2>/dev/null || true
    ip netns del "$NS" 2>/dev/null || true
    rm -rf "/etc/netns/$NS"
    /usr/local/lib/mariner/bin/mariner-ctl reconcile >/dev/null
    echo "client $CLIENT_IP removed"
    ;;
*)
    echo "usage: $0 up [N] | run [N] CMD... | down [N]" >&2
    exit 1
    ;;
esac
