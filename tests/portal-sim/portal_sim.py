#!/usr/bin/env python3
"""Offline simulation harness for bin/mariner-check's captive-portal logic.

Loads the real bin/mariner-check as a module and patches only the
environment-specific parts (uplink_info, bound_socket, run). resolve,
_parse_reply, http_get, find_portal_url, probe and check run unmodified
against local fake DNS (UDP) and HTTP (TCP) servers whose behaviour each
scenario controls. Python 3 stdlib only; runs on Windows, macOS and Linux
(including the Pi, without touching wlan0 or needing root).

  python tests/portal-sim/portal_sim.py            # all scenarios
  python tests/portal-sim/portal_sim.py -k dns     # ids/groups containing "dns"
  python tests/portal-sim/portal_sim.py -v         # per-probe details
  python tests/portal-sim/portal_sim.py --json out.json
"""
import argparse
import importlib.util
import json
import random
import socket
import struct
import sys
import threading
import time
import traceback
import types
from concurrent.futures import ThreadPoolExecutor
from importlib.machinery import SourceFileLoader
from pathlib import Path
from urllib.parse import urlsplit

HERE = Path(__file__).resolve().parent
CHECK_PATH = HERE.parent.parent / "bin" / "mariner-check"   # --check overrides
HANG_LIMIT = 45.0      # a check() taking longer than this is reported as hung
SLOW_LIMIT = 15.0      # a check() taking longer than this is flagged slow

APPLE, GOOGLE, MS = "captive.apple.com", "connectivitycheck.gstatic.com", "www.msftconnecttest.com"
APPLE_URL = "http://captive.apple.com/hotspot-detect.html"
GOOGLE_URL = "http://connectivitycheck.gstatic.com/generate_204"
MS_URL = "http://www.msftconnecttest.com/connecttest.txt"
FIREFOX = "detectportal.firefox.com"   # not probed today; answered for patched versions
REAL_IP = {APPLE: "17.253.144.10", GOOGLE: "142.250.72.99", MS: "13.107.4.52",
           FIREFOX: "34.107.221.82", "example.com": "93.184.215.14", "neverssl.com": "34.223.124.45"}
GW = "10.10.0.1"           # uplink gateway = DNS server = portal web server
PORTAL = "http://login.hotelwifi.test/portal?ap=7"
APPLE_BODY = b"<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"
MS_BODY = b"Microsoft Connect Test"


# --- loading the code under test -------------------------------------------

def load_check(tag):
    """A fresh, independent instance of bin/mariner-check."""
    if "fcntl" not in sys.modules:
        try:
            import fcntl  # noqa: F401
        except ImportError:  # Windows: only main() uses it
            stub = types.ModuleType("fcntl")
            stub.LOCK_EX = 2
            stub.flock = lambda *a: None
            sys.modules["fcntl"] = stub
    name = f"mariner_check_sim_{tag}"
    loader = SourceFileLoader(name, str(CHECK_PATH))
    spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


# --- DNS packet helpers -----------------------------------------------------

def qname_of(query):
    labels, off = [], 12
    while off < len(query) and query[off]:
        n = query[off]
        labels.append(query[off + 1:off + 1 + n].decode("ascii", "replace"))
        off += 1 + n
    return ".".join(labels).lower()


def a_rr(ip, name=b"\xc0\x0c"):
    return name + struct.pack(">HHIH", 1, 1, 60, 4) + socket.inet_aton(ip)


def cname_rr(target, name=b"\xc0\x0c"):
    enc = b"".join(bytes([len(p)]) + p.encode() for p in target.split(".")) + b"\0"
    return name + struct.pack(">HHIH", 5, 1, 60, len(enc)) + enc


def dns_reply(query, ips=(), rcode=0, qid=None, records=None, flags=None, an=None):
    qid = struct.unpack(">H", query[:2])[0] if qid is None else qid
    recs = list(records) if records is not None else [a_rr(ip) for ip in ips]
    fl = (0x8180 | rcode) if flags is None else flags
    hdr = struct.pack(">HHHHHH", qid, fl, 1, len(recs) if an is None else an, 0, 0)
    return hdr + query[12:] + b"".join(recs)


def real_dns(ctx):
    ip = REAL_IP.get(ctx.qname)
    return dns_reply(ctx.query, [ip]) if ip else dns_reply(ctx.query, rcode=3)


# --- HTTP helpers -----------------------------------------------------------

REASONS = {200: "OK", 204: "No Content", 301: "Moved Permanently", 302: "Found",
           303: "See Other", 307: "Temporary Redirect", 308: "Permanent Redirect",
           403: "Forbidden", 404: "Not Found", 511: "Network Authentication Required"}


def resp(status, body=b"", headers=(), cl=True, eol=b"\r\n", version="HTTP/1.1"):
    if isinstance(body, str):
        body = body.encode()
    lines = [f"{version} {status} {REASONS.get(status, 'X')}".encode()]
    for k, v in headers:
        lines.append(f"{k}: {v}".encode("latin-1"))
    if cl:
        lines.append(f"Content-Length: {len(body)}".encode())
    lines.append(b"Connection: close")
    return eol.join(lines) + eol + eol + body


