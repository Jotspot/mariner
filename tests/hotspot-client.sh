#!/bin/bash
# Fake hotspot client for testing routing, kill switch and DNS without a phone.
#
#   sudo tests/hotspot-client.sh up       create netns "mclient" (10.42.0.250)
#   sudo tests/hotspot-client.sh run CMD  run CMD inside it (e.g. curl ...)
#   sudo tests/hotspot-client.sh down     remove it again
#
# The namespace hangs off a veth (mtest0) that mariner-ctl treats exactly like
# the real hotspot interface uap0, via /run/mariner/test-hotspot-ifs.
set -euo pipefail
NS=mclient HOST_IF=mtest0 PEER=mpeer CLIENT_IP=10.42.0.250
TEST_FILE=/run/mariner/test-hotspot-ifs

case "${1:-}" in
up)
    ip netns add "$NS"
    ip link add "$HOST_IF" type veth peer name "$PEER"
    ip link set "$PEER" netns "$NS"
    ip addr add 10.42.0.1/32 dev "$HOST_IF"
    ip link set "$HOST_IF" up
    ip route add "$CLIENT_IP/32" dev "$HOST_IF"
    ip -n "$NS" link set lo up
    ip -n "$NS" addr add "$CLIENT_IP/24" dev "$PEER"
    ip -n "$NS" link set "$PEER" up
    ip -n "$NS" route add default via 10.42.0.1
    mkdir -p "/etc/netns/$NS"
    echo "nameserver 10.42.0.1" > "/etc/netns/$NS/resolv.conf"
    echo "$HOST_IF" > "$TEST_FILE"
    /usr/local/lib/mariner/bin/mariner-ctl reconcile >/dev/null
    echo "client $CLIENT_IP ready in netns $NS"
    ;;
run)
    shift
    exec ip netns exec "$NS" "$@"
    ;;
down)
    rm -f "$TEST_FILE"
    ip link del "$HOST_IF" 2>/dev/null || true
    ip netns del "$NS" 2>/dev/null || true
    rm -rf "/etc/netns/$NS"
    /usr/local/lib/mariner/bin/mariner-ctl reconcile >/dev/null
    echo "client removed"
    ;;
*)
    echo "usage: $0 up|run CMD...|down" >&2
    exit 1
    ;;
esac
