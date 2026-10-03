#!/bin/bash
# Install Mariner from this checkout onto the system. Idempotent; run as root.
# Normally called by bootstrap.sh; also used to deploy changes (git pull/push
# into /opt/mariner, then `sudo ./install.sh`).
#
# Code is copied to /usr/local/lib/mariner (root-owned) so that anything run
# via sudo or systemd cannot be modified by non-root users.
#
# Environment (all optional):
#   MARINER_HOTSPOT=auto|yes|no       create/manage the hotspot (auto: if wlan0 exists)
#   MARINER_HOTSPOT_SSID, MARINER_HOTSPOT_PASSWORD
#                                     set on first install; also applied to an
#                                     existing hotspot when given explicitly
#   MARINER_OUTLINE=yes|no            install the Outline client (shadowsocks-rust)
#   GEPH_SRC=PATH                     copy this geph5-client build into place
set -euo pipefail
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

LIB=/usr/local/lib/mariner
HOTSPOT=mariner-hotspot
WANT_HOTSPOT=${MARINER_HOTSPOT:-auto}
if [ "$WANT_HOTSPOT" = auto ]; then
    [ -e /sys/class/net/wlan0 ] && WANT_HOTSPOT=yes || WANT_HOTSPOT=no
fi

# --- code -------------------------------------------------------------------
install -d -m 0755 "$LIB" "$LIB/bin"
install -m 0755 bin/* "$LIB/bin/"
# /etc/mariner: root only, except that group mariner may read portal.json
# (password hash) inside it. VPN files stay root 0600. Set the final mode
# right away: a 0700 window would make the portal look unconfigured.
id mariner >/dev/null 2>&1 || useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin mariner
install -d -m 0750 -g mariner /etc/mariner
install -d -m 0755 /var/lib/mariner
rm -f /run/mariner/geph.json   # pre-Outline state file

for f in "$LIB"/bin/*; do
    [ -f "$f" ] && ln -sf "$f" /usr/local/sbin/"$(basename "$f")"
done
rm -f /usr/local/sbin/__pycache__

# --- migrations (before any unit files are replaced) -----------------------
# Before Outline support the VPN target was mariner-geph.target and the tunnel
# was geph0. Stop the old units while their old PartOf= links still exist,
# or the old tun2socks keeps running (and the kill switch blocks everything).
if [ -f /etc/systemd/system/mariner-geph.target ]; then
    systemctl stop mariner-geph.target mariner-tun.service mariner-dns.service 2>/dev/null || true
    rm -f /etc/systemd/system/mariner-geph.target
fi

# --- phase 2: uplink + hotspot ---------------------------------------------
install -m 0644 nm/udev/90-mariner-uap0.rules /etc/udev/rules.d/
udevadm control --reload 2>/dev/null || true
install -m 0755 nm/dispatcher/* /etc/NetworkManager/dispatcher.d/
install -d -m 0755 /etc/NetworkManager/conf.d
if ! cmp -s nm/conf.d/90-mariner-wifi.conf /etc/NetworkManager/conf.d/90-mariner-wifi.conf ||
   ! cmp -s nm/conf.d/91-mariner-unmanaged.conf /etc/NetworkManager/conf.d/91-mariner-unmanaged.conf; then
    install -m 0644 nm/conf.d/*.conf /etc/NetworkManager/conf.d/
    nmcli general reload conf
fi
# Apply now as well (NM applies its setting on the next activation).
for d in wlan0 uap0; do iw dev "$d" set power_save off 2>/dev/null || true; done
nmcli general reload conf 2>/dev/null || true
install -d -m 0755 /etc/NetworkManager/dnsmasq-shared.d
DNSMASQ_CHANGED=0
cmp -s nm/dnsmasq-shared.d/mariner.conf /etc/NetworkManager/dnsmasq-shared.d/mariner.conf || DNSMASQ_CHANGED=1
install -m 0644 nm/dnsmasq-shared.d/mariner.conf /etc/NetworkManager/dnsmasq-shared.d/

if [ "$WANT_HOTSPOT" = yes ]; then
    # Create uap0 now if the udev rule hasn't (first install, no reboot yet).
    ip link show uap0 >/dev/null 2>&1 || iw dev wlan0 interface add uap0 type __ap

    SSID=${MARINER_HOTSPOT_SSID:-Mariner}
    if ! nmcli -t -f NAME con show | grep -qx "$HOTSPOT"; then
        psk=${MARINER_HOTSPOT_PASSWORD:-$(LC_ALL=C tr -dc 'a-km-np-z2-9' </dev/urandom | head -c 12)}
        nmcli con add type wifi ifname uap0 con-name "$HOTSPOT" autoconnect yes ssid "$SSID" \
            802-11-wireless.mode ap 802-11-wireless.band bg 802-11-wireless.channel 6 \
            ipv4.method shared ipv4.addresses 10.42.0.1/24 ipv6.method disabled \
            wifi-sec.key-mgmt wpa-psk wifi-sec.proto rsn \
            wifi-sec.pairwise ccmp wifi-sec.group ccmp wifi-sec.psk "$psk" >/dev/null
        [ -n "${MARINER_HOTSPOT_PASSWORD:-}" ] || echo "created hotspot '$SSID' with password: $psk"
    else
        # Explicit settings on a re-run update the existing hotspot.
        [ -z "${MARINER_HOTSPOT_SSID:-}" ] || nmcli con modify "$HOTSPOT" 802-11-wireless.ssid "$SSID"
        [ -z "${MARINER_HOTSPOT_PASSWORD:-}" ] || nmcli con modify "$HOTSPOT" wifi-sec.psk "$MARINER_HOTSPOT_PASSWORD"
    fi
    # Client profiles created by Mariner are pinned to wlan0, but profiles that
    # came from netplan (cloud-init) can't hold an interface name and match any
    # Wi-Fi device. Top priority makes NM always pick the hotspot for uap0.
    nmcli con modify "$HOTSPOT" connection.autoconnect-priority 100 connection.autoconnect-retries 0
fi

install -m 0644 systemd/*.service systemd/*.timer systemd/*.target /etc/systemd/system/
systemctl daemon-reload
if [ "$WANT_HOTSPOT" = yes ]; then
    systemctl enable --now mariner-hotspot-sync.timer
fi

# Avahi: advertise mariner.local only on the hotspot and ethernet, so phones
# on the hotspot get 10.42.0.1 and the upstream network doesn't see us.
AVAHI=/etc/avahi/avahi-daemon.conf
if [ -f "$AVAHI" ]; then
    [ -f "$AVAHI.orig-mariner" ] || cp -a "$AVAHI" "$AVAHI.orig-mariner"
    if ! grep -qx 'allow-interfaces=uap0,eth0' "$AVAHI"; then
        sed -i -E 's/^#?allow-interfaces=.*/allow-interfaces=uap0,eth0/' "$AVAHI"
        systemctl restart avahi-daemon 2>/dev/null || true
    fi
