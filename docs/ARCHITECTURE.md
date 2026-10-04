# Mariner: architecture and engineering notes

The detailed design behind Mariner: how each subsystem works, why it's built that way, and what was measured on real hardware. For an overview and installation, see the [README](../README.md).

A Raspberry Pi 4 travel router: joins hotel or café Wi-Fi, broadcasts its own
hotspot, detects captive portals, and (optionally) sends hotspot traffic
through [Geph](https://geph.io) with a kill switch. Everything is managed from
a phone at `http://mariner.local`.

## Hardware and OS

- Raspberry Pi 4 Model B, Debian 13 (trixie), Raspberry Pi kernel, arm64.
- Onboard Wi-Fi only (Broadcom brcmfmac). It supports one managed and one AP
  interface at the same time, on a **single shared channel**.
- Networking is NetworkManager. Connection profiles are stored by NM's netplan
  backend in `/etc/netplan/90-NM-*.yaml`. Always change them with `nmcli`.
- cloud-init (NoCloud seed in `/boot/firmware`) did the first-boot setup and
  is now **disabled** by `/etc/cloud/cloud-init.disabled`, so it can't
  reapply its cached hostname, `/etc/hosts` or network config on boot. Delete
  that file to re-enable it. As a belt-and-braces measure,
  `/etc/cloud/cloud.cfg.d/99-mariner.cfg` and `/boot/firmware/user-data` also
  say `hostname: mariner` and `manage_etc_hosts: false` (the original seed is
  `user-data.orig-mariner`).

## Layout

| Path | What |
|---|---|
| `/opt/mariner` | This git repo (working copy, owned by the login user). |
| `/usr/local/lib/mariner` | Installed, root-owned copy. Created by `install.sh`. |
| `/usr/local/sbin/*` | Symlinks to the installed tools. |
| `/etc/mariner/` | Secrets and local config. Never in git. Directory `root:mariner 0750`; `geph.json`/`geph.yaml` root `0600`; `portal.json` (portal password hash, cookie key) `root:mariner 0640`. |
| `/run/mariner/` | Live state: `portal.json`, `hotspot.json`, `geph.json`, `public-ip.json`. |
| `/usr/local/bin/geph5-client`, `tun2socks` | Third-party binaries (see Geph below). |
| `/var/lib/mariner/` | State and network snapshots. |

Deploy changes: edit, commit, then `sudo /opt/mariner/install.sh`.

## Uplink and hotspot (phase 2)

```
 hotel Wi-Fi ))) wlan0 [Pi 4 onboard radio] uap0 ((( your phone/laptop
                 client                     AP "Mariner", 10.42.0.1/24
```

- **wlan0** joins upstream networks with ordinary NM Wi-Fi profiles. Profiles
  Mariner creates are pinned to `wlan0`. The old netplan-generated home
  profile can't hold an interface name, which is why the hotspot gets
  `autoconnect-priority 100`: NM always picks it for `uap0`.
- **uap0** is a second (virtual) interface on the same radio, created by the
  udev rule `90-mariner-uap0.rules` as soon as `wlan0` appears. NM profile
  `mariner-hotspot` runs on it: AP mode, WPA2-PSK (CCMP), `ipv4.method shared`,
  so NM runs dnsmasq (DHCP + DNS) and adds NAT in the nft table
  `nm-shared-uap0`.
- **One channel.** The Broadcom firmware allows one managed and one AP
  interface on a single shared channel. Tested on this Pi:
  - When `wlan0` changes channel or band (roaming, a new network), the
    firmware moves the running AP along with it.
  - Starting the AP on a band that doesn't match the uplink can fail.
  - `mariner-hotspot-sync` (NM dispatcher on `wlan0 up`, plus
    `mariner-hotspot-sync.timer` every 30 s) restarts the hotspot only if it
    is down or on the wrong band. Otherwise it quietly records the current
    band and channel in the profile so the next start matches. Its status is
    in `/run/mariner/hotspot.json`.
  - **DFS channels (5 GHz, 52–144) can't host the hotspot.** The status
    becomes `dfs`. Fix it by forcing the uplink to 2.4 GHz
    (`nmcli con modify <uplink> 802-11-wireless.band bg`).
  - Clients see a short drop whenever the hotspot changes channel.
- **Names.** Avahi advertises `mariner.local` only on `uap0` and `eth0`
  (`allow-interfaces` in `/etc/avahi/avahi-daemon.conf`; original saved as
  `.orig-mariner`). The hotspot's dnsmasq also answers `mariner` and
  `mariner.local` with 10.42.0.1 (`/etc/NetworkManager/dnsmasq-shared.d/`).
- While ethernet is plugged in, the Pi's default route (and hotspot client
  traffic) goes out `eth0` (metric 100) rather than `wlan0` (600).