def real_answer(host):
    if host == APPLE:
        return resp(200, APPLE_BODY, [("Content-Type", "text/html")])
    if host == GOOGLE:
        return resp(204)
    if host == MS:
        return resp(200, MS_BODY, [("Content-Type", "text/plain")])
    if host == FIREFOX:
        return resp(200, b"success\n", [("Content-Type", "text/plain")])
    if host == "example.com":
        return resp(200, b"<html><title>Example Domain</title></html>", [("Content-Type", "text/html")])
    return resp(404, "not found")


def real_http(ctx):
    return real_answer(ctx.host)


def redirect(status=302, loc=PORTAL):
    return lambda ctx: resp(status, "<html>Moved</html>", [("Location", loc)])


def page(html, status=200, headers=()):
    return lambda ctx: resp(status, html, [("Content-Type", "text/html")] + list(headers))


LOGIN = "<html><head><title>Hotel WiFi</title></head><body><form>Room <input name=room></form></body></html>"


def per_host(apple=real_http, google=real_http, ms=real_http, other=real_http):
    table = {APPLE: apple, GOOGLE: google, MS: ms}
    return lambda ctx: table.get(ctx.host, other)(ctx)


def hijack_all(ip=GW):
    return lambda ctx: dns_reply(ctx.query, [ip])


# --- simulation environment -------------------------------------------------

class Ctx:
    pass


class Sim:
    """Per-scenario fake network: DNS and HTTP listeners on 127.0.0.1."""

    def __init__(self, sc, mod):
        self.sc, self.mod = sc, mod
        self.state = {}          # scenario-private, persists across runs
        self.run_idx = 0
        self.stop = threading.Event()
        self.lock = threading.Lock()
        self.tcp_listeners, self.udp_listeners = {}, {}
        self.open_socks = []
        self.log = []
        sim = self

        class SimSocket(socket.socket):
            def connect(self, addr):
                ip, port = addr[0], addr[1]
                sim.log.append(f"tcp {ip}:{port}")
                policy = sim.sc.connect(ip, port) if sim.sc.connect else "ok"
                if policy == "refuse":
                    raise ConnectionRefusedError(111, "Connection refused")
                if policy == "timeout":
                    sim.stop.wait(self.gettimeout() or 0)
                    raise TimeoutError("timed out")
                super().connect(("127.0.0.1", sim.tcp_port(ip, port)))

            def sendto(self, data, *args):
                ip, port = args[-1][0], args[-1][1]
                sim.log.append(f"udp {ip}:{port}")
                return super().sendto(data, ("127.0.0.1", sim.udp_port(ip, port)))

        self.SimSocket = SimSocket

    # patched replacements for the environment-specific functions
    def bound_socket(self, kind):
        s = self.SimSocket(socket.AF_INET, kind)
        s.settimeout(self.mod.TIMEOUT)
        with self.lock:
            self.open_socks.append(s)
        return s

    def uplink_info(self):
        return self.sc.uplink or (True, "Hotel-Guest", "10.10.3.77", list(self.sc.dns_servers))

    def patch(self):
        self.mod.bound_socket = self.bound_socket
        self.mod.uplink_info = self.uplink_info
        self.mod.run = lambda *cmd: ""

    # listeners
    def _listen(self, kind):
        s = socket.socket(socket.AF_INET, kind)
        s.bind(("127.0.0.1", 0))
        with self.lock:
            self.open_socks.append(s)
        return s

    def tcp_port(self, ip, port):
        with self.lock:
            if (ip, port) in self.tcp_listeners:
                return self.tcp_listeners[(ip, port)]
        s = self._listen(socket.SOCK_STREAM)
        s.listen(16)
        threading.Thread(target=self._accept_loop, args=(s, ip), daemon=True).start()
        with self.lock:
            self.tcp_listeners[(ip, port)] = s.getsockname()[1]
        return s.getsockname()[1]

    def udp_port(self, ip, port):
        with self.lock:
            if (ip, port) in self.udp_listeners:
                return self.udp_listeners[(ip, port)]
        s = self._listen(socket.SOCK_DGRAM)
        threading.Thread(target=self._udp_loop, args=(s, ip), daemon=True).start()
        with self.lock:
            self.udp_listeners[(ip, port)] = s.getsockname()[1]
        return s.getsockname()[1]

    def _udp_loop(self, s, server_ip):
        while not self.stop.is_set():
            try:
                q, peer = s.recvfrom(4096)
            except OSError:   # closed, or Windows WSAECONNRESET from an old reply
                if self.stop.is_set():
                    return
                continue
            ctx = Ctx()
            ctx.query, ctx.qname, ctx.server, ctx.state, ctx.run = q, qname_of(q), server_ip, self.state, self.run_idx
            try:
                out = self.sc.dns(ctx)
            except Exception:
                traceback.print_exc()
                out = None
            if out is None:
                continue                      # drop: client times out
            if isinstance(out, bytes):
                out = [(0, out)]
            threading.Thread(target=self._udp_send, args=(s, peer, out), daemon=True).start()

    def _udp_send(self, s, peer, packets):
        for delay, pkt in packets:
            if delay and self.stop.wait(delay):
                return
            try:
                s.sendto(pkt, peer)
            except OSError:
                return

    def _accept_loop(self, s, ip):
        while not self.stop.is_set():
            try:
                c, _ = s.accept()
            except OSError:
                return
            with self.lock:
                self.open_socks.append(c)
            threading.Thread(target=self._serve, args=(c, ip), daemon=True).start()

    def _serve(self, c, ip):
        try:
            c.settimeout(5)
            req = b""
            while b"\r\n\r\n" not in req and len(req) < 65536:
                chunk = c.recv(4096)
                if not chunk:
                    break
                req += chunk
            head = req.split(b"\r\n\r\n")[0].decode("latin-1").split("\r\n")
            ctx = Ctx()
            ctx.ip, ctx.request, ctx.conn, ctx.sim = ip, req, c, self
            ctx.state, ctx.run = self.state, self.run_idx
            parts = head[0].split(" ")
            ctx.path = parts[1] if len(parts) > 1 else "/"
            ctx.host = ""
            for line in head[1:]:
                k, _, v = line.partition(":")
                if k.strip().lower() == "host":
                    ctx.host = v.strip().lower()
            with self.lock:
                self.state.setdefault("requests", []).append((ctx.run, ip, ctx.host))
            out = self.sc.http(ctx)
            if isinstance(out, bytes):
                c.sendall(out)
            elif out == "rst":
                rst(c)
                return
        except OSError:
            pass
        finally:
            try:
                c.close()
            except OSError:
                pass

    def close(self):
        self.stop.set()
        with self.lock:
            socks = list(self.open_socks)
        for s in socks:
            try:
                s.close()
            except OSError:
                pass


