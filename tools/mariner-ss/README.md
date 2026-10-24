# mariner-ss

A local SOCKS5 server (CONNECT and UDP ASSOCIATE) that relays through an
Outline/Shadowsocks server with the [Outline SDK](https://golang.getoutline.org/sdk),
including Outline's **prefix** disguise, which shadowsocks-rust's `sslocal`
can't send. `bin/outline-client` runs it instead of `sslocal` when the Outline
key has a prefix; it reads the same JSON config Mariner generates for `sslocal`
(plus a base64 `prefix`).

Installs get it from this repository's GitHub releases (`mariner-ss-v<version>`):
`tools/fetch-binaries.sh` downloads `mariner-ss-linux-arm64` and checks it
against the pinned SHA-256, like the other third-party binaries.

The build is reproducible. To build it yourself (on a PC with Go; the Pi's
`/tmp` is too small for Go builds), or to check the published binary:

    cd tools/mariner-ss
    GOTOOLCHAIN=auto CGO_ENABLED=0 GOOS=linux GOARCH=arm64       go build -trimpath -ldflags="-s -w -buildid= -X main.version=0.1.0" -o mariner-ss-linux-arm64 .
    sha256sum mariner-ss-linux-arm64   # = MSS_SHA in tools/fetch-binaries.sh

A `mariner-ss-linux-arm64` left in this directory takes precedence: `install.sh`
installs it instead of the release (for development; it isn't committed).

To release a new version: bump the version in the build command, build, publish
the binary as the release asset `mariner-ss-linux-arm64` under the tag
`mariner-ss-v<version>`, and update `MSS_VER`/`MSS_SHA` in `tools/fetch-binaries.sh`.
