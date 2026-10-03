#!/bin/bash
# Simulate a captive portal on the uplink, for testing mariner-check and the
# Geph interlock without a hotel:
#
#   sudo tests/fake-portal.sh on [redirect|meta]   all port-80 traffic the Pi
#                                                  sends out wlan0 hits a fake portal
#   sudo tests/fake-portal.sh off
#
# Only the Pi's own outgoing HTTP is redirected (nft output hook), so the
# connectivity probes see a portal while everything else is unaffected.
set -euo pipefail
WLAN_IP=$(ip -4 -o addr show wlan0 | awk '{print $4}' | cut -d/ -f1)
PIDFILE=/run/mariner/fake-portal.pid

case "${1:-}" in
on)
    mode=${2:-redirect}
    # Detached, so it doesn't hold an SSH session open.
    setsid python3 - "$mode" >/dev/null 2>&1 <<'EOF' &
import http.server, sys
mode = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if mode == "redirect":
            self.send_response(302)
            self.send_header("Location", "http://login.hotelwifi.test/portal?orig=" + self.path)
            self.end_headers()
        else:
            body = b'<html><head><meta http-equiv="refresh" content="0; url=https://wifi.cafe.test/welcome"></head><body>Login</body></html>'
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
    def log_message(self, *a):
        pass
http.server.HTTPServer(("0.0.0.0", 8099), H).serve_forever()
EOF
    echo $! > "$PIDFILE"
    printf 'table ip mariner_test {\n chain out {\n  type nat hook output priority -100\n  oifname "wlan0" tcp dport 80 dnat to %s:8099\n }\n}\n' "$WLAN_IP" | nft -f -
    sleep 1
    echo "fake portal ($mode) on"
    ;;
off)
    nft delete table ip mariner_test 2>/dev/null || true
    [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
    echo "fake portal off"
    ;;
*)
    echo "usage: $0 on [redirect|meta] | off" >&2
    exit 1
    ;;
esac
