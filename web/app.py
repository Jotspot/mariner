"""Mariner web portal.

Runs as the unprivileged user `mariner`, bound to the hotspot address only.
Every privileged action goes through `sudo mariner-ctl ...` (the only sudo
rule this user has); secrets are passed to it on stdin.

Auth: one admin password (scrypt hash in /etc/mariner/portal.json, readable
by group mariner). Sessions are HMAC-signed cookies (SameSite=Strict,
HttpOnly) carrying a CSRF token that every POST form must echo back.
"""
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import subprocess
import threading
import time
from pathlib import Path
from urllib.parse import parse_qs, quote, urlsplit

from fastapi import Depends, FastAPI, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

import countries

CTL = "/usr/local/lib/mariner/bin/mariner-ctl"
PORTAL_JSON = "/etc/mariner/portal.json"
COOKIE = "mariner_session"
SESSION_SECS = 7 * 24 * 3600
HERE = Path(__file__).parent

async def csrf_check(request: Request):
    """Every POST from a signed-in session must carry the session's CSRF token."""
    sess = getattr(request.state, "session", None)
    if request.method == "POST" and sess is not None:
        form = await request.form()
        if not hmac.compare_digest(str(form.get("csrf", "")), sess["csrf"]):
            raise HTTPException(403, "Form expired. Go back and reload the page.")


app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None, dependencies=[Depends(csrf_check)])
app.mount("/static", StaticFiles(directory=HERE / "static"), name="static")
templates = Jinja2Templates(directory=HERE / "templates")


def _bytes(n):
    try:
        n = float(n)
    except (TypeError, ValueError):
        return "–"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1000 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1000


def _since(ts):
    try:
        secs = int(time.time() - int(ts))
    except (TypeError, ValueError):
        return ""
    if secs < 60:
        return "just now"
    if secs < 3600:
        return f"{secs // 60} min"
    if secs < 86400:
        return f"{secs // 3600} h {secs % 3600 // 60} min"
    return f"{secs // 86400} d {secs % 86400 // 3600} h"


def _date(ts):
    try:
        return time.strftime("%-d %b %Y", time.localtime(int(ts)))
    except (TypeError, ValueError):
        return ""


def _duration(secs):
    try:
        return _since(time.time() - int(secs))
    except (TypeError, ValueError):
        return ""


def _org(text):
    """'AS206092 F.N.S. HOLDINGS LIMITED' -> 'F.N.S. Holdings Limited'."""
    if not text:
        return ""
    text = re.sub(r"^AS\d+\s+", "", str(text))
    return text.title() if text.isupper() else text


templates.env.filters.update(org=_org, flag=countries.flag, country=countries.name, bytes=_bytes, since=_since,
                             date=_date, duration=_duration, region_label=countries.region_label,
                             region_flag=lambda slug: countries.flag(countries.region(slug)[0]))

_failures = {}  # ip -> (count, locked_until)


class CtlError(Exception):
    pass