def rst(c):
    c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    c.close()


# --- scenarios ---------------------------------------------------------------

class Scenario:
    def __init__(self, sid, group, desc, expect, url=None, dns=real_dns, http=real_http,
                 connect=None, dns_servers=(GW,), uplink=None, runs=1, note=""):
        self.id, self.group, self.desc = sid, group, desc
        # expect: state string, a tuple of acceptable states, None (any verdict:
        # only "no crash / no hang"), or a list with one of those per run.
        self.expect = expect if isinstance(expect, list) else [expect] * runs
        self.url = url        # expected portal_url (str), or None = don't check
        self.dns, self.http, self.connect = dns, http, connect
        self.dns_servers, self.uplink, self.runs, self.note = dns_servers, uplink, runs, note


S = []


def sc(*a, **kw):
    S.append(Scenario(*a, **kw))


def blackhole(ctx):
    return None


# 1. normal internet
sc("N1", "normal", "All three probes answer like the real servers", "online")
sc("N2", "normal", "HTTP/1.0 answers, no Content-Length", "online",
   http=lambda ctx: real_answer(ctx.host).replace(b"HTTP/1.1", b"HTTP/1.0"))
sc("N3", "normal", "Chunked transfer-encoding (Apple/MS bodies chunked)", "online",
   http=per_host(apple=lambda c: resp(200, b"46\r\n" + APPLE_BODY + b"\r\n0\r\n\r\n",
                                       [("Transfer-Encoding", "chunked")], cl=False),
                 ms=lambda c: resp(200, b"16\r\n" + MS_BODY + b"\r\n0\r\n\r\n",
                                   [("Transfer-Encoding", "chunked")], cl=False)))
sc("N4", "normal", "Two DHCP DNS servers, first one dead (drops queries)", "online",
   dns=lambda ctx: None if ctx.server == "10.10.0.2" else real_dns(ctx), dns_servers=("10.10.0.2", GW))


def dribble_ok(ctx):
    data = real_answer(ctx.host)
    for i in range(0, len(data), 20):
        ctx.conn.sendall(data[i:i + 20])
        if ctx.sim.stop.wait(0.3):
            return None
    return None


sc("N5", "normal", "Answers arrive in small pieces (0.3 s apart)", "online", http=dribble_ok)


def keepalive(ctx):
    """Server/proxy that ignores Connection: close and keeps the socket open."""
    data = real_answer(ctx.host).replace(b"Connection: close", b"Connection: keep-alive")
    ctx.conn.sendall(data)
    ctx.sim.stop.wait(30)
    return None


sc("N6", "normal", "Proxy ignores 'Connection: close' (keep-alive, Content-Length given)", "online",
   http=keepalive, note="realistic for some transparent proxies / load balancers")
sc("N7", "normal", "Bare-LF line endings (non-conformant middlebox)", "online",
   http=lambda ctx: resp(int(real_answer(ctx.host)[9:12]),
                         APPLE_BODY if ctx.host == APPLE else MS_BODY if ctx.host == MS else b"",
                         eol=b"\n"),
   note="edge case; browsers/OS checks accept bare LF")
sc("N8", "normal", "Multiple A records per name (only first used)", "online",
   dns=lambda ctx: dns_reply(ctx.query, [REAL_IP.get(ctx.qname, "1.1.1.1"), "9.9.9.9"]))

# 2. redirects
sc("R1", "redirect", "302 absolute Location on every probe", "portal", url=PORTAL, http=redirect(302))
sc("R2", "redirect", "303 relative Location (/login?x=1)", "portal",
   url="http://captive.apple.com/login?x=1", http=redirect(303, "/login?x=1"))
