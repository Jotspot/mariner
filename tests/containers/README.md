# Container tests (installer, captive portal end to end)

Run on a Pi (or any arm64 Debian box with NetworkManager), as root. Nothing
touches the host's own networking: each test runs in a throwaway
`systemd-nspawn` container with its own simulated Wi-Fi radio
(`mac80211_hwsim`; the host's NetworkManager is told to leave those alone).

One-time base image (about 5 minutes):

```bash
sudo apt-get install -y debootstrap systemd-container
sudo debootstrap --include=systemd,systemd-sysv,dbus,network-manager,sudo,ca-certificates,curl,git,iproute2,locales,iw     trixie /var/lib/machines/mariner-test-base http://deb.debian.org/debian
```

The containers install from this checkout (bind-mounted read-only from
`/opt/mariner`).

- `installer-tests.sh`: fresh `--yes` install; an idempotent re-run (nothing may
  change); the rollback scripts without netplan; `--add-expressvpn` later (only
  ExpressVPN may change); a fresh install with ExpressVPN; its re-run. The
  ExpressVPN tests need `EVPN_RUN=/path/to/expressvpn-linux-universal-*.run`.
- `e2e-portal.sh`: a "hotel" container runs hostapd, dnsmasq and a click-through
  captive portal (nftables redirect to a login page, an allow set filled on
  "Accept"); a Mariner container joins it over simulated Wi-Fi with the VPN on
  and the kill switch on, detects the portal, lets one fake hotspot device log in
  through the per-device login window, and notices the network coming online.
- `ct.sh up|down|run NAME ...`: the container helper both use.

Clean up afterwards: `rmmod mac80211_hwsim`, remove
`/etc/NetworkManager/conf.d/99-mtest-hwsim.conf` and run `nmcli general reload conf`.
