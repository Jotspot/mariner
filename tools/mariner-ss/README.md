# mariner-ss

A local SOCKS5 server (CONNECT and UDP ASSOCIATE) that relays through an
Outline/Shadowsocks server with the [Outline SDK](https://golang.getoutline.org/sdk),
including Outline's **prefix** disguise, which shadowsocks-rust's `sslocal`
can't send. `bin/outline-client` runs it instead of `sslocal` when the Outline
key has a prefix; it reads the same JSON config Mariner generates for `sslocal`
(plus a base64 `prefix`).

Build on a PC with Go (the Pi's `/tmp` is too small for Go builds) and deploy:

    cd tools/mariner-ss
    GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o mariner-ss-linux-arm64 .

`install.sh` installs `mariner-ss-linux-arm64` as `/usr/local/bin/mariner-ss`
when it's present (the binary itself isn't committed).