sc("R3", "redirect", "307 to https login page", "portal", url="https://portal.example.net/login",
   http=redirect(307, "https://portal.example.net/login"))
sc("R4", "redirect", "301/308 permanent redirects", "portal", url=PORTAL,
   http=per_host(apple=redirect(301), google=redirect(308), ms=redirect(301)))
sc("R5", "redirect", "Scheme-relative Location //portal.example/login", "portal",
   url="http://portal.example/login", http=redirect(302, "//portal.example/login"))
sc("R6", "redirect", "302 without Location, body has meta refresh", "portal",
   url=PORTAL, http=page(f'<meta http-equiv="refresh" content="0; url={PORTAL}">', status=302))
sc("R7", "redirect", "Header named in upper case ('LOCATION:')", "portal", url=PORTAL,
   http=lambda ctx: resp(302, "", [("LOCATION", PORTAL)]))
sc("R8", "redirect", "Relative Location without slash ('login.php')", "portal",
   url="http://captive.apple.com/login.php", http=redirect(302, "login.php"))

# 3. 200 pages
sc("P1", "page200", "200 + <meta http-equiv=refresh content='0; url=...'>", "portal", url=PORTAL,
   http=page(f'<html><head><meta http-equiv="refresh" content="0; url={PORTAL}"></head></html>'))
sc("P2", "page200", "200 + meta refresh with content= BEFORE http-equiv=", "portal", url=PORTAL,
   http=page(f'<html><head><meta content="0;URL={PORTAL}" http-equiv="refresh"></head></html>'))
sc("P3", "page200", "200 + meta refresh with quoted url (content=\"0; URL='...'\")", "portal", url=PORTAL,
   http=page(f'<html><head><meta http-equiv="refresh" content="0; URL=\'{PORTAL}\'"></head></html>'))
sc("P4", "page200", "200 + meta refresh URL with &amp; entity", "portal",
   url="http://login.hotelwifi.test/portal?ap=7&mac=aa",
   http=page('<meta http-equiv="refresh" content="0; url=http://login.hotelwifi.test/portal?ap=7&amp;mac=aa">'))
sc("P5", "page200", "200 + relative meta refresh (login.php)", "portal",
   url="http://captive.apple.com/login.php",
   http=page('<meta http-equiv="refresh" content="1;url=login.php">'))
sc("P6", "page200", "200 + JS window.location = '...'", "portal", url=PORTAL,
   http=page(f'<script>window.location = "{PORTAL}";</script>'))
sc("P7", "page200", "200 + JS window.location.href='...'", "portal", url=PORTAL,
   http=page(f"<script>window.location.href='{PORTAL}'</script>"))
sc("P8", "page200", "200 + JS window.location.replace('...')", "portal", url=PORTAL,
   http=page(f"<script>window.location.replace('{PORTAL}')</script>"))
sc("P9", "page200", "200 + JS top.location.href / location.href (no window.)", "portal", url=PORTAL,
   http=page(f'<script>top.location.href="{PORTAL}";</script>'))
sc("P10", "page200", "200 inline login form, no redirect (portal_url = probe URL)", "portal",
   url=APPLE_URL, http=page(LOGIN))
sc("P11", "page200", "200 + 'Refresh: 0; url=...' HTTP header (no meta)", "portal", url=PORTAL,
   http=page(LOGIN, headers=[("Refresh", f"0; url={PORTAL}")]))
sc("P12", "page200", "200 empty body for everything (pre-auth accept)", "portal", url=APPLE_URL,
   http=lambda ctx: resp(200))
sc("P13", "page200", "404 for every probe path (portal web server)", "portal", url=APPLE_URL,
   http=lambda ctx: resp(404, "<h1>Not Found</h1>"))

# 4. 511
sc("S1", "511", "511 with meta refresh body (RFC 6585 style)", "portal", url=PORTAL,
   http=page(f'<html><head><meta http-equiv="refresh" content="0; url={PORTAL}"></head></html>', status=511))
sc("S2", "511", "511 with no body", "portal", url=APPLE_URL, http=lambda ctx: resp(511))

# 5. DNS hijack
sc("H1", "hijack", "DNS hijack: every name -> portal IP, which 302s", "portal", url=PORTAL,
   dns=hijack_all(), http=lambda ctx: redirect()(ctx) if ctx.ip == GW else real_http(ctx))
sc("H2", "hijack", "DNS hijack: every name -> portal IP, which serves login page", "portal",
   url=APPLE_URL, dns=hijack_all(), http=lambda ctx: page(LOGIN)(ctx) if ctx.ip == GW else real_http(ctx))
sc("H3", "hijack", "DNS hijack to 1.1.1.1-style public IP owned by portal (meta refresh)", "portal",
   url=PORTAL, dns=hijack_all("1.1.1.1"),
   http=page(f'<meta http-equiv="refresh" content="0; url={PORTAL}">'))

# 6. DNS failures
for sid, rc, nm in (("D1", 3, "NXDOMAIN"), ("D2", 2, "SERVFAIL"), ("D3", 5, "REFUSED")):
    sc(sid, "dns-fail", f"DNS answers {nm} for everything until login", "offline",
       dns=(lambda r: lambda ctx: dns_reply(ctx.query, rcode=r))(rc),
       note="no portal URL discoverable; offline is the best available verdict")
