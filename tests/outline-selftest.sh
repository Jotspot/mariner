#!/bin/bash
# Self-test for Mariner's Outline support, without touching the live VPN.
#
# Starts a throwaway Shadowsocks server on 127.0.0.1, builds ss:// access keys
# for it in several formats, runs them through mariner-ctl's own parser and
# config writer, starts sslocal on a spare SOCKS port, and fetches a page
# through it. Run as root on the Pi.
set -euo pipefail
LIB=/usr/local/lib/mariner
PW=$(head -c 16 /dev/urandom | base64 | tr -d '/+=')
SRV_PORT=18388 SOCKS_PORT=19909 METHOD=chacha20-ietf-poly1305
work=$(mktemp -d)
cleanup() { kill "${SRV:-}" "${CLI:-}" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT

ssserver -U -s "127.0.0.1:$SRV_PORT" -k "$PW" -m "$METHOD" >"$work/server.log" 2>&1 &
SRV=$!
sleep 1

userinfo=$(printf '%s:%s' "$METHOD" "$PW" | base64 -w0 | tr '+/' '-_' | tr -d '=')
legacy=$(printf '%s:%s@127.0.0.1:%s' "$METHOD" "$PW" "$SRV_PORT" | base64 -w0)
keys=(
    "ss://$userinfo@127.0.0.1:$SRV_PORT/?outline=1#Mariner%20selftest"   # Outline style (SIP002)
    "ss://$METHOD:$PW@127.0.0.1:$SRV_PORT#plain"                         # plain userinfo
    "ss://$legacy#legacy"                                               # legacy base64
)

python3 - "$work" "$SOCKS_PORT" "${keys[@]}" <<'EOF'
import importlib.machinery, importlib.util, json, sys
loader = importlib.machinery.SourceFileLoader("ctl", "/usr/local/lib/mariner/bin/mariner-ctl")
spec = importlib.util.spec_from_loader("ctl", loader)
ctl = importlib.util.module_from_spec(spec)
loader.exec_module(ctl)
work, port, keys = sys.argv[1], sys.argv[2], sys.argv[3:]
for k in keys:
    o = ctl.outline_from_key(k)
    assert o["server"] == "127.0.0.1" and o["method"] == "chacha20-ietf-poly1305", o
    print(f"parsed ok: {k.split('@')[0][:14]}... name={o['name']!r}")
for bad in ("ss://abc", "ss://Y2hhY2hhMjA6eA@1.2.3.4:443/?prefix=%16%03", "http://x", "ss://bm9uZTpwdw@1.2.3.4:443"):
    try:
        ctl.outline_from_key(bad)
        print("NOT rejected:", bad); sys.exit(1)
    except ctl.Fail as e:
        print(f"rejected ok: {bad[:30]:30} -> {e}")
# Same config writer as the live service, but on a spare SOCKS port.
ctl.OUTLINE_CONF = f"{work}/outline.json"
ctl.SOCKS = f"127.0.0.1:{port}"
ctl.write_outline_conf({"outline": ctl.outline_from_key(keys[0])})
EOF

sslocal -c "$work/outline.json" >"$work/client.log" 2>&1 &
CLI=$!
sleep 1
echo "through sslocal -> ssserver: $(curl -s -m 10 --socks5-hostname 127.0.0.1:$SOCKS_PORT -o /dev/null -w '%{http_code}' https://example.com)"
echo "UDP (DNS) through sslocal:   $(python3 - "$SOCKS_PORT" <<'EOF'
import socket, struct, sys
port = int(sys.argv[1])
s = socket.create_connection(("127.0.0.1", port), timeout=5)
s.sendall(b"\x05\x01\x00"); s.recv(2)
s.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00"); r = s.recv(10)
relay = (socket.inet_ntoa(r[4:8]), struct.unpack(">H", r[8:10])[0])
q = b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01"
u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.settimeout(5)
u.sendto(b"\x00\x00\x00\x01" + socket.inet_aton("1.1.1.1") + struct.pack(">H", 53) + q, relay)
d, _ = u.recvfrom(2048)
print("answer received" if d[10:12] == b"\x12\x34" else "bad answer")
EOF
)"