## Stability notes

- **Wi-Fi firmware.** The onboard BCM43455 runs on Cypress's *minimal*
  firmware (`update-alternatives --set cyfmac43455-sdio.bin
  /usr/lib/firmware/cypress/cyfmac43455-sdio-minimal.bin`). The default
  "standard" build crashed under VPN load with AP and client running at once
  (`brcmf_fw_crashed`). The driver recovers by itself in about 15 s. Crashes
  are counted on the dashboard and System page. Undo with
  `update-alternatives --auto cyfmac43455-sdio.bin`.
- **Power save off** on all Wi-Fi (`nm/conf.d/90-mariner-wifi.conf`); in AP
  mode it made clients drop right after joining.
- **Persistent journal** (`/etc/systemd/journald.conf.d/90-mariner.conf`, 100 MB
  cap), so crashes are visible after a reboot.
- **Mesh / multi-AP networks.** Each roam to an access point on another
  channel moves the hotspot and drops clients for a few seconds. "Stay on
  this access point" (Wi-Fi page) sets `802-11-wireless.bssid`, which also
  stops NM's background roaming scans. A locked profile only connects to that
  access point; unlock it when you move.
- If the radio still isn't stable enough, the robust fix is a USB Wi-Fi
  adapter that supports AP mode for the hotspot, so each radio has one job.

## ExpressVPN (third VPN provider)

The official ExpressVPN Linux app (14.3.1, ARM64; install it once by hand
with its `.run` installer and `--no-gui`, run as the login user, not with sudo)
runs **sandboxed**, so it can't touch the Pi's own routing, DNS or firewall:

```
phone --uap0--> [table 100: default via 10.200.0.2 dev evh]
            evh (10.200.0.1) ==veth== evn (10.200.0.2) [netns evpn]
                                     expressvpn-daemon -> wgexpressvpn0 -> ExpressVPN
phone DNS :53 --dnat--> 10.200.0.2:5354 mariner-evpn-dns -> ExpressVPN's DNS (via tunnel)
```

- `bin/mariner-evpn-netns` (+ `mariner-evpn-netns.service`) builds the
  namespace and its guard table `inet mariner_guard`: forwarded hotspot
  traffic may leave only through `wgexpressvpn*`/`tun*`, and the DNS
  forwarder (user `mariner`) may only send through the tunnel (except its
  answers back to the host). Disconnected VPN = blocked, never leaked.
- Drop-in `expressvpn-service.service.d/mariner.conf` puts the daemon in the
  namespace (`NetworkNamespacePath`) with the namespace's resolv.conf. It
  requires the namespace service, so if that fails the daemon doesn't start
  rather than running on the host. `install.sh` disables the installer's
  autostart; `mariner-vpn-expressvpn.target` starts it on demand.
- Host side (`inet mariner`): the kill switch allows only `evh`; "evpn guard"
  lets nothing but the sandbox's own VPN connection (10.200.0.2) out of the
  sandbox towards the uplink; the sandbox's traffic is masqueraded.
