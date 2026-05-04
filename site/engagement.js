/**
 * engagement.js — Minimal client-side engagement measurement
 *
 * Tracks page views, referrer, dwell time, scroll depth, and exit referrer.
 * Sends beacons to /api/engagement (server-side log). No cookies, no
 * cross-site tracking, no third-party dependency — fits the privacy-first
 * ethos of disinto.ai.
 *
 * The factory reads this data via collect-engagement.sh which parses the
 * server-side log alongside Caddy access logs. The gardener surfaces it
 * in its engagement report.
 *
 * Data sent per beacon:
 *   - event: "pageview" | "scroll" | "dwell" | "exit"
 *   - path: current page path
 *   - referrer: document.referrer
 *   - ts: epoch ms
 *   - dwell_seconds: time on page (for dwell/exit events)
 *   - scroll_pct: max scroll depth percentage (for scroll/exit events)
 *
 * Privacy: IP is stripped by the server endpoint (logged only as hash).
 * No user identifiers. No cross-site cookies.
 */
(function () {
  "use strict";

  var BASE_PATH = "/api/engagement";
  var MAX_SCROLL_TRACKING = 100; // track every 1%
  var DWELL_REPORT_MIN = 5; // only report dwell after N seconds
  var MAX_BEACONS = 10; // cap per-session beacons

  var state = {
    path: "",
    startTime: Date.now(),
    maxScroll: 0,
    beaconCount: 0,
    reported: false,
  };

  function getRelativePath() {
    var path = window.location.pathname;
    // Normalize: strip trailing slash, keep root as "/"
    if (path.length > 1 && path[path.length - 1] === "/") {
      path = path.slice(0, -1);
    }
    return path;
  }

  function calculateScrollPct() {
    var scrollTop = window.pageYOffset || document.documentElement.scrollTop;
    var docHeight =
      document.documentElement.scrollHeight -
      document.documentElement.clientHeight;
    if (docHeight <= 0) return 0;
    return Math.min(100, Math.round((scrollTop / docHeight) * 100));
  }

  function sendBeacon(event) {
    state.beaconCount++;
    if (state.beaconCount > MAX_BEACONS) return;

    var payload = {
      event: event,
      path: state.path,
      referrer: document.referrer || "direct",
      ts: Date.now(),
    };

    if (event === "dwell" || event === "exit") {
      payload.dwell_seconds = Math.round((Date.now() - state.startTime) / 1000);
    }

    if (event === "scroll" || event === "exit") {
      payload.scroll_pct = state.maxScroll;
    }

    // Use navigator.sendBeacon for reliable delivery on page unload.
    // Fall back to XHR for non-unload events.
    var json = JSON.stringify(payload);
    if (typeof navigator.sendBeacon === "function") {
      try {
        navigator.sendBeacon(
          BASE_PATH,
          new Blob([json], { type: "application/json" })
        );
        return;
      } catch (e) {
        // sendBeacon failed — fall through to XHR
      }
    }

    // XHR fallback (fire-and-forget)
    try {
      var xhr = new XMLHttpRequest();
      xhr.open("POST", BASE_PATH, true);
      xhr.setRequestHeader("Content-Type", "application/json");
      xhr.send(json);
    } catch (e) {
      // best effort — silently drop
    }
  }

  function onScroll() {
    var pct = calculateScrollPct();
    if (pct >= state.maxScroll + MAX_SCROLL_TRACKING) {
      state.maxScroll = pct;
      sendBeacon("scroll");
    }
  }

  function onPageHide() {
    var dwell = Math.round((Date.now() - state.startTime) / 1000);
    if (dwell >= DWELL_REPORT_MIN) {
      state.maxScroll = calculateScrollPct();
      sendBeacon("exit");
    }
  }

  function init() {
    state.path = getRelativePath();

    // Pageview beacon fires immediately
    sendBeacon("pageview");
    state.reported = true;

    // Scroll tracking
    window.addEventListener("scroll", onScroll, { passive: true });

    // Dwell time beacon on page hide (pagehide is more reliable than beforeunload)
    window.addEventListener("pagehide", onPageHide, { passive: true });

    // If the page is a back-navigation (bfcache restore), report dwell
    window.addEventListener("pageshow", function (e) {
      if (e.persisted) {
        // Page was restored from bfcache — report dwell from initial load
        var dwell = Math.round((Date.now() - state.startTime) / 1000);
        if (dwell >= DWELL_REPORT_MIN) {
          state.maxScroll = calculateScrollPct();
          sendBeacon("exit");
        }
      }
    });
  }

  // Run on DOM ready
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