fi

if [ "$WANT_HOTSPOT" = yes ]; then
    # Restart the hotspot only if its dnsmasq config changed (drops clients).
    [ "$DNSMASQ_CHANGED" = 1 ] && nmcli con up "$HOTSPOT" >/dev/null 2>&1 || true
    "$LIB/bin/mariner-hotspot-sync" >/dev/null || echo "warning: hotspot did not start" >&2
fi

# --- phase 3: captive portal detection --------------------------------------
systemctl enable --now mariner-check.timer

# --- phase 4: VPN (Geph, Outline) ----------------------------------------------
# Third-party binaries (tun2socks, shadowsocks-rust): pinned + checksummed.
MARINER_OUTLINE=${MARINER_OUTLINE:-yes} tools/fetch-binaries.sh

# geph5-client is built from crates.io with `cargo install --locked
# geph5-client` as the admin user; copy the newest build into place.
GEPH_SRC=${GEPH_SRC:-$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)/.cargo/bin/geph5-client}
if [ -x "$GEPH_SRC" ] && ! cmp -s "$GEPH_SRC" /usr/local/bin/geph5-client; then
    install -m 0755 "$GEPH_SRC" /usr/local/bin/geph5-client
    echo "installed geph5-client from $GEPH_SRC"
fi
[ -x /usr/local/bin/geph5-client ] || echo "note: Geph isn't installed (geph5-client missing); Outline/ExpressVPN still work" >&2
[ -x /usr/local/bin/tun2socks ] || echo "warning: /usr/local/bin/tun2socks missing" >&2

# ExpressVPN (optional; installed separately with its own installer, see
# README): its daemon only ever runs inside the evpn sandbox, and only when
# Mariner starts it, not at boot.
install -d -m 0755 /etc/systemd/system/expressvpn-service.service.d
install -m 0644 systemd/expressvpn-service.service.d/mariner.conf /etc/systemd/system/expressvpn-service.service.d/
rm -f /etc/systemd/system/expressvpn-service.service.d/mariner-sandbox.conf
nft delete table ip mariner_evpn 2>/dev/null || true   # leftover from the trial
systemctl daemon-reload
if [ -f /etc/systemd/system/expressvpn-service.service ]; then
    systemctl disable expressvpn-service.service 2>/dev/null || true
fi
systemctl enable mariner-reconcile.service mariner-firewall-early.service
"$LIB/bin/mariner-ctl" reconcile >/dev/null

# --- phase 5: web portal ----------------------------------------------------------
[ -x "$LIB/venv/bin/python" ] || python3 -m venv "$LIB/venv"
"$LIB/venv/bin/pip" install -q --disable-pip-version-check -r web/requirements.txt
install -d -m 0755 "$LIB/web"
# Stop first so the old process never renders new templates with old code.
systemctl stop mariner-web.service 2>/dev/null || true
rsync -a --delete --exclude __pycache__ web/ "$LIB/web/"
chown -R root:root "$LIB/web"

SUDOERS=$(mktemp)
echo "mariner ALL=(root) NOPASSWD: $LIB/bin/mariner-ctl" > "$SUDOERS"
visudo -cqf "$SUDOERS" && install -m 0440 "$SUDOERS" /etc/sudoers.d/mariner-web
rm -f "$SUDOERS"

systemctl enable mariner-web.service
systemctl restart mariner-web.service

echo "mariner installed to $LIB"