- Sign-in from the VPN page: the activation code goes to `mariner-ctl
  evpn-login` on stdin, into a root-only temp file for `expressvpnctl login`,
  then is shredded. Mariner sets: background mode, autoconnect, Network Lock
  off (Mariner's kill switch covers the hotspot; ExpressVPN's would block
  forwarding), allow-LAN on (the DNS forwarder's answers rely on it),
  protocol, location.
- Status comes from one `expressvpnctl status` call (cached 2 s). Reconcile
  reconnects if the daemon is disconnected or claims "Connected" without a
  tunnel interface.
- Locations: 216 slugs like `usa-new-york-2`, mapped to countries and flags in
  `web/countries.py`.

Benchmarks on this Pi (2026-10-03, Singapore exit; Ethernet = CPU ceiling,
Wi-Fi = what travel looks like):

| Protocol | Ethernet (Mbit/s) | Wi-Fi uplink (Mbit/s) | Notes |
|---|---|---|---|
| none (direct) | 148 | 71–96 | |
| WireGuard (default) | 132 | 79–81 | ~40% CPU |
| OpenVPN UDP | 60–73 | 88–93 | ~19–40% CPU |
| OpenVPN TCP | 68–81 | – | |
| Lightway UDP/TCP | 1–2 | – | `expressvpn-lightway` pins one core at 100% |

Lightway is unusable on this Pi (`use_pqc: true` is the prime suspect; no CLI
switch for it). RAM: ~70 MB idle, ~230 MB connected. Connect ~16 s, clean
disconnect ~12 s; a `connect` issued mid-disconnect is ignored.

Caveat: ExpressVPN's control socket (`/opt/expressvpn/var/daemon.sock`) is
mode 0777 by design, so any local process on the Pi can control the app.
Only Mariner's own services run there.

## Captive portal detection (phase 3)

`mariner-check` (Python, stdlib only, runs as root) decides whether the
uplink is `online`, behind a `portal`, or `offline`, and writes the answer to
`/run/mariner/portal.json` (`state`, `portal_url`, `ssid`, `dns`, per-probe
details). State changes are logged with tag `mariner-check`.

- It asks the **upstream network's own DNS server** (from DHCP, via
  `nmcli -g IP4.DNS dev show wlan0`) for the probe hostnames using its own
  minimal DNS client, then fetches each URL with a hand-written HTTP GET (no
  redirects followed).
- **Every socket is bound to `wlan0`** (`SO_BINDTODEVICE`), so checks never
  use ethernet, the Geph tunnel or encrypted DNS, whatever the routing table
  says.
- Probes, from three companies:
  - `http://captive.apple.com/hotspot-detect.html`: expects 200 + "Success".
  - `http://connectivitycheck.gstatic.com/generate_204`: expects 204.
  - `http://www.msftconnecttest.com/connecttest.txt`: expects 200 +
    "Microsoft Connect Test".
- Verdict: any probe redirected or answered with other content means
  `portal`. Otherwise any expected answer means `online`. Otherwise
  (no uplink, no DNS, nothing answers) it's `offline`.
- `portal_url` is the redirect `Location`, else a `<meta refresh>` or
  `window.location` target in the page, else the probe URL itself (opening it
  from a hotspot device shows the portal).
- When it runs: `mariner-check.timer` every 60 s, plus NM dispatcher hook
  `91-mariner-check` 3 s after `wlan0` up/down/DHCP changes or any NM
  connectivity change. Runs are serialized with a lock.
- NM's own connectivity verdict is recorded as `nm_connectivity` for
  reference only.

## VPN: Geph or Outline (phase 4)

```
phone --uap0--> [ip rule: from 10.42.0.0/24 iif uap0 -> table 100]
                    table 100: default dev vpn0 | unreachable default (metric 9999)
                vpn0 (tun2socks) --> SOCKS5 127.0.0.1:9909 --> geph5-client | sslocal --> wlan0 --> exit
phone DNS :53 --nft dnat--> mariner-dns 10.42.0.1:5354 --DoH via SOCKS--> 1.1.1.1 / 8.8.8.8
```