sc("D4", "dns-fail", "DNS times out (1 server)", "offline", dns=blackhole)
sc("D5", "dns-fail", "DNS times out (3 DHCP DNS servers)", "offline", dns=blackhole,
   dns_servers=(GW, "10.10.0.2", "10.10.0.3"))
sc("D6", "dns-fail", "DNS answers 0.0.0.0 for everything", "offline",
   dns=hijack_all("0.0.0.0"), connect=lambda ip, port: "refuse" if ip == "0.0.0.0" else "ok",
   note="on Linux connect(0.0.0.0) means localhost; modelled as refused")
sc("D7", "dns-fail", "DNS answers a private IP where nothing listens (timeout)", "offline",
   dns=hijack_all("10.255.255.1"), connect=lambda ip, port: "timeout" if ip == "10.255.255.1" else "ok")
sc("D8", "dns-fail", "DNS answers CNAME only (no A)", "offline",
   dns=lambda ctx: dns_reply(ctx.query, records=[cname_rr("portal.hotel.test")]))
sc("D9", "dns-fail", "First A record unreachable, second works (all probes)", "online",
   dns=lambda ctx: dns_reply(ctx.query, ["203.0.113.9", REAL_IP.get(ctx.qname, "1.1.1.1")]),
   connect=lambda ip, port: "timeout" if ip == "203.0.113.9" else "ok",
   note="multi-A answers are normal for the MS/Google probe names")

# 7. walled garden
sc("W1", "walled", "Apple whitelisted (CNA bypass); Google+MS 302", "portal", url=PORTAL,
   http=per_host(google=redirect(), ms=redirect(), other=redirect()))
sc("W2", "walled", "Apple whitelisted; Google+MS 200 login page", "portal", url=GOOGLE_URL,
   http=per_host(google=page(LOGIN), ms=page(LOGIN), other=page(LOGIN)))
sc("W3", "walled", "Apple 302; Google+MS whitelisted", "portal", url=PORTAL,
   http=per_host(apple=redirect(), other=redirect()))
sc("W4", "walled", "Apple 200 login page; Google+MS whitelisted", "portal", url=APPLE_URL,
   http=per_host(apple=page(LOGIN), other=page(LOGIN)), note="same shape as F2 unless a tie-break probe is used")
sc("W5", "walled", "Apple+Google whitelisted (fonts/CNA), MS 200 login page", "portal", url=MS_URL,
   http=per_host(ms=page(LOGIN), other=page(LOGIN)), note="same shape as F2 unless a tie-break probe is used")
sc("W6", "walled", "Portal spoofs Apple 'Success' and Google 204, MS 302", "portal", url=PORTAL,
   http=per_host(ms=redirect(), other=redirect()))
sc("W7", "walled", "Login page contains 'Success' (JS onSuccess); gstatic whitelisted; MS page", "portal",
   url=None, http=per_host(apple=page(LOGIN + "<script>function onLoginSuccess(){}</script>"),
                           ms=page(LOGIN), other=page(LOGIN)),
   note="Apple check is a substring test")
sc("W8", "walled", "Portal spoofs all three expected answers, blocks everything else", ("online", "portal"),
   http=per_host(other=page(LOGIN)), note="undetectable with these probes; informational")

# 8. transparent proxy
sc("T1", "proxy", "Proxy rewrites Google 204 -> 200 empty body", "online",
   http=per_host(google=lambda c: resp(200)))
sc("T2", "proxy", "Proxy appends tracking script to MS probe body", "online",
   http=per_host(ms=lambda c: resp(200, MS_BODY + b"<script src=http://isp.example/t.js></script>")))
sc("T3", "proxy", "ISP banner injection into every 200 + Google 204->200", "online",
   http=per_host(apple=lambda c: resp(200, APPLE_BODY + b"<div>ISP ad</div>"),
                 google=lambda c: resp(200, "<div>ISP ad</div>"),
                 ms=lambda c: resp(200, MS_BODY + b"<div>ISP ad</div>")))
sc("T4", "proxy", "Proxy adds Via/X-Cache headers, gzip-free", "online",
   http=lambda ctx: real_answer(ctx.host).replace(b"Connection: close", b"Via: 1.1 squid\r\nX-Cache: MISS\r\nConnection: close"))

# 9. content filter on ONE probe domain
sc("F1", "filter", "Filter: Google probe name NXDOMAIN", "online",
   dns=lambda ctx: dns_reply(ctx.query, rcode=3) if ctx.qname == GOOGLE else real_dns(ctx))
sc("F2", "filter", "Filter: MS probe gets 200 block page", "online",
   http=per_host(ms=page("<h1>Blocked by policy</h1>")))
sc("F3", "filter", "Filter: MS probe 302 -> block page (Umbrella/school/corporate style)", "online",
   http=per_host(ms=redirect(302, "http://block.filter.example/?cat=telemetry")))
sc("F4", "filter", "Filter: gstatic sinkholed to 0.0.0.0 (Pi-hole style)", "online",
   dns=lambda ctx: dns_reply(ctx.query, ["0.0.0.0"]) if ctx.qname == GOOGLE else real_dns(ctx),
   connect=lambda ip, port: "refuse" if ip == "0.0.0.0" else "ok")
