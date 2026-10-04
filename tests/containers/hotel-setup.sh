#!/bin/bash
# Inside the "hotel" container: an open Wi-Fi network with a click-through
# captive portal (like openNDS): unauthenticated clients get DNS, and every
# plain-HTTP request is redirected to the login page; after "Accept", the
# client's address is let through.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q >/dev/null
apt-get install -y -q --no-install-recommends hostapd dnsmasq nftables python3 iw >/dev/null
systemctl disable --now dnsmasq hostapd 2>/dev/null || true  # the packaged instances
nmcli dev set wlan0 managed no 2>/dev/null || true
ip link set wlan0 up
ip addr replace 192.168.77.1/24 dev wlan0
cat > /etc/hostapd/hotel.conf <<'EOF'
interface=wlan0
driver=nl80211
ssid=Harbor-Hotel-Guest
hw_mode=g
channel=6
auth_algs=1
EOF
cat > /etc/hotel-dnsmasq.conf <<'EOF'
interface=wlan0
bind-interfaces
listen-address=192.168.77.1
dhcp-range=192.168.77.50,192.168.77.150,12h
dhcp-option=option:router,192.168.77.1
dhcp-option=option:dns-server,192.168.77.1
server=1.1.1.1
no-resolv
EOF
sysctl -qw net.ipv4.ip_forward=1
nft -f - <<'EOF'
table ip hotel {}
delete table ip hotel
table ip hotel {
    set authed { type ipv4_addr; }
    chain pre {
        type nat hook prerouting priority dstnat; policy accept;
        iifname "wlan0" ip saddr != @authed tcp dport 80 dnat to 192.168.77.1:8080
    }
    chain forwarding {
        type filter hook forward priority filter; policy accept;
        iifname "wlan0" ip saddr != @authed counter drop
    }
    chain post {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "host0" masquerade
    }
}
EOF
cat > /usr/local/bin/hotel-portal <<'EOF'
#!/usr/bin/env python3
import http.server, subprocess, urllib.parse
PAGE = b"""<html><head><title>Harbor Hotel Wi-Fi</title></head><body><h1>Welcome to Harbor Hotel</h1>
<form method="post" action="/login"><button>Accept and connect</button></form></body></html>"""
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/login"):
            self.send_response(200); self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(PAGE))); self.end_headers(); self.wfile.write(PAGE)
        else:
            self.send_response(302)
            self.send_header("Location", "http://192.168.77.1:8080/login?orig=" + urllib.parse.quote(self.headers.get("Host", "") + self.path))
            self.send_header("Content-Length", "0"); self.end_headers()
    def do_POST(self):
        ip = self.client_address[0]
        subprocess.run(["nft", "add", "element", "ip", "hotel", "authed", "{", ip, "}"], check=False)
        body = b"<html><body>You're online. Enjoy your stay.</body></html>"
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
        with open("/var/log/hotel-portal.log", "a") as f:
            f.write(f"login from {ip}\n")
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("192.168.77.1", 8080), H).serve_forever()
EOF
chmod +x /usr/local/bin/hotel-portal
systemd-run --unit hotel-ap /usr/sbin/hostapd /etc/hostapd/hotel.conf
systemd-run --unit hotel-dns /usr/sbin/dnsmasq -k -C /etc/hotel-dnsmasq.conf
systemd-run --unit hotel-portal /usr/local/bin/hotel-portal
sleep 3
systemctl is-active hotel-ap hotel-dns hotel-portal | tr '\n' ' '; echo
iw dev wlan0 info | grep -E "ssid|type|channel"