- **Providers.** One at a time, chosen on the VPN page. Both expose SOCKS5 on
  `127.0.0.1:9909`, so the tunnel, DNS, kill switch and portal handling are
  shared.
  - **Geph:** `geph5-client`. Status from its control API (`127.0.0.1:12222`):
    exit country/city, protocol, links, server load, traffic, account level.
  - **Outline:** shadowsocks-rust `sslocal` (`outline-ss.service`). Takes
    `ss://` keys (SIP002, plain or legacy base64) and `ssconf://` dynamic keys
    (fetched over HTTPS, refreshed hourly). Keys with Outline's `prefix=`
    option or Shadowsocks plugins are rejected with an explanation. UDP is
    relayed (`tcp_and_udp`). sslocal has no status API, so "connected" means
    the exit lookup through the tunnel succeeded.
- **Exit location.** `mariner-ctl vpn-probe` (run after each `mariner-check`:
  every 30 s until confirmed, then every 5 min) fetches the IPv4 exit address
  through the tunnel and looks it up (ipinfo.io, ipapi.co, ifconfig.co). For
  Geph the country/city come from Geph itself, since IP databases often
  misplace VPN exits. Flags are emoji rendered with a bundled Twemoji
  country-flag font (`web/static/TwemojiCountryFlags.woff2`, from
  talkjs/country-flag-emoji-polyfill, MIT; artwork Twemoji, CC-BY 4.0).
- **Binaries.** `geph5-client` 0.4.2 has no prebuilt ARM64 release, so it is
  built from crates.io: `cargo install --locked --target-dir ~/.cache/geph-build geph5-client`
  as the login user (Rust via rustup; about 40 min on the Pi 4; `/tmp` is a 900 MB
  RAM disk, too small for the build). `install.sh` copies
  `~/.cargo/bin/geph5-client` to `/usr/local/bin`. `tun2socks` v2.7.0 is the
  `linux-arm64` release from xjasonlyu/tun2socks; `sslocal` is
  shadowsocks-rust v1.25.0. Both are installed by `tools/fetch-binaries.sh`
  with pinned versions and SHA-256 checks.
- **Config.** `/etc/mariner/vpn.json` (root 0600) holds the settings:
  `enabled`, `provider`, `killswitch`, `geph.exit`, `geph.credentials`,
  `outline` (key + parsed server). It replaced `geph.json`, which is migrated
  automatically. `mariner-ctl` generates `outline.json` (sslocal) and `geph.yaml`:
  SOCKS5 on `127.0.0.1:9909`, control API on `127.0.0.1:12222`, the broker
  list and keys from the official app's `binaries/geph5-app/default-config.yaml`
  (including `mizaru_bw`, which Plus accounts need for bandwidth tokens), `allow_lan: false` (strict
  full tunnel). Credentials are either `secret` (newer accounts) or
  `legacy_username_password`.
- **Units.** `mariner-vpn-geph.target` (`geph5.service`, logging at info
  level) or `mariner-vpn-outline.target` (`outline-ss.service`), each with
  `mariner-tun.service` and `mariner-dns.service`. The provider services are
  DynamicUser and get their root-only config through `LoadCredential`.
  `mariner-tun.service` runs tun2socks, creating `vpn0`; `mariner-tun-up` adds 198.18.0.1/30 for NM's
  masquerade and the table-100 default route) and `mariner-dns.service`. The
  target is never enabled; `mariner-ctl reconcile` starts and stops it.
- **Routing.** Only traffic arriving from the hotspot is policy-routed into
  table 100. The Pi's own traffic, including Geph's connection to its
  servers and the captive-portal checks, stays on the main table. Table 100
  ends in `unreachable`, so if `vpn0` vanishes nothing falls back to `wlan0`.