sc("F5", "filter", "Censor: TCP RST on Google probe only", "online",
   http=per_host(google=lambda c: "rst"))
sc("F6", "filter", "Filter: Apple probe 403 Forbidden", "online",
   http=per_host(apple=lambda c: resp(403, "Forbidden")))
sc("F7", "filter", "Censor: Google probe 302 to state block page", "online",
   http=per_host(google=redirect(302, "http://blocked.gov.example/")))

# 10. TCP-level problems and timing
sc("X1", "tcp", "TCP RST on port 80 for everything (DNS fine)", "offline", http=lambda c: "rst")
sc("X2", "tcp", "Port 80 connect times out for everything", "offline",
   connect=lambda ip, port: "timeout")
sc("X3", "tcp", "Accepts TCP, then never answers", "offline",
   http=lambda ctx: ctx.sim.stop.wait(30) and None)
sc("X4", "tcp", "Everything times out (DNS and TCP)", "offline", dns=blackhole,
   connect=lambda ip, port: "timeout")


def slow(delay):
    def h(ctx):
        if ctx.sim.stop.wait(delay):
            return None
        return real_answer(ctx.host)
    return h


sc("X5", "tcp", "Each answer delayed 3.5 s (just under 4 s timeout)", "online", http=slow(3.5))
sc("X6", "tcp", "Each answer delayed 4.5 s (just over timeout)", "offline", http=slow(4.5),
   note="congested hotel Wi-Fi")


def slowloris(ctx):
    ctx.conn.sendall(b"HTTP/1.1 200 OK\r\n")
    while not ctx.sim.stop.wait(2.0):
        ctx.conn.sendall(b"X")
    return None


sc("X7", "tcp", "Slowloris: 1 byte every 2 s, forever", None, http=slowloris,
   note="must finish in bounded time")
