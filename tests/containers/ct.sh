#!/bin/bash
# Throwaway installer-test containers with a simulated Wi-Fi radio (run as root on the Pi).
#   ct.sh up NAME IDX     copy the clean rootfs to NAME, boot it, network it, give it a radio
#   ct.sh down NAME IDX   remove it again
#   ct.sh run NAME CMD    run CMD inside (bash -c), output to stdout
set -euo pipefail
CLEAN=${CLEAN:-/var/lib/machines/mariner-test-base}   # debootstrap trixie here first (see README)
cmd=$1 M=$2
case "$cmd" in
up)
    i=$3   # 1..9: veth subnet 10.201.$i.0/30
    rm -rf "/var/lib/machines/$M"
    cp -a "$CLEAN" "/var/lib/machines/$M"
    echo "$M" > "/var/lib/machines/$M/etc/hostname"
    install -d "/var/lib/machines/$M/root"
    # Optional: ExpressVPN installer for the ExpressVPN tests (EVPN_RUN=/path/to/expressvpn-linux-universal-*.run)
    [ -z "${EVPN_RUN:-}" ] || cp "$EVPN_RUN" "/var/lib/machines/$M/root/expressvpn.run"
    printf "[Exec]\nBoot=yes\n[Network]\nVirtualEthernet=yes\n[Files]\nBindReadOnly=/opt/mariner:/src/mariner\n" \
        > "/etc/systemd/nspawn/$M.nspawn"
    machinectl start "$M"; sleep 12
    ip addr replace "10.201.$i.1/30" dev "ve-$M"; ip link set "ve-$M" up
    printf "table ip ${M}_nat {\n chain post {\n  type nat hook postrouting priority srcnat\n  ip saddr 10.201.$i.0/30 masquerade\n }\n}\n" | nft -f -
    systemd-run -M "$M" --wait -q -P sh -c "nmcli con add type ethernet ifname host0 con-name uplink ipv4.method manual ipv4.addresses 10.201.$i.2/30 ipv4.gateway 10.201.$i.1 ipv4.dns 1.1.1.1 ipv6.method disabled >/dev/null; nmcli con up uplink >/dev/null; sleep 2; curl -s -m 10 -o /dev/null -w 'internet %{http_code}\n' https://deb.debian.org/"
    # simulated radio
    [ -f /etc/NetworkManager/conf.d/99-mtest-hwsim.conf ] || {
        printf "[keyfile]\nunmanaged-devices=driver:mac80211_hwsim\n" > /etc/NetworkManager/conf.d/99-mtest-hwsim.conf
        nmcli general reload conf; }
    lsmod | grep -q mac80211_hwsim || modprobe mac80211_hwsim radios=4
    sleep 1
    PHY=""
    for p in /sys/class/ieee80211/*; do
        [ "$(basename "$(readlink -f "$p/device/driver")")" = mac80211_hwsim ] && [ -d "$p/device/net" ] \
            && [ -n "$(ls "$p/device/net" 2>/dev/null)" ] && { PHY=$(basename "$p"); break; }
    done
    [ -n "$PHY" ] || { echo "no free hwsim radio"; exit 1; }
    IF=$(ls "/sys/class/ieee80211/$PHY/device/net/" | head -1)
    iw phy "$PHY" set netns "$(machinectl show "$M" -p Leader --value)"
    systemd-run -M "$M" --wait -q -P sh -c "ip link set $IF down; ip link set $IF name wlan0; ip -br link | grep wlan0"
    ;;
down)
    i=$3
    machinectl poweroff "$M" 2>/dev/null || true
    sleep 5
    machinectl terminate "$M" 2>/dev/null || true
    nft delete table ip "${M}_nat" 2>/dev/null || true
    rm -rf "/var/lib/machines/$M" "/etc/systemd/nspawn/$M.nspawn"
    ;;
run)
    shift 2
    systemd-run -M "$M" --setenv=HOME=/root --setenv=LANG=C.UTF-8 --wait -q -P bash -c "$*"
    ;;
esac