- **Kill switch** (`table inet mariner`, chain `forward`): while Geph is
  enabled with the kill switch on, `iifname uap0 oifname != {uap0, vpn0}
  drop`. It doesn't depend on geph5-client being alive.
- **DNS.** Geph's SOCKS server supports UDP ASSOCIATE, but hotspot DNS doesn't
  rely on it. While traffic goes through Geph, nft redirects every port-53
  query from the hotspot to `mariner-dns`, which answers the router's own
  names (hostname, hostname.local) itself and sends everything else as
  DNS-over-HTTPS through the SOCKS port (Cloudflare, falling back to Google),
  with a TTL cache keyed on (name, type, class, DO bit). `mariner-dns` always
  runs: while the kill switch blocks and no tunnel is up (VPN starting, or
  paused for a captive portal) hotspot DNS still goes to it, and it keeps
  answering the router's name and REFUSEs everything else at once (the SOCKS
  port is closed). Hotspot DNS never reaches the hotel's resolver while the
  kill switch is on. When the VPN is off, dnsmasq uses the network's DNS as
  usual.
- **State machine** (`mariner-ctl reconcile`; runs at boot via
  `mariner-reconcile.service`, after every `mariner-check`, after every
  setting change, and from `mariner-tun.service` ExecStopPost):

  | Situation | geph5 | Hotspot routing | Kill switch | Hotspot DNS |
  |---|---|---|---|---|
  | Geph off | stopped | direct | – | network's |
  | On, uplink online/offline | running | table 100 | blocks direct | DoH via Geph |
  | On, captive portal detected | **stopped** | table 100 (unreachable) | blocks direct | router's name only; rest REFUSED |
  | Login window open | as above | that device: direct (ip rule 900+) | that device exempt | that device: network's |
  | On, kill switch off, tunnel down | – | direct | – | network's |

  The login window (`/run/mariner/portal-login.json`: until, device IPs, the
  state it was opened in) lets **only the device that asked** load the hotel's
  login page: an `ip rule` at priority 900+ sends that one address to the main
  table, an `ip saddr … accept` comes before the kill-switch drop, and its DNS
  skips the DNAT. Everyone else stays blocked. It works in any detected state
  (a portal can let the probe hosts through), and closes when it expires, when
  a detected portal turns "online", or when the VPN tunnel comes up. While it
  is open, a `mariner-login-watch` unit runs `mariner-check` every 10 s.

## Web portal (phase 5)

- `http://mariner.local` / `http://mariner` / `http://10.42.0.1`, hotspot
  only: uvicorn binds `10.42.0.1:80` and nft drops port 80 on every other
  interface.
- FastAPI and Jinja templates, plain HTML forms, a hand-written Material 3 style
  sheet (`web/static/m3.css`, light and dark), inline Material Icons. No CDN:
  it works with no internet. CSP allows only same-origin resources.
- Fast and live: the app keeps a background cache of `mariner-ctl` results
  (refreshed only while someone has the portal open; every second for 30 s
  after an action), so pages render in ~10 ms. Slow actions (VPN on/off,
  reconnects, IP checks) run in the background and report failures as a
  one-time notice. `app.js` swaps pages in place, refreshes elements marked
  `data-live`, submits forms with fetch (switches flip immediately) and shows
  toasts. Everything still works without JavaScript.
- Runs as system user `mariner` with `CAP_NET_BIND_SERVICE`, from a venv in
  `/usr/local/lib/mariner/venv`. The only sudo rule is
  `/etc/sudoers.d/mariner-web`: `mariner ALL=(root) NOPASSWD:
  /usr/local/lib/mariner/bin/mariner-ctl`. `mariner-ctl` validates every
  argument; secrets go to it on stdin as JSON and are never echoed back.
- Auth: first visit asks you to set the password (scrypt hash in
  `/etc/mariner/portal.json`). Sessions are HMAC-signed cookies (7 days,
  HttpOnly, SameSite=Strict) with a CSRF token checked on every POST. Posts
  with a foreign Origin are refused. Five wrong passwords lock that address
  out for 60 s. Changing the password rotates the cookie key, which signs
  everyone else out.
