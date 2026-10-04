#!/bin/bash
# Installer tests in throwaway containers (run as root on the Pi, after ct.sh exists).
set -uo pipefail
CT="$(dirname "$0")/ct.sh"
BOOT='git config --global --add safe.directory /src/mariner/.git; git config --global --add safe.directory /src/mariner; curl -fsS file:///src/mariner/bootstrap.sh | bash -s -- --repo /src/mariner'
EVPN=/root/expressvpn.run
snapshot() {  # facts to compare across runs (password as a hash only)
    bash "$CT" run "$1" 'echo "hostname=$(hostname)"; echo "ssid=$(nmcli -g 802-11-wireless.ssid con show mariner-hotspot)"; echo "psk_sha=$(nmcli -s -g 802-11-wireless-security.psk con show mariner-hotspot | sha256sum | cut -c1-12)"; echo "hotspot_dnsmasq_pid=$(pgrep -f \"dnsmasq.*uap0\" | head -1)"; echo "outline=$([ -x /usr/local/bin/sslocal ] && echo yes || echo no)"; echo "evpn=$([ -x /opt/expressvpn/bin/expressvpnctl ] && echo yes || echo no)"; echo "conf=$(cat /etc/mariner/install.conf 2>/dev/null)"; echo "vpn=$(echo "{}" | /usr/local/lib/mariner/bin/mariner-ctl vpn-get | jq -c "{enabled,provider,killswitch}")"'
}
checks() {  # common post-install checks
    bash "$CT" run "$1" 'systemctl is-active mariner-web mariner-dns mariner-check.timer | tr "\n" " "; echo; nmcli -t -f DEVICE,STATE,CONNECTION dev | grep -E "uap0|wlan0"; iw dev uap0 info 2>/dev/null | grep -E "ssid|type"; stat -c "log mode %a" /var/log/mariner-install.log; psk=$(nmcli -s -g 802-11-wireless-security.psk con show mariner-hotspot 2>/dev/null); if [ -n "$psk" ] && grep -qF "$psk" /var/log/mariner-install.log; then echo "!! PASSWORD IN LOG"; else echo "password not in log"; fi; ls /etc/netplan 2>&1 | head -1; dig +short $(hostname) @10.42.0.1 -p 5354 2>/dev/null | head -1'
}

echo "######## T1: fresh install --yes --no-geph (no ExpressVPN)"
bash "$CT" up ta 5
bash "$CT" run ta "time ($BOOT --yes --no-geph --ssid 'Test Box') > /root/t1.log 2>&1; echo T1 EXIT=\$?"
bash "$CT" run ta 'tail -14 /root/t1.log | sed "s/\x1b\[[0-9;]*m//g"'
checks ta
snapshot ta > /tmp/ta.1

echo "######## T2: idempotent re-run --yes"
bash "$CT" run ta "($BOOT --yes) > /root/t2.log 2>&1; echo T2 EXIT=\$?"
bash "$CT" run ta 'grep -E "Plan" -A8 /root/t2.log | sed "s/\x1b\[[0-9;]*m//g"'
snapshot ta > /tmp/ta.2
diff /tmp/ta.1 /tmp/ta.2 && echo "T2: nothing changed"

echo "######## T6: rollback scripts without netplan"
bash "$CT" run ta 'ls /etc/netplan 2>&1 | head -1; S=$(/usr/local/lib/mariner/bin/mariner-snapshot) && echo "snapshot $S ok" && ls $S; S2=$(/usr/local/lib/mariner/bin/mariner-snapshot); echo "second: $S2"; /usr/local/lib/mariner/bin/mariner-restore "$S" && echo "restore rc=$?"; sleep 8; nmcli -t -f NAME con show | sort | tr "\n" " "; echo'

echo "######## T3: --add-expressvpn later"
bash "$CT" run ta "($BOOT --add-expressvpn $EVPN) > /root/t3.log 2>&1; echo T3 EXIT=\$?"
bash "$CT" run ta 'tail -12 /root/t3.log | sed "s/\x1b\[[0-9;]*m//g"; ls /etc/systemd/system/expressvpn-service.service.d/; systemctl is-enabled expressvpn-service 2>&1; systemctl is-active expressvpn-service 2>&1'
snapshot ta > /tmp/ta.3
diff /tmp/ta.2 /tmp/ta.3 && echo "T3: nothing else changed" || echo "(diff above: only evpn should change)"
bash "$CT" down ta 5

echo "######## T4: fresh install with ExpressVPN from the start"
bash "$CT" up tb 6
bash "$CT" run tb "($BOOT --yes --no-geph --expressvpn-installer $EVPN) > /root/t4.log 2>&1; echo T4 EXIT=\$?"
bash "$CT" run tb 'tail -16 /root/t4.log | sed "s/\x1b\[[0-9;]*m//g"'
checks tb
snapshot tb > /tmp/tb.1
echo "######## T5: re-run of T4"
bash "$CT" run tb "($BOOT --yes) > /root/t5.log 2>&1; echo T5 EXIT=\$?"
snapshot tb > /tmp/tb.2
diff /tmp/tb.1 /tmp/tb.2 && echo "T5: nothing changed"
bash "$CT" down tb 6
