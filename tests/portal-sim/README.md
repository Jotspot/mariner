# portal-sim: offline tests for `mariner-check`

Runs the real classification code of `bin/mariner-check` against ~110
simulated networks (captive portals, DNS hijacks, filters, proxies, broken
servers) without touching `wlan0`, the Pi or the internet.

## Run

```
python tests/portal-sim/portal_sim.py                 # all scenarios (~45 s, scenarios run in parallel)
python tests/portal-sim/portal_sim.py -k "R1 W4 dns"  # ids (exact) or words in group/description
python tests/portal-sim/portal_sim.py -v              # per-probe result/status/detail
python tests/portal-sim/portal_sim.py --json out.json # full results incl. tracebacks
python tests/portal-sim/portal_sim.py --check path/to/other/mariner-check   # test a patched copy
```

Python 3.8+ (3.9+ for `random.randbytes`), stdlib only. Works on Windows, macOS
and Linux; on the Pi it needs no root and binds only to 127.0.0.1. Exit status
is 1 if any scenario FAILs.

## How it works

- `bin/mariner-check` is loaded as a module (a fresh copy per scenario, so
  scenarios run in parallel). On Windows a stub `fcntl` is injected (only
  `main()` uses it). `main()` is never called, so nothing writes `/run` or
  calls `mariner-ctl`.
- Patched: `uplink_info` (returns connected, SSID, IP and the scenario's DNS
  servers), `run` (no subprocesses) and `bound_socket` (a normal socket whose
  `connect()`/`sendto()` are redirected to per-IP fake HTTP/DNS listeners on
  127.0.0.1, and which can simulate connect timeouts/refusals).
- Not patched (under test): `resolve`, `_parse_reply`, `_skip_name`,
  `http_get`, `find_portal_url`, `_find_portal_url`, `probe`, `check`, and
  the real `TIMEOUT`.
- Each scenario supplies a DNS handler (reply bytes, delayed packets, or drop)
  and an HTTP handler (raw response bytes, `"rst"`, or it drives the socket
  itself for slow/endless/keep-alive servers). Fake servers see the
  destination IP the code connected to and the `Host` header.

## Reading the output

| Column   | Meaning |
|----------|---------|
| STATUS   | PASS; WARN = verdict right but `portal_url` not the real login URL, or slow; FAIL = wrong verdict, crash, hang or unsafe URL |
| EXPECT   | expected state (`a|b` = either accepted, `any` = only "no crash/hang", `x/y` = per run for multi-run scenarios) |
| PROBLEMS | VERDICT, URL, CRASH, HANG (> 45 s), SLOW (> 15 s), UNSAFE-URL (non-http(s) or > 2000 chars) |

Groups: `normal`, `redirect`, `page200`, `511`, `hijack`, `dns-fail`,
`walled` (walled gardens), `proxy`, `filter` (one probe domain blocked, should
stay online), `tcp` (resets/timeouts/slow), `unsafe-url`, `malformed`,
`login` (state changes across runs).

## Adding a scenario

```python
sc("R9", "redirect", "302 to portal on port 8080", "portal",
   url="http://10.0.0.1:8080/login",
   http=redirect(302, "http://10.0.0.1:8080/login"))
```

Helpers: `resp()`, `redirect()`, `page()`, `per_host(apple=, google=, ms=, other=)`,
`dns_reply()`, `hijack_all()`, `blackhole`, `real_dns`, `real_http`.

`suggested-fix.diff` is a patch for `bin/mariner-check` (not applied) with
which every scenario passes and the worst case drops to about 8 s; check it
with `--check` against a patched copy.