sc("X8", "tcp", "RST after sending headers (mid-response)", "offline",
   http=lambda ctx: (ctx.conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 70\r\n"), "rst")[1])
sc("X9", "tcp", "Uplink not connected", "offline", uplink=(False, "", "", []))
sc("X10", "tcp", "Uplink connected but no DNS from DHCP", "offline", uplink=(True, "Hotel", "10.10.3.77", []))
sc("X11", "tcp", "DNS answer delayed 3.5 s (just under timeout)", "online",
   dns=lambda ctx: [(3.5, real_dns(ctx))])

# 11. unsafe / odd portal URLs
for sid, loc in (("U1", "javascript:alert(document.cookie)"), ("U2", "data:text/html,<script>alert(1)</script>"),
                 ("U3", "file:///etc/passwd"), ("U4", "http://portal.example/" + "a" * 3000),
                 ("U5", "  JavaScript:alert(1)"), ("U6", "\x01javascript:alert(1)"),
                 ("U7", "http://"), ("U8", "ftp://portal.example/login"),
                 ("U9", "http://[portal.example/login"), ("U10", "http://portal.example]/x")):
    sc(sid, "unsafe-url", f"302 Location: {loc[:48]!r}", "portal", url=APPLE_URL, http=redirect(302, loc))
sc("U11", "unsafe-url", "meta refresh to javascript:", "portal", url=APPLE_URL,
   http=page('<meta http-equiv="refresh" content="0; url=javascript:alert(1)">'))
sc("U12", "unsafe-url", "meta refresh to 'http://[' (invalid IPv6)", "portal", url=APPLE_URL,
   http=page('<meta http-equiv="refresh" content="0; url=http://[::1">'))
sc("U13", "unsafe-url", "JS location to 'https://[x'", "portal", url=APPLE_URL,
   http=page('<script>window.location="https://[x"</script>'))
sc("U14", "unsafe-url", "Location with HTML specials (http://p.example/\"><script>)", "portal",
   url=None, http=redirect(302, 'http://p.example/"><script>alert(1)</script>'),
   note="accepted; safe only because Jinja autoescapes href")

# 12. malformed DNS / HTTP
sc("M1", "malformed", "DNS reply truncated to 6 bytes", "offline", dns=lambda ctx: dns_reply(ctx.query, ["1.2.3.4"])[:6])
sc("M2", "malformed", "DNS reply is random garbage", "offline",
   dns=lambda ctx: random.Random(7).randbytes(60))
sc("M3", "malformed", "DNS reply with wrong ID only", "offline",
   dns=lambda ctx: dns_reply(ctx.query, [REAL_IP.get(ctx.qname, "1.1.1.1")], qid=struct.unpack(">H", ctx.query[:2])[0] ^ 0x5555))
sc("M4", "malformed", "Stray wrong-ID packet, then the real answer", "online",
   dns=lambda ctx: [(0, dns_reply(ctx.query, ["6.6.6.6"], qid=struct.unpack(">H", ctx.query[:2])[0] ^ 1)),
                    (0.05, real_dns(ctx))])
sc("M5", "malformed", "Compression pointer loop in question+answer names", None,
   dns=lambda ctx: ctx.query[:2] + struct.pack(">HHHHH", 0x8180, 1, 1, 0, 0) + b"\xc0\x0c\x00\x01\x00\x01"
   + a_rr("1.2.3.4", name=b"\xc0\x0c"),
   note="only needs: no crash, no hang")
sc("M6", "malformed", "Label length overruns packet", "offline",
   dns=lambda ctx: dns_reply(ctx.query, records=[b"\x3fabc"]))
sc("M7", "malformed", "ANCOUNT=65535 with one record", "offline",
   dns=lambda ctx: dns_reply(ctx.query, ["1.2.3.4"], an=65535))
sc("M8", "malformed", "A record rdlen=4 but packet cut after 2 bytes; 2nd DNS server fine", "online",
   dns=lambda ctx: dns_reply(ctx.query, ["1.2.3.4"])[:-2] if ctx.server == GW else real_dns(ctx),
   dns_servers=(GW, "10.10.0.2"))
sc("M9", "malformed", "DNS reflects the query back (QR=0, no answers)", "offline", dns=lambda ctx: ctx.query)
sc("M10", "malformed", "DNS TC=1 truncated, no answers", "offline",
   dns=lambda ctx: dns_reply(ctx.query, flags=0x8380))
sc("M11", "malformed", "HTTP: no status line, just 'Success'", "offline", http=lambda c: b"Success\r\n")
sc("M12", "malformed", "HTTP: binary junk", "offline", http=lambda c: random.Random(3).randbytes(3000))
sc("M13", "malformed", "HTTP: 100 KB header then body", None,
   http=lambda c: b"HTTP/1.1 200 OK\r\nX-Junk: " + b"A" * 100000 + b"\r\n\r\n" + APPLE_BODY)
sc("M14", "malformed", "HTTP: header lines without colon / high bytes", "online",
   http=lambda ctx: real_answer(ctx.host).replace(b"Connection: close", b"garbage line \xff\xfe\r\n:\r\nConnection: close"))
sc("M15", "malformed", "HTTP: server closes without sending anything", "offline", http=lambda c: b"")


def endless(ctx):
    ctx.conn.sendall(b"HTTP/1.1 200 OK\r\n\r\n")
    while not ctx.sim.stop.is_set():
        ctx.conn.sendall(b"Z" * 8192)
    return None


sc("M16", "malformed", "HTTP: endless body stream", None, http=endless)
sc("M17", "malformed", "HTTP: status '200' with Location of 10 KB", "online",
   http=lambda ctx: real_answer(ctx.host).replace(b"Connection: close", b"Location: " + b"x" * 10000 + b"\r\nConnection: close"))

# 13. login state changes
sc("L1", "login", "Post-login: portal DNS/gateway now passes real answers", "online", dns=real_dns)


def first_request_only(ctx):
    st = ctx.state
    with ctx.sim.lock:
        first = not st.get("seen")
        st["seen"] = True
    return redirect()(ctx) if first else real_http(ctx)


sc("L2", "login", "Splash intercepts only the very first request, then open (2 runs)",
   [("portal", "online"), "online"], http=first_request_only, runs=2)
sc("L3", "login", "Run 1 portal (302), user logs in, run 2 online", ["portal", "online"],
   http=lambda ctx: redirect()(ctx) if ctx.run == 0 else real_http(ctx), runs=2)
sc("L4", "login", "Run 1 online, session expires, run 2 portal", ["online", "portal"],
   http=lambda ctx: real_http(ctx) if ctx.run == 0 else redirect()(ctx), runs=2)


# --- runner ------------------------------------------------------------------

def run_scenario(sc_):
    mod = load_check(sc_.id)
    sim = Sim(sc_, mod)
    sim.patch()
    res = {"id": sc_.id, "group": sc_.group, "desc": sc_.desc, "note": sc_.note, "runs": []}
    box = {}

    def worker():
        for i in range(sc_.runs):
            sim.run_idx = i
            t0 = time.monotonic()
            try:
                out = mod.check()
                box.setdefault("runs", []).append({"out": out, "secs": time.monotonic() - t0})
            except Exception as e:
                box.setdefault("runs", []).append({"crash": f"{type(e).__name__}: {e}",
                                                    "tb": traceback.format_exc(), "secs": time.monotonic() - t0})
                return

    t = threading.Thread(target=worker, daemon=True)
    t0 = time.monotonic()
    t.start()
    t.join(HANG_LIMIT * sc_.runs)
    hung = t.is_alive()
    sim.close()
    if hung:
        t.join(10)
    res["hung"] = hung
    res["secs"] = round(time.monotonic() - t0, 1)
    problems = []
    for i in range(sc_.runs):
        exp = sc_.expect[i]
        runs = box.get("runs", [])
        if i >= len(runs):
            res["runs"].append({"state": "HUNG" if hung else "-", "portal_url": None})
            problems.append("HANG" if hung else "CRASH")
            break
        r = runs[i]
        if hung and i == len(runs) - 1:
            # finished only because the harness tore the fake servers down
            res["runs"].append({"state": "HUNG", "portal_url": None,
                                "after_teardown": r.get("out", {}).get("state")})
            problems.append("HANG")
            break
        if "crash" in r:
            res["runs"].append({"state": "CRASH", "portal_url": None, "crash": r["crash"], "tb": r["tb"]})
            problems.append("CRASH")
            break
        out = r["out"]
        rr = {"state": out["state"], "portal_url": out["portal_url"], "secs": round(r["secs"], 1),
              "probes": [(p["name"], p["result"], p.get("status"), p.get("detail"), p.get("portal_url"))
                         for p in out["probes"]]}
        res["runs"].append(rr)
        ok_states = exp if isinstance(exp, tuple) else (exp,)
        if exp is not None and out["state"] not in ok_states:
            problems.append("VERDICT")
        elif (sc_.url is not None and out["state"] == "portal" and i == 0 and exp == "portal"
              and out["portal_url"] != sc_.url):
            problems.append("URL")
        pu = out["portal_url"]
        if pu is not None:
            u = urlsplit(pu)
            if u.scheme not in ("http", "https") or not u.hostname or len(pu) > 2000:
                problems.append("UNSAFE-URL")
        for p in out["probes"]:
            ppu = p.get("portal_url")
            if ppu and urlsplit(ppu).scheme not in ("http", "https"):
                problems.append("UNSAFE-URL")
        if r["secs"] > SLOW_LIMIT:
            problems.append("SLOW")
    res["problems"] = sorted(set(problems))
    res["status"] = "PASS" if not res["problems"] else ("WARN" if set(res["problems"]) <= {"SLOW", "URL"} else "FAIL")
    return res


# uplink_info(): which NetworkManager device states count as "probe now".
# (state line, IPv4 address line, expected connected)
UPLINK_STATES = [
    ("100 (connected)", "10.10.3.77/22", True),
    ("100 (connected)", "", True),                 # activated: probe (fails -> offline) even without IPv4
    ("70 (connecting (getting IP configuration))", "", False),
    ("70 (connecting (getting IP configuration))", "10.10.3.77/22", True),   # IPv4 up, waiting for IPv6
    ("80 (connecting (checking IP connectivity))", "10.10.3.77/22", True),
    ("50 (connecting (configuring))", "", False),
    ("30 (disconnected)", "", False),
    ("", "", False),
]


def uplink_state_checks():
    """Unit checks for uplink_info()'s NM state handling; returns failures."""
    fails = []
    for state, addr, want in UPLINK_STATES:
        mod = load_check("uplink")

        def fake_run(*cmd, state=state, addr=addr):
            if "GENERAL.STATE" in cmd:
                return state
            if "IP4.ADDRESS" in cmd:
                return addr
            return ""
        mod.run = fake_run
        got = mod.uplink_info()[0]
        print(f"U     {'PASS' if got == want else 'FAIL':6} uplink_info({state!r}, ipv4={addr!r}) -> connected={got}")
        if got != want:
            fails.append(state)
    return fails


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-k", help="only these scenarios: ids (exact) or words in group/description; space/comma separated")
    ap.add_argument("-j", type=int, default=24, help="parallel scenarios (default 24)")
    ap.add_argument("-v", action="store_true", help="show per-probe details")
    ap.add_argument("--json", help="write full results to this file")
    ap.add_argument("--check", help="mariner-check file to test (default: bin/mariner-check of this repo)")
    args = ap.parse_args()
    if args.check:
        global CHECK_PATH
        CHECK_PATH = Path(args.check).resolve()
    terms = [t.lower() for t in (args.k or "").replace(",", " ").split()]
    todo = [s for s in S if not terms or any(t == s.id.lower() or t in f"{s.group} {s.desc}".lower() for t in terms)]
    t0 = time.monotonic()
    with ThreadPoolExecutor(max_workers=max(1, args.j)) as ex:
        results = list(ex.map(run_scenario, todo))
    print(f"{'ID':5} {'STATUS':6} {'EXPECT':16} {'ACTUAL':16} {'SECS':>5}  {'PROBLEMS':18} DESCRIPTION / portal_url")
    for r, s in zip(results, todo):
        exp = "/".join("|".join(e) if isinstance(e, tuple) else (e or "any") for e in s.expect)
        act = "/".join(x["state"] for x in r["runs"])
        print(f"{r['id']:5} {r['status']:6} {exp:16} {act:16} {r['secs']:5.1f}  {','.join(r['problems']) or '-':18} {r['desc']}")
        for x in r["runs"]:
            if x.get("portal_url"):
                pu = x["portal_url"]
                print(f"{'':52}-> portal_url {pu[:90]}{'...' if len(pu) > 90 else ''}")
            if x.get("crash"):
                print(f"{'':52}!! {x['crash']}")
        if args.v:
            for x in r["runs"]:
                for p in x.get("probes", []):
                    print(f"{'':52}   {p}")
    ufails = uplink_state_checks() if not terms else []
    n = {k: sum(r["status"] == k for r in results) for k in ("PASS", "WARN", "FAIL")}
    n["FAIL"] += len(ufails)
    print(f"\n{len(results)} scenarios: {n['PASS']} pass, {n['WARN']} warn (url/slow), {n['FAIL']} fail "
          f"[{time.monotonic() - t0:.0f}s wall]")
    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(results, f, indent=1, default=str)
    sys.exit(1 if n["FAIL"] else 0)


if __name__ == "__main__":
    main()