def ctl(*args, data=None, timeout=90):
    try:
        p = subprocess.run(["sudo", "-n", CTL, *args], input=json.dumps(data or {}),
                           capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise CtlError("The router took too long to answer.")
    try:
        out = json.loads(p.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        raise CtlError((p.stderr or "mariner-ctl failed").strip()[:300])
    if isinstance(out, dict) and "error" in out:
        raise CtlError(out["error"])
    return out


# --- router state cache ------------------------------------------------------------
#
# mariner-ctl calls take 0.2-1 s (sudo + nmcli/systemctl/expressvpnctl). Pages
# render from this cache instead; a background thread keeps the entries that
# someone looked at in the last minute fresh (stale-while-revalidate), and
# refreshes quickly for 30 s after any action so changes show up live.

class StateCache:
    TTL = {"status": 3, "hotspot-get": 5, "devices": 5, "wifi-saved": 8,
           "logs mariner": 5, "logs vpn": 5, "logs network": 5,
           "vpn-exits": 600, "vpn-exits --expressvpn": 600}
    FAST_TTL = {"status": 1, "hotspot-get": 2, "devices": 2, "wifi-saved": 3}

    def __init__(self):
        self.data = {}      # key -> (fetched_at, value or CtlError)
        self.wanted = {}    # key -> last time a page asked for it
        self.fast_until = 0
        self.lock = threading.Lock()
        self.wake = threading.Event()
        self.started = False

    def ttl(self, key):
        if time.time() < self.fast_until and key in self.FAST_TTL:
            return self.FAST_TTL[key]
        return self.TTL.get(key, 5)

    def fetch(self, key):
        try:
            if key.startswith("logs "):
                value = ctl("logs", data={"source": key.split()[1]}, timeout=60)
            else:
                value = ctl(*key.split(), timeout=60)
        except CtlError as e:
            value = e
        with self.lock:
            self.data[key] = (time.time(), value)
        return value

    def get(self, key):
        """Cached value (raises CtlError if the last fetch failed). Fetches
        synchronously only if there's nothing cached yet."""
        self.start()
        self.wanted[key] = time.time()
        entry = self.data.get(key)
        if entry is None:
            value = self.fetch(key)
        else:
            value = entry[1]
            if time.time() - entry[0] > self.ttl(key):
                self.wake.set()
        if isinstance(value, CtlError):
            raise value
        return value

    def poke(self, sync=None):
        """Something changed: refresh soon (and `sync` keys right now)."""
        self.fast_until = time.time() + 30
        with self.lock:
            for k, (t, v) in list(self.data.items()):
                if k in self.FAST_TTL:
                    self.data[k] = (0, v)
        for k in sync or ():
            self.fetch(k)
        self.wake.set()

    def patch(self, key, fn):
        """Apply an expected change to a cached value right away, so pages
        rendered before the background action finishes don't show the old state."""
        with self.lock:
            entry = self.data.get(key)
            if entry and not isinstance(entry[1], CtlError):
                fn(entry[1])

    def start(self):
        if not self.started:
            self.started = True
            threading.Thread(target=self.loop, daemon=True, name="state-cache").start()

    def loop(self):
        while True:
            self.wake.wait(timeout=0.5)
            self.wake.clear()
            now = time.time()
            for key, seen in list(self.wanted.items()):
                if now - seen > 60:
                    continue  # nobody is looking at this right now
                entry = self.data.get(key)
                if entry is None or now - entry[0] > self.ttl(key):
                    self.fetch(key)


cache = StateCache()
_notices = {}  # session csrf -> [(kind, text)] from background actions, shown once
_notice_lock = threading.Lock()
_bg_lock = threading.Lock()  # one background action at a time


def notice(owner, kind, text):
    with _notice_lock:
        lst = _notices.setdefault(owner, [])
        lst.append((kind, text))
        del lst[:-5]


def take_notices(owner):
    with _notice_lock:
        return _notices.pop(owner, [])


def run_bg(request, fail_label, *args, data=None, timeout=150):
    """Run a slow mariner-ctl action in the background; the page updates live.
    Failures are shown (once) to the session that started the action."""
    owner = getattr(request.state, "session", {}).get("csrf")

    def work():
        with _bg_lock:
            try:
                ctl(*args, data=data, timeout=timeout)
            except CtlError as e:
                notice(owner, "err", f"{fail_label}: {e}")
            finally:
                cache.poke()
    threading.Thread(target=work, daemon=True).start()
    cache.poke()


# --- auth ---------------------------------------------------------------------

class PortalConfigError(Exception):
    pass


def portal_cfg():
    """None only if no password has ever been set. Any other problem (bad
    permissions, corrupt file) must not reopen the first-run setup page."""
    try:
        with open(PORTAL_JSON) as f:
            return json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as e:
        raise PortalConfigError(str(e))


def b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def unb64(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def make_cookie(cfg):
    payload = b64(json.dumps({"exp": int(time.time()) + SESSION_SECS, "csrf": secrets.token_urlsafe(24)}).encode())
    sig = hmac.new(bytes.fromhex(cfg["cookie_key"]), payload.encode(), hashlib.sha256).digest()
    return f"{payload}.{b64(sig)}"


def session(request):
    cfg = portal_cfg()
    raw = request.cookies.get(COOKIE, "")
    if not cfg or "." not in raw:
        return None
    payload, sig = raw.rsplit(".", 1)
    good = hmac.new(bytes.fromhex(cfg["cookie_key"]), payload.encode(), hashlib.sha256).digest()
    try:
        if not hmac.compare_digest(good, unb64(sig)):
            return None
        data = json.loads(unb64(payload))
    except (ValueError, TypeError):
        return None
    return data if data.get("exp", 0) > time.time() else None


def check_password(cfg, pw):
    s = cfg["scrypt"]
    h = hashlib.scrypt(pw.encode(), salt=bytes.fromhex(s["salt"]), n=s["n"], r=s["r"], p=s["p"])
    return hmac.compare_digest(h.hex(), s["hash"])


def same_origin(request):
    origin = request.headers.get("origin") or request.headers.get("referer")
    if not origin:
        return True
    return urlsplit(origin).netloc == request.headers.get("host", "")


def back(path, msg=None, err=None):
    q = []
    if msg:
        q.append("m=" + quote(msg))
    if err:
        q.append("e=" + quote(err))
    return RedirectResponse(path + ("?" + "&".join(q) if q else ""), status_code=303)


@app.middleware("http")
async def guard(request: Request, call_next):
    path = request.url.path
    if path.startswith("/static/"):
        return await call_next(request)
    if request.method == "POST" and not same_origin(request):
        return Response("cross-site request refused", status_code=403)
    try:
        configured = portal_cfg() is not None
    except PortalConfigError:
        return Response("Mariner can't read its portal settings (/etc/mariner/portal.json). "
                        "Fix the file or its permissions over SSH.", status_code=503)
    if not configured:
        if path != "/setup":
            return RedirectResponse("/setup", status_code=303)
        return await call_next(request)
    if path in ("/login",):
        return await call_next(request)
    scripted = bool(request.headers.get("x-mariner"))
    sess = session(request)
    if sess is None:
        if scripted:
            return JSONResponse({"location": "/login", "reload": True}, status_code=401)
        return RedirectResponse("/login", status_code=303)
    request.state.session = sess
    resp = await call_next(request)
    if scripted and request.method == "POST" and resp.status_code == 303:
        # Form submitted by app.js: answer with JSON instead of a redirect.
        loc = urlsplit(resp.headers.get("location", "/"))
        q = parse_qs(loc.query)
        resp = JSONResponse({"msg": (q.get("m") or [None])[0], "err": (q.get("e") or [None])[0],
                             "location": loc.path or "/"})
    resp.headers["Cache-Control"] = "no-store"
    return resp


def render(request, name, active, **ctx):
    msg, err = request.query_params.get("m"), request.query_params.get("e")
    owner = getattr(request.state, "session", {}).get("csrf")
    for kind, text in (take_notices(owner) if owner else []):
        if kind == "err":
            err = f"{err} {text}" if err else text
        else:
            msg = msg or text
    ctx.update(request=request, active=active, csrf=getattr(request.state, "session", {}).get("csrf", ""),
               msg=msg, err=err)
    resp = templates.TemplateResponse(request, name, ctx)
    resp.headers["X-Frame-Options"] = "DENY"
    resp.headers["Content-Security-Policy"] = "default-src 'self'; style-src 'self'; script-src 'self'; img-src 'self' data:"
    return resp


# --- setup / login -------------------------------------------------------------

@app.get("/setup", response_class=HTMLResponse)
def setup_page(request: Request):
    if portal_cfg():
        return RedirectResponse("/", status_code=303)
    return render(request, "setup.html", None)


@app.post("/setup")
def setup_post(request: Request, password: str = Form(...), confirm: str = Form(...)):
    if portal_cfg():
        return RedirectResponse("/", status_code=303)
    if len(password) < 8:
        return back("/setup", err="Use at least 8 characters.")
    if password != confirm:
        return back("/setup", err="The passwords don't match.")
    try:
        ctl("set-portal-password", data={"password": password})
    except CtlError as e:
        return back("/setup", err=str(e))
    resp = RedirectResponse("/?m=" + quote("Password set. Welcome aboard!"), status_code=303)
    resp.set_cookie(COOKIE, make_cookie(portal_cfg()), max_age=SESSION_SECS, httponly=True, samesite="strict")
    return resp


@app.get("/login", response_class=HTMLResponse)
def login_page(request: Request):
    return render(request, "login.html", None)


@app.post("/login")
def login_post(request: Request, password: str = Form(...)):
    ip = request.client.host if request.client else "?"
    count, until = _failures.get(ip, (0, 0))
    if until > time.time():
        return back("/login", err=f"Too many attempts. Try again in {int(until - time.time())} s.")
    cfg = portal_cfg()
    if not cfg or not check_password(cfg, password):
        count += 1
        _failures[ip] = (count, time.time() + 60 if count >= 5 else 0)
        return back("/login", err="Wrong password.")
    _failures.pop(ip, None)
    resp = RedirectResponse("/", status_code=303)
    resp.set_cookie(COOKIE, make_cookie(cfg), max_age=SESSION_SECS, httponly=True, samesite="strict")
    return resp


@app.post("/logout")
def logout(request: Request):
    resp = RedirectResponse("/login", status_code=303)
    resp.delete_cookie(COOKIE)
    return resp


# --- dashboard -------------------------------------------------------------------

@app.get("/", response_class=HTMLResponse)
def dashboard(request: Request):
    try:
        st, ctl_error = cache.get("status"), None
    except CtlError as e:
        st, ctl_error = {}, str(e)
    return render(request, "dashboard.html", "home", st=st, v=st.get("vpn") or {}, ctl_error=ctl_error)


@app.post("/public-ip")
def public_ip(request: Request):
    run_bg(request, "Checking IPs failed", "public-ip", "--fresh", timeout=90)
    return back("/", msg="Checking where your traffic comes out…")


# --- captive portal ----------------------------------------------------------------

@app.get("/portal", response_class=HTMLResponse)
def portal_page(request: Request):
    try:
        st = cache.get("status")
    except CtlError as e:
        return back("/", err=str(e))
    return render(request, "portal.html", "home", st=st)


@app.post("/portal/check")
def portal_check(request: Request):
    run_bg(request, "Checking failed", "check", timeout=150)
    return back("/portal", msg="Checking the connection again…")


@app.post("/portal/allow")
def portal_allow(request: Request):
    try:
        ctl("portal-login-allow")
    except CtlError as e:
        return back("/portal", err=str(e))
    cache.poke(sync=["status"])
    return back("/portal", msg="Direct access allowed for 10 minutes. Log in now.")


# --- Wi-Fi -------------------------------------------------------------------------

@app.get("/wifi", response_class=HTMLResponse)
def wifi_page(request: Request, scan: int = 0):
    nets, saved, st, link = None, [], {}, {}
    try:
        ws = cache.get("wifi-saved")
        saved, link = ws["profiles"], ws.get("link") or {}
        st = cache.get("status")
        if scan:
            nets = wifi_scan()
    except CtlError as e:
        return render(request, "wifi.html", "wifi", saved=saved, nets=nets, st=st, link=link, scan_error=str(e))
    return render(request, "wifi.html", "wifi", saved=saved, nets=nets, st=st, link=link)


_scan = {"at": 0, "nets": None}
_scan_lock = threading.Lock()


def wifi_scan():
    """Scanning takes the shared radio off the hotspot's channel for a moment,
    so reuse a recent scan instead of rescanning on every page load."""
    with _scan_lock:
        if _scan["nets"] is None or time.time() - _scan["at"] > 20:
            _scan["nets"] = ctl("wifi-scan", timeout=60)["networks"]
            _scan["at"] = time.time()
        return _scan["nets"]


@app.post("/wifi/connect")
def wifi_connect(request: Request, ssid: str = Form(...), password: str = Form(""), band: str = Form("auto")):
    try:
        ctl("wifi-connect", data={"ssid": ssid, "password": password, "band": "bg" if band == "bg" else "auto"},
            timeout=90)
    except CtlError as e:
        return back("/wifi", err=str(e))
    cache.poke(sync=["wifi-saved"])
    return back("/", msg=f"Connected to {ssid}. Checking for a login page…")


@app.post("/wifi/forget")
def wifi_forget(request: Request, uuid: str = Form(...)):
    try:
        ctl("wifi-forget", data={"uuid": uuid})
    except CtlError as e:
        return back("/wifi", err=str(e))
    cache.poke(sync=["wifi-saved"])
    return back("/wifi", msg="Network forgotten.")


@app.post("/wifi/lock")
def wifi_lock(request: Request, uuid: str = Form(...), lock: str = Form("0")):
    try:
        ctl("wifi-lock", data={"uuid": uuid, "lock": lock == "1"}, timeout=90)
    except CtlError as e:
        return back("/wifi", err=str(e))
    cache.poke(sync=["wifi-saved"])
    return back("/wifi", msg="Staying on this access point." if lock == "1" else "Roaming between access points again.")


@app.post("/wifi/band")
def wifi_band(request: Request, uuid: str = Form(...), band: str = Form(...)):
    try:
        ctl("wifi-band", data={"uuid": uuid, "band": band})
    except CtlError as e:
        return back("/wifi", err=str(e))
    cache.poke(sync=["wifi-saved"])
    return back("/wifi", msg="Band updated." if band == "auto" else "Forced to 2.4 GHz.")


# --- VPN (Geph / Outline) -----------------------------------------------------------

@app.get("/geph")
def geph_redirect():
    return RedirectResponse("/vpn", status_code=301)


@app.get("/vpn", response_class=HTMLResponse)
def vpn_page(request: Request):
    try:
        v = cache.get("status")["vpn"]
        exits = cache.get("vpn-exits")["exits"] if v["provider"] == "geph" else []
        regions = cache.get("vpn-exits --expressvpn")["regions"] if v["provider"] == "expressvpn" else []
    except CtlError as e:
        return back("/", err=str(e))
    # ExpressVPN locations grouped by country, alphabetically, for the picker.
    groups = {}
    for r in regions:
        code, _ = countries.region(r)
        groups.setdefault(countries.name(code) if code else "Other", []).append(r)
    return render(request, "vpn.html", "vpn", v=v, exits=exits, evpn_groups=sorted(groups.items()))


@app.post("/vpn/toggle")
def vpn_toggle(request: Request, on: str = Form(...), next: str = Form("/vpn")):
    dest = next if next in ("/", "/vpn") else "/vpn"
    try:
        v = cache.get("status")["vpn"]
    except CtlError:
        v = {}
    if on == "1" and v and not v.get("has_credentials"):
        return back(dest, err=f"Set up {v.get('provider_name', 'the VPN')} first.")
    def expect(st):
        vpn = st.get("vpn") or {}
        vpn["enabled"] = on == "1"
        vpn["mode"] = "on" if on == "1" else "off"
        vpn["connection"] = "starting" if on == "1" else "stopped"
        vpn["detail"] = (f"Starting {vpn.get('provider_name', 'the VPN')}…" if on == "1"
                         else "Off. Hotspot traffic goes out directly.")
        vpn["exit"], vpn["connected_since"] = None, None
    cache.patch("status", expect)
    run_bg(request, "Couldn't switch the VPN", "vpn-enable", "on" if on == "1" else "off")
    return back(dest, msg="Turning the VPN on…" if on == "1" else "VPN off. Traffic goes out directly.")


@app.post("/vpn/provider")
def vpn_provider(request: Request, provider: str = Form(...)):
    try:
        ctl("vpn-set", data={"provider": provider}, timeout=150)
    except CtlError as e:
        return back("/vpn", err=str(e))
    cache.poke(sync=["status"])
    return back("/vpn", msg=f"Using {dict(geph='Geph', outline='Outline', expressvpn='ExpressVPN').get(provider, provider)}.")


@app.post("/vpn/killswitch")
def vpn_killswitch(request: Request, killswitch: str = Form("0")):
    try:
        ctl("vpn-set", data={"killswitch": killswitch == "1"}, timeout=120)
    except CtlError as e:
        return back("/vpn", err=str(e))
    cache.poke(sync=["status"])
    return back("/vpn", msg="Kill switch on." if killswitch == "1" else "Kill switch off.")


@app.post("/vpn/geph/exit")
def geph_exit(request: Request, exit: str = Form("auto")):
    run_bg(request, "Couldn't change the exit", "vpn-set", data={"exit": exit})
    return back("/vpn", msg="Exit location saved. Reconnecting…")


@app.post("/vpn/geph/account")
def geph_account(request: Request, kind: str = Form(...), secret: str = Form(""),
                 username: str = Form(""), password: str = Form("")):
    if kind == "secret":
        creds = {"type": "secret", "secret": secret}
    elif kind == "password":
        creds = {"type": "password", "username": username, "password": password}
    else:
        creds = None
    try:
        ctl("vpn-set", data={"credentials": creds}, timeout=120)
    except CtlError as e:
        return back("/vpn", err=str(e))
    cache.poke(sync=["status"])
    return back("/vpn", msg="Geph account removed." if creds is None else "Geph account saved.")


@app.post("/vpn/expressvpn/login")
def evpn_login(request: Request, code: str = Form(...)):
    try:
        ctl("evpn-login", data={"code": code}, timeout=120)
    except CtlError as e:
        return back("/vpn", err=str(e))
    cache.poke(sync=["status"])
    return back("/vpn", msg="Signed in to ExpressVPN.")


@app.post("/vpn/expressvpn/logout")
def evpn_logout(request: Request):
    try:
        ctl("evpn-logout", timeout=120)
    except CtlError as e:
        return back("/vpn", err=str(e))
    cache.poke(sync=["status"])
    return back("/vpn", msg="Signed out of ExpressVPN.")


@app.post("/vpn/expressvpn/settings")
def evpn_settings(request: Request, region: str = Form("smart"), protocol: str = Form("wireguard")):
    def expect(st):  # show the switch right away; live refresh takes over
        vpn = st.get("vpn") or {}
        e = vpn.get("expressvpn") or {}
        if vpn.get("enabled") and vpn.get("provider") == "expressvpn":
            e["switching_to"] = region
            vpn["connection"] = "connecting"
            vpn["detail"] = "Switching location…"
            vpn["exit"], vpn["connected_since"] = None, None
        e["region"], e["protocol"] = region, protocol
    cache.patch("status", expect)
    run_bg(request, "Couldn't apply the ExpressVPN settings", "vpn-set",
           data={"evpn_region": region, "evpn_protocol": protocol})
    return back("/vpn", msg=f"Switching to {countries.region_label(region)}…")


@app.post("/vpn/outline/key")
def outline_key(request: Request, key: str = Form(""), remove: str = Form("")):
    try:
        ctl("vpn-set", data={"outline_key": None if remove else key}, timeout=120)
    except CtlError as e:
        return back("/vpn", err=str(e))
    cache.poke(sync=["status"])
    return back("/vpn", msg="Outline key removed." if remove else "Outline access key saved.")


# --- hotspot -------------------------------------------------------------------------

@app.get("/hotspot", response_class=HTMLResponse)
def hotspot_page(request: Request):
    try:
        hs = cache.get("hotspot-get")
        devices = cache.get("devices")["devices"]
    except CtlError as e:
        return back("/", err=str(e))
    return render(request, "hotspot.html", "hotspot", hs=hs, devices=devices, now=int(time.time()))


@app.post("/hotspot")
def hotspot_post(request: Request, ssid: str = Form(""), password: str = Form(""), band: str = Form("")):
    data = {k: v for k, v in (("ssid", ssid.strip()), ("password", password), ("band", band)) if v}
    try:
        ctl("hotspot-set", data=data)
    except CtlError as e:
        return back("/hotspot", err=str(e))
    cache.poke()
    return back("/hotspot", msg="Saved. The hotspot restarts now. Reconnect your device if it drops"
                + (" (use the new name/password)." if ssid or password else "."))


# --- system ------------------------------------------------------------------------

@app.get("/system", response_class=HTMLResponse)
def system_page(request: Request, log: str = "mariner"):
    if log not in ("mariner", "vpn", "network"):
        log = "mariner"
    try:
        lines = cache.get(f"logs {log}")["lines"]
        radio = cache.get("status").get("radio", {})
    except CtlError as e:
        lines, radio = [f"(could not read logs: {e})"], {}
    return render(request, "system.html", "system", lines=lines, log=log, radio=radio)


@app.post("/system/restart")
def system_restart(request: Request, service: str = Form(...)):
    try:
        ctl("restart", data={"service": service})
    except CtlError as e:
        return back("/system", err=str(e))
    cache.poke()
    return back("/system", msg=f"Restarting {service}…")


@app.post("/system/reboot")
def system_reboot(request: Request):
    try:
        ctl("reboot")
    except CtlError as e:
        return back("/system", err=str(e))
    return render(request, "rebooting.html", None)


@app.post("/system/poweroff")
def system_poweroff(request: Request):
    try:
        ctl("poweroff")
    except CtlError as e:
        return back("/system", err=str(e))
    return render(request, "poweroff.html", None)


@app.post("/system/password")
def system_password(request: Request, current: str = Form(...), password: str = Form(...), confirm: str = Form(...)):
    cfg = portal_cfg()
    if not check_password(cfg, current):
        return back("/system", err="Current password is wrong.")
    if len(password) < 8 or password != confirm:
        return back("/system", err="New passwords must match and be at least 8 characters.")
    try:
        ctl("set-portal-password", data={"password": password, "replace": True})
    except CtlError as e:
        return back("/system", err=str(e))
    resp = back("/system", msg="Password changed. Other devices were signed out.")
    resp.set_cookie(COOKIE, make_cookie(portal_cfg()), max_age=SESSION_SECS, httponly=True, samesite="strict")
    return resp
