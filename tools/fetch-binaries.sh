#!/bin/bash
# Download the third-party binaries Mariner uses, verify their SHA-256 and
# install them to /usr/local/bin. Run as root. Idempotent.
#
#   tun2socks   xjasonlyu/tun2socks       (VPN tunnel interface vpn0)
#   sslocal     shadowsocks/shadowsocks-rust (Outline client)
#   ssserver    shadowsocks/shadowsocks-rust (only for tests/outline-test-server.sh)
#
# geph5-client has no prebuilt ARM64 release; it is built with cargo (README).
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

TUN2SOCKS_VER=v2.7.0
TUN2SOCKS_SHA=3931476c9cfa8fa236d23aeaf36767df0eb27cc11ecaab699faba57744450f49
SS_VER=v1.25.0
SS_SHA=9c3b7fd2df1b7fd12cd80bb3b57d9de98a0fb526921669c3ac40587b88be3009

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

fetch() {  # url sha256 file
    curl -fsSL -o "$3" "$1"
    echo "$2  $3" | sha256sum -c --quiet - || { echo "checksum mismatch for $1" >&2; exit 1; }
}

if [ "$(/usr/local/bin/tun2socks --version 2>/dev/null | head -1)" != "tun2socks-${TUN2SOCKS_VER#v}" ]; then
    fetch "https://github.com/xjasonlyu/tun2socks/releases/download/$TUN2SOCKS_VER/tun2socks-linux-arm64.zip" \
          "$TUN2SOCKS_SHA" t.zip
    unzip -q t.zip
    install -m 0755 tun2socks-linux-arm64 /usr/local/bin/tun2socks
    echo "installed tun2socks $TUN2SOCKS_VER"
fi

if [ "${MARINER_OUTLINE:-yes}" = no ]; then
    echo "skipping shadowsocks-rust (Outline disabled)"
elif [ "$(/usr/local/bin/sslocal --version 2>/dev/null)" != "shadowsocks ${SS_VER#v}" ]; then
    fetch "https://github.com/shadowsocks/shadowsocks-rust/releases/download/$SS_VER/shadowsocks-$SS_VER.aarch64-unknown-linux-gnu.tar.xz" \
          "$SS_SHA" ss.tar.xz
    tar -xJf ss.tar.xz sslocal ssserver
    install -m 0755 sslocal ssserver /usr/local/bin/
    echo "installed shadowsocks-rust $SS_VER (sslocal, ssserver)"
fi
