#!/usr/bin/env bash
# Mariner one-line installer.
#
#   curl -fsSL https://raw.githubusercontent.com/Jotspot/mariner/main/bootstrap.sh | sudo bash
#
# Turns a Raspberry Pi (Pi OS / Debian 12-13, 64-bit, NetworkManager) into a
# Mariner travel router. Interactive by default: it asks a few questions
# (anything given as an option isn't asked). --yes runs it unattended.
# Safe to run again: every step is idempotent. Run with --help for options.
set -euo pipefail

# Everything lives in main(), called on the last line: under `curl | bash`
# bash reads the script from stdin as it goes, so the whole file must be
# parsed before any command that could read stdin runs.
main() {

# --- defaults ---------------------------------------------------------------------
REPO=${MARINER_REPO:-https://github.com/Jotspot/mariner.git}
BRANCH=${MARINER_BRANCH:-main}
DIR=/opt/mariner
HOTSPOT_SSID=Mariner
HOTSPOT_PASSWORD=""
COUNTRY=""
HOSTNAME_NEW=mariner
GEPH=build                  # build | skip | binary
GEPH_BINARY=""
GEPH_VERSION=0.4.2          # tested with Mariner
OUTLINE=yes
EXPRESSVPN_INSTALLER=""
MINIMAL_FIRMWARE=yes
DISABLE_CLOUD_INIT=yes
UPGRADE=no
HOTSPOT=auto                # auto | yes | no
ASSUME_YES=no
DRY_RUN=no
WIZARD=auto                 # auto | no
# Which settings came from options (the wizard doesn't ask about those). The
# SSID is passed on only when chosen, so re-runs keep a name set in the portal.
SSID_SET=no PW_SET=no COUNTRY_SET=no HOSTNAME_SET=no GEPH_SET=no OUTLINE_SET=no
EVPN_SET=no FW_SET=no UPGRADE_SET=no

usage() {
    cat <<'EOF'
Mariner installer

Usage: bootstrap.sh [options]

With no options it asks step by step. Options answer a question in advance;
with --yes nothing is asked and defaults fill in the rest.

Hotspot and system
  --ssid NAME               Hotspot name (default: Mariner)
  --hotspot-password PW     Hotspot password, 8-63 chars (default: random, shown at the end)
  --country CC              Wi-Fi regulatory country, e.g. US, GB, SG (default: leave as is)
  --hostname NAME           Hostname, also NAME.local (default: mariner)
  --no-hotspot              Don't create the hotspot (e.g. no Wi-Fi, or set it up later)
  --keep-cloud-init         Don't disable cloud-init (it can reset hostname/network on boot)
  --standard-firmware       Keep the Pi's default Wi-Fi firmware (Mariner switches the
                            BCM43455 to Cypress' "minimal" build, more stable as a hotspot)
  --upgrade                 Run apt full-upgrade first

VPN providers
  --no-geph                 Don't install Geph
  --geph-binary PATH        Use an existing geph5-client binary instead of compiling
  --geph-version V          geph5-client version to compile (default: 0.4.2)
  --no-outline              Don't install the Outline (Shadowsocks) client
  --expressvpn-installer F  Also install ExpressVPN from its official Linux .run installer
                            (download it from your ExpressVPN account first)

Install source
  --repo URL                Git repository (default: the official one)
  --branch NAME             Branch or tag (default: main)

Other
  -y, --yes                 Unattended: no questions, no pauses
  --no-wizard               Don't ask questions, but still pause on warnings
  --dry-run                 Show what would be done, change nothing
  -h, --help                This help

Compiling Geph takes 30-60 minutes on a Pi 4 (no prebuilt ARM64 release exists).
EOF
}

LOG=/var/log/mariner-install.log

# --- look ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
    B=$'\033[1m' D=$'\033[2m' BLUE=$'\033[38;5;33m' CYAN=$'\033[38;5;44m' GREEN=$'\033[32m'
    YEL=$'\033[33m' RED=$'\033[31m' R=$'\033[0m' FANCY=yes
else
    B="" D="" BLUE="" CYAN="" GREEN="" YEL="" RED="" R="" FANCY=no
fi
case "${LC_ALL:-}${LC_CTYPE:-}${LANG:-}" in
    *UTF-8*|*utf8*|*UTF8*|*utf-8*)
        OK="${GREEN}✓${R}" BAD="${RED}✗${R}" Q="${CYAN}?${R}" DOT="·" TICK="✓ "
        SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) ;;
    *)  OK="${GREEN}ok${R}" BAD="${RED}!!${R}" Q="${CYAN}?${R}" DOT="-" TICK=""
        SPIN=('|' '/' '-' '\') ;;
esac

banner() {
    printf '%s' "$BLUE"
    cat <<'EOF'

     __  __            _
    |  \/  | __ _ _ __(_)_ __   ___ _ __
    | |\/| |/ _` | '__| | '_ \ / _ \ '__|
    | |  | | (_| | |  | | | | |  __/ |
    |_|  |_|\__,_|_|  |_|_| |_|\___|_|
EOF
    printf '%s\n    %scensorship-resilient travel router %s installer%s\n' "$R" "$D" "$DOT" "$R"
}
die() { printf '\n  %s %serror:%s %s\n\n' "$BAD" "$RED$B" "$R" "$*" >&2; exit 1; }
warn() { printf '  %s!%s %s\n' "$YEL$B" "$R" "$*" >&2; }
info() { printf '    %s%s%s\n' "$D" "$*" "$R"; }
need_arg() { [ $# -ge 2 ] && [ -n "$2" ] && [ "${2#--}" = "$2" ] || die "$1 needs a value"; }
section() { printf '\n  %s%s%s\n' "$B" "$*" "$R"; }
STEP=0 TOTAL=0
step() {
    STEP=$((STEP + 1))
    printf '\n  %s[%d/%d]%s %s%s%s\n' "$BLUE$B" "$STEP" "$TOTAL" "$R" "$B" "$*" "$R"
}
elapsed() {
    local s=$(( SECONDS - $1 ))
    if [ $s -ge 60 ]; then printf '%dm%02ds' $((s / 60)) $((s % 60)); else printf '%ds' "$s"; fi
}
run() {  # run a command, or just print it in --dry-run mode
    if [ "$DRY_RUN" = yes ]; then printf '    %swould run:%s %s\n' "$D" "$R" "$*"; else "$@"; fi
}
task() {  # task "Label" cmd...: output to the log, a spinner meanwhile, ✓ or ✗ after
    local label=$1; shift
    if [ "$DRY_RUN" = yes ]; then printf '    %s %swould run:%s %s\n' "$label" "$D" "$R" "$*"; return; fi
    echo "+ $*" >>"$LOG"
    local start=$SECONDS rc=0 i=0
    if [ "$FANCY" = yes ]; then
        "$@" >>"$LOG" 2>&1 </dev/null &
        local pid=$!
        while kill -0 "$pid" 2>/dev/null; do
            printf '\r    %s%s%s %s %s%s%s\033[K' "$CYAN" "${SPIN[i % ${#SPIN[@]}]}" "$R" "$label" "$D" "$(elapsed $start)" "$R"
            i=$((i + 1))
            sleep 0.2
        done
        wait "$pid" || rc=$?
        printf '\r\033[K'
    else
        "$@" >>"$LOG" 2>&1 </dev/null || rc=$?
    fi
    if [ $rc -eq 0 ]; then
        printf '    %s %s %s%s%s\n' "$OK" "$label" "$D" "$(elapsed $start)" "$R"
    else
        printf '    %s %s\n' "$BAD" "$label"
        tail -n 12 "$LOG" | sed "s/^/      $D/; s/\$/$R/"
        die "'$label' failed; the full log is in $LOG"
    fi
}
done_line() { printf '    %s %s\n' "$OK" "$*"; }
skip_line() { printf '    %s- %s%s\n' "$D" "$*" "$R"; }

TTY=no
if [ -r /dev/tty ] && { : </dev/tty; } 2>/dev/null; then TTY=yes; fi
ask() {  # ask VAR "Question" default [hint]
    local __a
    printf '    %s %s%s%s ' "$Q" "$2" "${4:+ $D$4$R}" "${3:+ $D[$3]$R}"
    IFS= read -r __a </dev/tty || __a=""
    printf -v "$1" '%s' "${__a:-$3}"
}
ask_secret() {  # ask_secret VAR "Question" hint
    local __a
    printf '    %s %s %s%s%s ' "$Q" "$2" "$D" "$3" "$R"
    IFS= read -rs __a </dev/tty || __a=""
    if [ -n "$__a" ]; then echo "$D(hidden)$R"; else echo; fi
    printf -v "$1" '%s' "$__a"
}
ask_yn() {  # ask_yn VAR "Question" yes|no [hint]
    local __a hint
    if [ "$3" = yes ]; then hint="Y/n"; else hint="y/N"; fi
    printf '    %s %s%s %s[%s]%s ' "$Q" "$2" "${4:+ $D$4$R}" "$D" "$hint" "$R"
    IFS= read -r __a </dev/tty || __a=""
    case "$__a" in
        [Yy]*) printf -v "$1" yes ;;
        [Nn]*) printf -v "$1" no ;;
        *) printf -v "$1" '%s' "$3" ;;
    esac
}
pause_or_yes() {
    [ "$ASSUME_YES" = yes ] || [ "$DRY_RUN" = yes ] && return 0
    if [ "$TTY" = yes ]; then
        local answer
        ask_yn answer "$1 Continue anyway?" no
        [ "$answer" = yes ] || die "stopped"
    else
        die "$1 Re-run with --yes to continue anyway."
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --ssid) need_arg "$@"; HOTSPOT_SSID=$2; SSID_SET=yes; shift ;;
        --hotspot-password) need_arg "$@"; HOTSPOT_PASSWORD=$2; PW_SET=yes; shift ;;
        --country) need_arg "$@"; COUNTRY=${2^^}; COUNTRY_SET=yes; shift ;;
        --hostname) need_arg "$@"; HOSTNAME_NEW=$2; HOSTNAME_SET=yes; shift ;;
        --no-hotspot) HOTSPOT=no ;;
        --keep-cloud-init) DISABLE_CLOUD_INIT=no ;;
        --standard-firmware) MINIMAL_FIRMWARE=no; FW_SET=yes ;;
        --upgrade) UPGRADE=yes; UPGRADE_SET=yes ;;
        --no-geph) GEPH=skip; GEPH_SET=yes ;;
        --geph-binary) need_arg "$@"; GEPH=binary; GEPH_BINARY=$2; GEPH_SET=yes; shift ;;
        --geph-version) need_arg "$@"; GEPH_VERSION=$2; shift ;;
        --no-outline) OUTLINE=no; OUTLINE_SET=yes ;;
        --expressvpn-installer) need_arg "$@"; EXPRESSVPN_INSTALLER=$2; EVPN_SET=yes; shift ;;
        --repo) need_arg "$@"; REPO=$2; shift ;;
        --branch) need_arg "$@"; BRANCH=$2; shift ;;
        -y|--yes) ASSUME_YES=yes ;;
        --no-wizard) WIZARD=no ;;
        --dry-run) DRY_RUN=yes ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
done

# --- validation -------------------------------------------------------------------
valid_ssid() { [ -n "$1" ] && [ "$(printf %s "$1" | wc -c)" -le 32 ]; }
valid_pw() { [ ${#1} -ge 8 ] && [ ${#1} -le 63 ]; }
valid_country() { [[ "$1" =~ ^[A-Z]{2}$ ]]; }
valid_hostname() { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; }
valid_ssid "$HOTSPOT_SSID" || die "--ssid must be 1-32 bytes"
[ -z "$HOTSPOT_PASSWORD" ] || valid_pw "$HOTSPOT_PASSWORD" || die "--hotspot-password must be 8-63 characters"
[ -z "$COUNTRY" ] || valid_country "$COUNTRY" || die "--country must be a two-letter code"
valid_hostname "$HOSTNAME_NEW" || die "--hostname must be a valid lowercase hostname"
[[ "$GEPH_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--geph-version must look like 0.4.2"
[ "$GEPH" != binary ] || [ -x "$GEPH_BINARY" ] || die "--geph-binary: $GEPH_BINARY is not an executable file"
[ -z "$EXPRESSVPN_INSTALLER" ] || [ -f "$EXPRESSVPN_INSTALLER" ] || die "--expressvpn-installer: $EXPRESSVPN_INSTALLER not found"
if [ "$WIZARD" = auto ]; then
    if [ "$ASSUME_YES" = no ] && [ "$DRY_RUN" = no ] && [ "$TTY" = yes ]; then WIZARD=yes; else WIZARD=no; fi
fi

banner

# --- preflight ----------------------------------------------------------------------
section "Checking this machine"
[ "$(id -u)" = 0 ] || [ "$DRY_RUN" = yes ] || die "run as root (… | sudo bash)"
ARCH=$(uname -m)
[ "$ARCH" = aarch64 ] || die "Mariner needs a 64-bit ARM system (found $ARCH). Use 64-bit Raspberry Pi OS."
. /etc/os-release
MODEL=$({ tr -d '\0' </proc/device-tree/model; } 2>/dev/null \
    || { v=$(systemd-detect-virt 2>/dev/null) && echo "virtual machine/container ($v)"; } || echo "unknown board")
done_line "$MODEL"
done_line "${PRETTY_NAME:-unknown OS}, $(awk '/MemTotal/ {printf "%.1f GB RAM", $2/1048576}' /proc/meminfo), $(df -h --output=avail / | tail -1 | tr -d ' ') free"
case "${ID:-}:${VERSION_CODENAME:-}" in
    debian:bookworm|debian:trixie|raspbian:bookworm|raspbian:trixie) ;;
    *) warn "untested OS: ${PRETTY_NAME:-unknown}. Mariner is tested on Debian 13 / Raspberry Pi OS (64-bit)."
       pause_or_yes "Untested OS." ;;
esac
command -v nmcli >/dev/null && systemctl is-active --quiet NetworkManager \
    || die "NetworkManager isn't running. Raspberry Pi OS Bookworm and later use it by default."
done_line "NetworkManager is running"

ap_and_client() {  # some interface combination allows a client (uplink) and an AP at once
    iw list 2>/dev/null | awk '/^[[:space:]]*\* #\{/ && /managed/ && /#\{[^}]*[ ,]AP[ ,}]/ {f = 1} END {exit !f}'
}
if [ "$HOTSPOT" = auto ]; then
    if [ -e /sys/class/net/wlan0 ] && command -v iw >/dev/null && ap_and_client; then
        HOTSPOT=yes
    elif [ -e /sys/class/net/wlan0 ] && ! command -v iw >/dev/null; then
        HOTSPOT=yes   # iw arrives with the packages below; checked again by install.sh
    else
        HOTSPOT=no
        warn "no Wi-Fi radio that can run a hotspot next to the uplink was found; skipping the hotspot"
    fi
    [ "$HOTSPOT" = no ] || done_line "Wi-Fi radio can run the uplink and a hotspot at once"
fi

if [ -n "${SSH_CONNECTION:-}" ]; then
    SSH_IF=$(ip route get "${SSH_CONNECTION%% *}" 2>/dev/null | grep -o 'dev [^ ]*' | cut -d' ' -f2 || true)
    if [ "$SSH_IF" = wlan0 ] && [ "$HOTSPOT" = yes ]; then
        warn "you're connected over Wi-Fi (wlan0). Creating the hotspot on the same radio can drop this SSH session for a moment; the install continues on the Pi regardless."
        pause_or_yes "Installing over Wi-Fi."
    fi
fi

HOTSPOT_EXISTS=no CUR_SSID=""
if nmcli -t -f NAME con show 2>/dev/null | grep -x mariner-hotspot >/dev/null; then
    HOTSPOT_EXISTS=yes
    CUR_SSID=$(nmcli -g 802-11-wireless.ssid con show mariner-hotspot 2>/dev/null || true)
    [ "$SSID_SET" = yes ] || HOTSPOT_SSID=${CUR_SSID:-$HOTSPOT_SSID}
fi
GEPH_HAVE=""
[ -x /usr/local/bin/geph5-client ] && GEPH_HAVE=$(cat /var/cache/mariner/geph5-client.version 2>/dev/null || echo "?")
FW=/usr/lib/firmware/cypress/cyfmac43455-sdio-minimal.bin
FW_AVAILABLE=no
[ -f "$FW" ] && FW_AVAILABLE=yes

# --- questions ----------------------------------------------------------------------------
if [ "$WIZARD" = yes ]; then
    printf '\n  %sA few questions.%s %sPress Enter to take the [default]; --yes skips all this.%s\n' "$B" "$R" "$D" "$R"
    QN=0 QT=4
    qhead() { QN=$((QN + 1)); printf '\n  %s%d/%d%s %s%s%s\n' "$CYAN$B" "$QN" "$QT" "$R" "$B" "$1" "$R"; }

    qhead "Hotspot"
    if [ "$HOTSPOT" = yes ]; then
        if [ "$SSID_SET" = no ]; then
            while :; do
                ask HOTSPOT_SSID "Network name" "$HOTSPOT_SSID"
                valid_ssid "$HOTSPOT_SSID" && break
                warn "1-32 characters, please"; HOTSPOT_SSID=${CUR_SSID:-Mariner}
            done
            [ "$HOTSPOT_SSID" = "$CUR_SSID" ] || SSID_SET=yes
        fi
        if [ "$PW_SET" = no ]; then
            while :; do
                if [ "$HOTSPOT_EXISTS" = yes ]; then
                    ask_secret HOTSPOT_PASSWORD "Password" "(Enter keeps the current one)"
                else
                    ask_secret HOTSPOT_PASSWORD "Password" "(8-63 characters; Enter makes one up)"
                fi
                [ -z "$HOTSPOT_PASSWORD" ] || valid_pw "$HOTSPOT_PASSWORD" && break
                warn "8-63 characters, please"
            done
        fi
    else
        skip_line "no suitable Wi-Fi radio (or --no-hotspot); skipping"
    fi
    if [ "$COUNTRY_SET" = no ]; then
        CUR_CC=$(iw reg get 2>/dev/null | awk '/^country/ {sub(":", "", $2); print $2; exit}' || true)
        [ "$CUR_CC" != 00 ] || CUR_CC=""
        while :; do
            ask COUNTRY "Wi-Fi country" "${CUR_CC:-skip}" "(two letters, e.g. US, GB, JP)"
            COUNTRY=${COUNTRY^^}
            [ "$COUNTRY" != SKIP ] && [ "$COUNTRY" != "$CUR_CC" ] || { COUNTRY=""; break; }
            valid_country "$COUNTRY" && break
            warn "two letters, like US or DE"
        done
    fi

    qhead "VPN providers"
    printf '    %sInstall any you might use; you pick one in the portal later.%s\n' "$D" "$R"
    if [ "$GEPH_SET" = no ]; then
        if [ "$GEPH_HAVE" = "$GEPH_VERSION" ]; then
            ask_yn ans "Keep Geph $GEPH_VERSION (already installed)?" yes
            [ "$ans" = yes ] || GEPH=skip
        else
            ask_yn ans "Geph: compile it now?" yes "(30-60 min on a Pi 4)"
            [ "$ans" = yes ] || GEPH=skip
        fi
    fi
    if [ "$OUTLINE_SET" = no ]; then
        ask_yn OUTLINE "Outline (Shadowsocks) client?" yes "(small download)"
    fi
    if [ "$EVPN_SET" = no ] && [ ! -x /opt/expressvpn/bin/expressvpnctl ]; then
        while :; do
            ask EXPRESSVPN_INSTALLER "ExpressVPN: path to its Linux .run installer" "skip"
            [ "$EXPRESSVPN_INSTALLER" != skip ] || { EXPRESSVPN_INSTALLER=""; break; }
            [ -f "$EXPRESSVPN_INSTALLER" ] && break
            warn "$EXPRESSVPN_INSTALLER not found (download it from your ExpressVPN account, or Enter to skip)"
        done
    fi

    qhead "This Raspberry Pi"
    if [ "$HOSTNAME_SET" = no ]; then
        while :; do
            ask HOSTNAME_NEW "Hostname" "$HOSTNAME_NEW" "(the portal is at http://NAME.local)"
            valid_hostname "$HOSTNAME_NEW" && break
            warn "lowercase letters, digits and dashes"; HOSTNAME_NEW=mariner
        done
    fi
    if [ "$FW_SET" = no ] && [ "$FW_AVAILABLE" = yes ]; then
        ask_yn MINIMAL_FIRMWARE "Switch Wi-Fi to the steadier minimal firmware?" yes "(recommended)"
    fi
    if [ "$UPGRADE_SET" = no ]; then
        ask_yn UPGRADE "Upgrade all system packages first?" no "(slower)"
    fi
fi

GEN_PASSWORD=no
if [ "$HOTSPOT" = yes ] && [ -z "$HOTSPOT_PASSWORD" ] && [ "$HOTSPOT_EXISTS" = no ]; then
    # Read a fixed amount (no SIGPIPE under pipefail): ~500 usable characters, keep 12.
    HOTSPOT_PASSWORD=$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'a-km-np-z2-9' | cut -c1-12)
    GEN_PASSWORD=yes
fi

# --- the plan -------------------------------------------------------------------------------
yesno() { if [ "$1" = yes ]; then printf '%s' "$OK"; else printf '%s-%s' "$D" "$R"; fi; }
row() { printf '    %s%-12s%s %s\n' "$D" "$1" "$R" "$2"; }
if [ "$WIZARD" = yes ]; then qhead "Review"; else section "Plan"; fi
if [ "$HOTSPOT" = yes ]; then
    pw="unchanged"
    [ "$GEN_PASSWORD" = no ] || pw="random, shown at the end"
    [ -z "$HOTSPOT_PASSWORD" ] || [ "$GEN_PASSWORD" = yes ] || pw="the one you chose"
    row Hotspot "$HOTSPOT_SSID $D(password: $pw)$R"
else
    row Hotspot "none"
fi
row "Wi-Fi" "country ${COUNTRY:-unchanged}, $([ "$MINIMAL_FIRMWARE" = yes ] && [ "$FW_AVAILABLE" = yes ] && echo "minimal firmware" || echo "standard firmware")"
case "$GEPH" in
    build) [ "$GEPH_HAVE" = "$GEPH_VERSION" ] && g="$(yesno yes) Geph $GEPH_VERSION (installed)" || g="$(yesno yes) Geph $GEPH_VERSION ${YEL}(compiles, 30-60 min)${R}" ;;
    binary) g="$(yesno yes) Geph from $GEPH_BINARY" ;;
    skip) g="$(yesno no) Geph" ;;
esac
row VPNs "$g"
row "" "$(yesno "$OUTLINE") Outline"
if [ -x /opt/expressvpn/bin/expressvpnctl ]; then evpn_row="$(yesno yes) ExpressVPN (installed)"
elif [ -n "$EXPRESSVPN_INSTALLER" ]; then evpn_row="$(yesno yes) ExpressVPN"
else evpn_row="$(yesno no) ExpressVPN"; fi
row "" "$evpn_row"
row System "hostname $HOSTNAME_NEW$([ "$UPGRADE" = yes ] && echo ", full upgrade")$([ "$DISABLE_CLOUD_INIT" = yes ] && [ -d /etc/cloud ] && echo ", cloud-init off")"
if [ "$WIZARD" = yes ]; then
    echo
    ask_yn go "Install now?" yes
    [ "$go" = yes ] || die "nothing was changed"
fi

TOTAL=6
[ -z "$EXPRESSVPN_INSTALLER" ] || TOTAL=7
START=$SECONDS
[ "$DRY_RUN" = yes ] || { : >>"$LOG"; echo "=== $(date -Is) bootstrap" >>"$LOG"; }

# --- packages -------------------------------------------------------------------------
step "Packages"
export DEBIAN_FRONTEND=noninteractive
task "Updating package lists" apt-get update
[ "$UPGRADE" = no ] || task "Upgrading the system" apt-get -y -o Dpkg::Options::=--force-confold full-upgrade
PKGS=(git rsync curl ca-certificates jq iw nftables avahi-daemon dnsutils python3 python3-venv
      iproute2 unzip xz-utils sudo)
[ "$HOTSPOT" = yes ] && PKGS+=(wpasupplicant dnsmasq-base)   # Pi OS has them; minimal Debian doesn't
[ "$GEPH" = build ] && PKGS+=(build-essential pkg-config libssl-dev)
task "Installing ${#PKGS[@]} packages" apt-get install -y --no-install-recommends "${PKGS[@]}"

# --- source ----------------------------------------------------------------------------
step "Mariner source"
if [ -d "$DIR/.git" ]; then
    task "Updating $DIR ($BRANCH)" git -C "$DIR" fetch -q origin "$BRANCH"
    run git -C "$DIR" checkout -q "$BRANCH"
    run git -C "$DIR" merge -q --ff-only "origin/$BRANCH" || warn "local changes in $DIR; using them as they are"
else
    task "Cloning into $DIR" git clone -q --branch "$BRANCH" "$REPO" "$DIR"
fi
[ "$DRY_RUN" = yes ] || info "$(git -C "$DIR" log -1 --format='%h %s' 2>/dev/null)"

# --- system ------------------------------------------------------------------------------
step "System settings"
if [ "$(hostname)" != "$HOSTNAME_NEW" ]; then
    run hostnamectl set-hostname "$HOSTNAME_NEW"
    run sed -i "s/^127\.0\.1\.1.*/127.0.1.1 $HOSTNAME_NEW/" /etc/hosts
fi
done_line "Hostname $HOSTNAME_NEW"
if [ "$DISABLE_CLOUD_INIT" = yes ] && [ -d /etc/cloud ] && [ ! -e /etc/cloud/cloud-init.disabled ]; then
    run touch /etc/cloud/cloud-init.disabled
    done_line "cloud-init disabled (it would reapply its first-boot hostname/network settings)"
fi
if [ -n "$COUNTRY" ]; then
    if command -v raspi-config >/dev/null; then
        if run raspi-config nonint do_wifi_country "$COUNTRY"; then done_line "Wi-Fi country $COUNTRY"
        else warn "couldn't set the Wi-Fi country"; fi
    else
        if run iw reg set "$COUNTRY" 2>/dev/null; then done_line "Wi-Fi country $COUNTRY"
        else warn "couldn't set the Wi-Fi country now (no Wi-Fi?); it applies after a reboot"; fi
        [ "$DRY_RUN" = yes ] || echo "options cfg80211 ieee80211_regdom=$COUNTRY" > /etc/modprobe.d/mariner-wifi-country.conf
    fi
fi
if [ "$MINIMAL_FIRMWARE" = yes ] && [ "$FW_AVAILABLE" = yes ] && [ "$(readlink -f /usr/lib/firmware/cypress/cyfmac43455-sdio.bin)" != "$FW" ]; then
    run update-alternatives --quiet --set cyfmac43455-sdio.bin "$FW"
    done_line "Minimal BCM43455 firmware (takes effect after a reboot)"
    NEED_REBOOT=yes
fi
if [ ! -f /etc/systemd/journald.conf.d/90-mariner.conf ]; then
    run install -d /etc/systemd/journald.conf.d
    [ "$DRY_RUN" = yes ] || printf '[Journal]\nStorage=persistent\nSystemMaxUse=100M\n' > /etc/systemd/journald.conf.d/90-mariner.conf
fi
done_line "Persistent system log (100 MB cap)"

# --- Geph ----------------------------------------------------------------------------------
step "Geph"
case "$GEPH" in
    build)
        MARKER=/var/cache/mariner/geph5-client.version   # geph5-client has no --version
        if [ "$GEPH_HAVE" = "$GEPH_VERSION" ]; then
            done_line "Geph $GEPH_VERSION already installed"
        else
            info "No prebuilt ARM64 release exists, so it compiles here: 30-60 minutes on a Pi 4."
            export CARGO_HOME=/var/cache/mariner/cargo RUSTUP_HOME=/var/cache/mariner/rustup
            run install -d /var/cache/mariner
            if [ ! -x "$CARGO_HOME/bin/cargo" ]; then
                task "Installing the Rust toolchain" sh -c "curl -sSf https://sh.rustup.rs | sh -s -- -y -q --profile minimal --no-modify-path"
            fi
            MEM_GB=$(awk '/MemTotal/ {print int($2/1048576)}' /proc/meminfo)
            JOBS=$(( MEM_GB >= 3 ? $(nproc) : 2 ))
            # Build on disk, not /tmp (often a small RAM disk).
            # --force: replace an older build or one installed with --geph-binary.
            task "Compiling geph5-client $GEPH_VERSION" env CARGO_BUILD_JOBS=$JOBS "$CARGO_HOME/bin/cargo" install --locked --force \
                --version "$GEPH_VERSION" --root /usr/local --target-dir /var/cache/mariner/geph-build geph5-client
            [ "$DRY_RUN" = yes ] || echo "$GEPH_VERSION" > "$MARKER"
        fi ;;
    binary)
        run install -m 0755 "$GEPH_BINARY" /usr/local/bin/geph5-client
        done_line "geph5-client installed from $GEPH_BINARY" ;;
    skip)
        skip_line "skipped" ;;
esac

# --- Mariner itself --------------------------------------------------------------------------
step "Mariner"
SSID_ENV=""
[ "$SSID_SET" = no ] || SSID_ENV=$HOTSPOT_SSID
task "Installing services, firewall, hotspot and web portal" env MARINER_HOTSPOT="$HOTSPOT" \
    MARINER_HOTSPOT_SSID="$SSID_ENV" MARINER_HOTSPOT_PASSWORD="$HOTSPOT_PASSWORD" \
    MARINER_OUTLINE="$OUTLINE" GEPH_SRC=/nonexistent "$DIR/install.sh"

# --- ExpressVPN (optional) ------------------------------------------------------------------
if [ -n "$EXPRESSVPN_INSTALLER" ]; then
    step "ExpressVPN"
    # Mariner's drop-in (installed above) confines the daemon to its sandbox
    # before the installer starts it. The installer refuses to run under sudo.
    task "Running ExpressVPN's installer (headless)" env -u SUDO_USER -u SUDO_UID -u SUDO_GID -u SUDO_COMMAND \
        sh "$EXPRESSVPN_INSTALLER" -- --no-gui
    run systemctl disable --quiet expressvpn-service.service
    run systemctl stop expressvpn-service.service
    task "Sandboxing it" "$DIR/install.sh"
fi

# --- done ----------------------------------------------------------------------------------------
if [ "$DRY_RUN" = yes ]; then
    printf '\n  %sDry run: nothing was changed.%s\n\n' "$B" "$R"
    exit 0
fi
printf '\n  %s%sMariner is installed%s %sin %s%s\n\n' "$GREEN$B" "$TICK" "$R" "$D" "$(elapsed $START)" "$R"
if [ "$HOTSPOT" = yes ]; then
    row "Hotspot" "$B$HOTSPOT_SSID$R"
    if [ "$GEN_PASSWORD" = yes ]; then
        row "Password" "$B$HOTSPOT_PASSWORD$R $D(change it in the portal under Hotspot)$R"
    elif [ -n "$HOTSPOT_PASSWORD" ]; then
        row "Password" "the one you chose"
    else
        row "Password" "unchanged"
    fi
    row "Portal" "join the hotspot, then open ${CYAN}http://$HOSTNAME_NEW.local$R $D(or http://10.42.0.1)$R"
else
    row "Hotspot" "not set up (--no-hotspot or no suitable Wi-Fi radio)"
fi
vpns=$( { [ -x /usr/local/bin/geph5-client ] && printf 'Geph  '; [ -x /usr/local/bin/sslocal ] && printf 'Outline  '; [ -x /opt/expressvpn/bin/expressvpnctl ] && printf 'ExpressVPN'; } || true)
row "VPNs" "${vpns:-none}"
row "Log" "$LOG"
echo
printf '    %sNext:%s join the hotspot, open the portal, choose its password, connect\n' "$B" "$R"
printf '    Mariner to the local Wi-Fi, then turn on a VPN.\n'
[ "${NEED_REBOOT:-no}" = no ] || printf '\n    %sReboot once%s to load the new Wi-Fi firmware: %ssudo reboot%s\n' "$YEL$B" "$R" "$B" "$R"
echo
}

main "$@"