- Devices (Hotspot page): `mariner-ctl devices` merges dnsmasq leases
  (name, IP), `iw station dump` (connected, connected time, bytes) and the
  `uap0` neighbour table (static IPs). Names are whatever the device sends in
  DHCP. Most phones and laptops use private (randomized) MAC addresses.
- Forgot the password? Over SSH: `sudo rm /etc/mariner/portal.json`, then
  open the portal to set a new one.

## Security notes

- SSH is dropped on the uplink (`wlan0`, IPv4 and IPv6); it works from the
  hotspot and ethernet. Password login is still enabled for those.
- `mariner-firewall-early.service` runs before NetworkManager at boot and
  applies the kill switch if the VPN was on, so there's no window before the
  normal reconcile. Reconcile itself also blocks first and only then handles
  services.
- The portal treats only a missing `portal.json` as "first run"; any other
  read problem returns an error instead of reopening setup.

## Tests

Run on the Pi, as root:

- `tests/hotspot-client.sh up|run CMD|down`: a fake phone (netns
  `mclient`, 10.42.0.9) on a veth that mariner-ctl treats like `uap0`.
- `tests/fake-portal.sh on [redirect|meta]|off`: makes the uplink look like
  a captive portal to `mariner-check`.
- `tests/outline-selftest.sh`: Outline key parsing, config generation and
  sslocal (TCP and UDP) against a throwaway local Shadowsocks server, without
  touching the live VPN.

## Tools

| Tool | Purpose |
|---|---|
| `mariner-snapshot` | Save NM profiles, netplan, nftables and `ip rule` state. |
| `mariner-restore SNAP` | Put a snapshot back and restart NetworkManager. |
| `mariner-ctl` | Privileged control tool used by the portal (`status`, `reconcile`, `vpn-*`, `evpn-*`, `wifi-*`, `hotspot-*`, `devices`, `logs`, `reboot`, `poweroff`, ...). JSON in/out. |
| `mariner-dns` | Hotspot DNS: DoH through the SOCKS port (Geph, Outline) or plain DNS to ExpressVPN's server inside its sandbox. |
| `mariner-evpn-netns` | Create/remove the ExpressVPN sandbox and its guard table. |
| `mariner-check` | Captive portal / connectivity check (prints JSON). |
| `mariner-hotspot-sync` | Keep the hotspot up and on the uplink's band. |
| `arm-rollback [min]` | Snapshot, then schedule an automatic restore (default 3 min). `arm-rollback cancel` once the change is verified. |

### Safe change procedure

```
sudo arm-rollback          # snapshot + restore in 3 minutes
# ... apply network/firewall change ...
# reconnect in a NEW ssh session and verify
sudo arm-rollback cancel
```

## Status by phase

1. Survey and base setup: done.
2. Uplink and hotspot: done, phone-tested.
3. Captive portal detection: done. Tested offline against 108 simulated
   networks (`tests/portal-sim`), and end to end on real Wi-Fi software:
   `tests/containers/e2e-portal.sh` runs a hotel access point (hostapd on a
   simulated radio, dnsmasq, a click-through portal redirecting port 80 until
   "Accept") and a Mariner joining it with the VPN and kill switch on. Result
   (2026-10-04): portal detected from the redirect within one check, VPN
   paused, a hotspot device blocked; after "Allow this device" that device
   alone reached the portal and logged in; Mariner saw the network online
   about 40 s later, closed the window and resumed the VPN. Not yet tried
   against a commercial portal (openNDS, hotel systems) on real hardware.
4. VPN: Geph, Outline and ExpressVPN, all tested with real accounts (ExpressVPN: leak, DNS and kill switch tests on 2026-10-03).
5. Web portal: done (phone and desktop layouts). Password is set on first visit.
