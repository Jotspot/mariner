// Mariner portal: progressive enhancement. Without JavaScript every link and
// form still works with full page loads; with it:
//   - tab switches fetch the page and swap <main> (no reload, no white flash)
//   - elements marked data-live="id" refresh themselves every few seconds
//     (every second for a while after an action) without touching forms
//   - forms submit in the background; switches flip immediately
//   - messages appear as toasts
(function () {
  "use strict";
  var HDR = { "X-Mariner": "1" };
  var fastUntil = 0;
  var busy = false;         // a navigation or form submit is in flight
  var liveTimer = null;

  function parse(html) { return new DOMParser().parseFromString(html, "text/html"); }

  // --- toasts ----------------------------------------------------------------
  function toast(text, isError) {
    if (!text) return;
    var box = document.getElementById("toasts");
    if (!box) {
      box = document.createElement("div");
      box.id = "toasts";
      box.setAttribute("aria-live", "polite");
      document.body.appendChild(box);
    }
    var t = document.createElement("div");
    t.className = "toast" + (isError ? " error" : "");
    t.setAttribute("role", isError ? "alert" : "status");
    t.textContent = text;
    box.appendChild(t);
    setTimeout(function () { t.classList.add("out"); }, isError ? 7000 : 3500);
    setTimeout(function () { t.remove(); }, isError ? 7400 : 3900);
  }

  // Server-rendered snackbars (from ?m= / ?e= or background notices) -> toasts.
  function liftSnackbars(root) {
    root.querySelectorAll("main > .snackbar").forEach(function (s) {
      toast(s.textContent.trim(), s.classList.contains("error"));
      s.remove();
    });
  }

  // One-shot URL parameters (messages, "scan now") must not repeat when the
  // page refreshes itself or the user reloads.
  function cleanUrl() {
    var u = new URL(location.href), changed = false;
    ["m", "e", "scan"].forEach(function (k) {
      if (u.searchParams.has(k)) { u.searchParams.delete(k); changed = true; }
    });
    if (changed) history.replaceState(history.state, "", u.pathname + (u.search || "") + u.hash);
  }

  // --- progress bar ------------------------------------------------------------
  var barTimer = null;
  function loading(on) {
    clearTimeout(barTimer);
    if (on) {
      barTimer = setTimeout(function () { document.documentElement.classList.add("loading"); }, 120);
    } else {
      document.documentElement.classList.remove("loading");
    }
  }

  // --- page swap -----------------------------------------------------------------
  function swapPage(doc, url, push) {
    var main = doc.querySelector("main"), nav = doc.querySelector(".nav-bar"), bar = doc.querySelector(".top-bar");
    if (!main || !nav || !bar) {  // not a normal page (login, reboot, ...): do a real load
      location.href = url;
      return;
    }
    document.title = doc.title;
    document.querySelector("main").replaceWith(document.adoptNode(main));
    document.querySelector(".nav-bar").replaceWith(document.adoptNode(nav));
    document.querySelector(".top-bar").replaceWith(document.adoptNode(bar));
    if (push) history.pushState({}, "", url);
    liftSnackbars(document);
    cleanUrl();
  }

  function navigate(url, opts) {
    opts = opts || {};
    busy = true;
    loading(true);
    var y = window.scrollY;
    return fetch(url, { headers: HDR, credentials: "same-origin" })
      .then(function (r) {
        if (r.status === 401 || r.redirected && /\/(login|setup)$/.test(new URL(r.url).pathname)) {
          location.href = "/login";
          throw new Error("signed out");
        }
        return r.text().then(function (html) { return [html, r.url]; });
      })
      .then(function (res) {
        swapPage(parse(res[0]), opts.push === false ? location.href : res[1], opts.push !== false);
        window.scrollTo(0, opts.keepScroll ? y : 0);
      })
      .catch(function (e) { if (e.message !== "signed out") location.href = url; })
      .then(function () { busy = false; loading(false); schedule(); });
  }

  document.addEventListener("click", function (ev) {
    var a = ev.target.closest("a[href]");
    if (!a || ev.defaultPrevented || ev.button !== 0 || ev.metaKey || ev.ctrlKey || ev.shiftKey || ev.altKey) return;
    if (a.target || a.hasAttribute("download") || a.dataset.reload !== undefined) return;
    var url = new URL(a.href, location.href);
    if (url.origin !== location.origin || url.pathname.indexOf("/static/") === 0) return;
    if (url.pathname === location.pathname && url.search === location.search && url.hash) return;
    ev.preventDefault();
    navigate(url.href, { push: true });
  });

  window.addEventListener("popstate", function () { navigate(location.href, { push: false }); });

  // --- live regions --------------------------------------------------------------
  function interacting(el) {
    var f = document.activeElement;
    return f && el.contains(f) && /^(INPUT|SELECT|TEXTAREA)$/.test(f.tagName);
  }

  function refreshLive() {
    if (busy || document.hidden || !document.querySelector("[data-live]")) return schedule();
    fetch(location.href, { headers: HDR, credentials: "same-origin" })
      .then(function (r) {
        if (r.status === 401) { location.href = "/login"; throw new Error("signed out"); }
        return r.text();
      })
      .then(function (html) {
        if (busy) return;
        var doc = parse(html);
        doc.querySelectorAll("[data-live]").forEach(function (fresh) {
          var cur = document.querySelector('[data-live="' + fresh.dataset.live + '"]');
          if (!cur || interacting(cur) || cur.outerHTML === fresh.outerHTML) return;
          // keep <details> the user opened inside this region open
          var open = {};
          cur.querySelectorAll("details[data-key][open]").forEach(function (d) { open[d.dataset.key] = 1; });
          fresh.querySelectorAll("details[data-key]").forEach(function (d) { if (open[d.dataset.key]) d.open = true; });
          cur.replaceWith(document.adoptNode(fresh));
        });
        var main = doc.querySelector("main");
        if (main) liftSnackbars(doc);
      })
      .catch(function () {})
      .then(schedule);
  }

  function schedule() {
    clearTimeout(liveTimer);
    liveTimer = setTimeout(refreshLive, Date.now() < fastUntil ? 1000 : 3000);
  }

  document.addEventListener("visibilitychange", function () { if (!document.hidden) refreshLive(); });

  // --- forms --------------------------------------------------------------------
  document.addEventListener("submit", function (ev) {
    var form = ev.target;
    var msg = form.getAttribute("data-confirm");
    if (msg && !window.confirm(msg)) { ev.preventDefault(); return; }
    if (form.method.toLowerCase() !== "post" || form.hasAttribute("data-full")) return busyButton(form);
    ev.preventDefault();

    var submitter = ev.submitter;
    var data = new FormData(form);
    if (submitter && submitter.name) data.append(submitter.name, submitter.value);

    // Optimistic switch: flip it now, pulse until the router confirms.
    var sw = form.querySelector(".switch") || (submitter && submitter.classList.contains("switch") ? submitter : null);
    if (sw) {
      sw.classList.toggle("on");
      sw.setAttribute("aria-checked", sw.classList.contains("on") ? "true" : "false");
      sw.classList.add("pending");
    }
    if (submitter && submitter.classList.contains("seg")) {
      form.querySelectorAll(".seg").forEach(function (b) { b.classList.toggle("on", b === submitter); });
    }
    var restore = busyButton(form, submitter);
    busy = true;
    loading(true);
    fetch(form.action, { method: "POST", body: data, headers: HDR, credentials: "same-origin" })
      .then(function (r) {
        var type = r.headers.get("content-type") || "";
        if (type.indexOf("application/json") !== -1) {
          return r.json().then(function (j) {
            if (!r.ok && j && j.detail && !j.err) j = { err: String(j.detail), location: location.pathname };
            return { json: j };
          });
        }
        if (!r.ok) return r.text().then(function (t) {
          return { json: { err: (t || "Something went wrong (" + r.status + ").").slice(0, 200), location: location.pathname } };
        });
        return r.text().then(function (html) { return { html: html }; });
      })
      .then(function (res) {
        busy = false;
        loading(false);
        fastUntil = Date.now() + 30000;
        if (res.html !== undefined) {  // e.g. "Rebooting…" page
          var doc = parse(res.html);
          document.title = doc.title;
          document.body.replaceWith(document.adoptNode(doc.body));
          return;
        }
        var j = res.json;
        if (j.reload) { location.href = j.location || "/"; return; }
        toast(j.err, true);
        toast(j.msg, false);
        var dest = j.location || location.pathname;
        var same = dest === location.pathname;
        return navigate(dest + (same ? location.search.replace(/[?&](m|e)=[^&]*/g, "") : ""),
                        { push: !same, keepScroll: same });
      })
      .catch(function () {
        busy = false;
        loading(false);
        if (sw) { sw.classList.toggle("on"); sw.classList.remove("pending"); }
        restore();
        toast("Couldn't reach Mariner. Check you're still on its Wi-Fi.", true);
      });
  });

  // Show a busy label on the clicked (or data-busy) button; returns an undo fn.
  function busyButton(form, submitter) {
    var btn = (submitter && submitter.hasAttribute("data-busy")) ? submitter : form.querySelector("button[data-busy]");
    if (!btn) return function () {};
    var label = btn.innerHTML;
    btn.disabled = true;
    btn.textContent = btn.getAttribute("data-busy");
    return function () { btn.disabled = false; btn.innerHTML = label; };
  }

  liftSnackbars(document);
  cleanUrl();
  schedule();
})();
