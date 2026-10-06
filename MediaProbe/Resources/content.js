/* DOM and Performance observer. The page token is context, never an authorization secret. */
(() => {
  "use strict";
  const core = SiftXProbeCore;
  const topFrame = window === window.top;
  const attribute = "data-siftx-page-context";
  const contextEvent = "siftx-page-context-changed";
  const documentID = core.newPageToken();
  let sessionID = null;
  let previousURL = location.href;
  let batchTimer;
  let scanTimer;
  let lastAnnouncement = "";
  let alive = true;
  const seen = new Map();
  const notices = new Set();
  const protectedElements = new WeakSet();
  const observedElements = new WeakSet();

  function pageContext() {
    if (!document.documentElement) return null;
    let context;
    try { context = JSON.parse(document.documentElement.getAttribute(attribute)); } catch (_) {}
    if (!context || !core.validToken(context.id) || context.url !== location.href) {
      context = { id: core.newPageToken(), url: location.href };
      document.documentElement.setAttribute(attribute, JSON.stringify(context));
      document.dispatchEvent(new CustomEvent(contextEvent));
    }
    return context;
  }
  async function announce(force = false) {
    if (!alive) return;
    if (topFrame) {
      const context = pageContext();
      if (!context) return;
      if (sessionID !== context.id) { sessionID = context.id; seen.clear(); notices.clear(); }
      const signature = sessionID + "|" + document.title;
      if (!force && signature === lastAnnouncement) return;
      try {
        const reply = await browser.runtime.sendMessage({ type: "page", sessionID, pageURL: location.href, title: document.title });
        lastAnnouncement = reply?.sessionID === sessionID ? signature : "";
      } catch (_) { lastAnnouncement = ""; }
    } else {
      try { sessionID = (await browser.runtime.sendMessage({ type: "frame", documentID }))?.sessionID || null; } catch (_) {}
    }
  }
  function record(raw) {
    if (typeof raw.url === "string" && raw.url.startsWith("blob:")) { notices.add("blob"); schedule(); return; }
    const item = core.normalizeResource(raw);
    if (!item) return;
    const previous = seen.get(item.url);
    const combined = { ...previous, ...item, protected: raw.protected === true || previous?.protected === true };
    if (JSON.stringify(previous) === JSON.stringify(combined)) return;
    seen.set(item.url, combined);
    if (seen.size > 64) seen.delete(seen.keys().next().value);
    schedule();
  }
  function inspect(element) {
    const audio = element.tagName === "AUDIO";
    const title = element.getAttribute("title") || element.getAttribute("aria-label") || document.title;
    const metadata = { title, kind: audio ? "audio" : "video", width: element.videoWidth, height: element.videoHeight, thumbnail: element.poster, protected: protectedElements.has(element), explicit: true };
    for (const source of [element.currentSrc, element.src]) if (source) record({ ...metadata, url: source, mime: audio ? "audio/unknown" : "video/unknown" });
    for (const source of element.querySelectorAll("source[src]")) record({ ...metadata, url: core.validHTTPURL(source.getAttribute("src"), document.baseURI), mime: source.type || (audio ? "audio/unknown" : "video/unknown") });
    if (!observedElements.has(element)) {
      observedElements.add(element);
      for (const name of ["loadedmetadata", "loadstart", "playing", "durationchange"]) element.addEventListener(name, () => inspect(element), { passive: true });
      element.addEventListener("encrypted", () => { protectedElements.add(element); notices.add("protected"); inspect(element); schedule(); }, { passive: true });
    }
  }
  function scan() { for (const element of document.querySelectorAll("video,audio")) inspect(element); }
  function schedule() {
    clearTimeout(batchTimer);
    batchTimer = setTimeout(flush, 150);
  }
  async function flush() {
    if (!alive || !sessionID) return;
    try {
      const message = { type: "resources", sessionID, documentID, resources: [...seen.values()], notices: [...notices] };
      const reply = await browser.runtime.sendMessage(message);
      if (topFrame && reply?.sessionID === null) {
        // Extension/background restarts lose their registry while the page keeps its token.
        await announce(true);
        await browser.runtime.sendMessage(message);
      }
    } catch (_) {}
  }
  async function updateContext() {
    if (location.href !== previousURL) {
      previousURL = location.href;
      // Both extension worlds atomically converge on the same document attribute.
      if (topFrame) pageContext();
      await announce();
      scan();
    }
  }
  const observer = new MutationObserver(() => {
    clearTimeout(scanTimer);
    scanTimer = setTimeout(() => { announce(); scan(); }, 100);
  });
  function start() {
    if (!document.documentElement) { setTimeout(start, 20); return; }
    observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ["src", "poster", attribute] });
    announce().then(() => { scan(); flush(); });
  }
  try {
    new PerformanceObserver(list => {
      for (const entry of list.getEntries()) record({ url: entry.name });
    }).observe({ type: "resource", buffered: true });
  } catch (_) {
    for (const entry of performance.getEntriesByType("resource")) record({ url: entry.name });
  }
  document.addEventListener(contextEvent, () => { announce(true).then(() => { scan(); flush(); }); });
  document.addEventListener("siftx-refresh-media", () => {
    announce(true).then(async () => {
      scan(); await flush();
      if (topFrame && sessionID) {
        try { await browser.runtime.sendMessage({ type: "refresh", sessionID }); } catch (_) {}
      }
    });
  });
  let popoverAccepted = false;
  document.addEventListener("siftx-popover-accepted", () => { popoverAccepted = true; });
  browser.runtime.onMessage.addListener(message => {
    if (topFrame && message?.type === "show-popover") {
      popoverAccepted = false;
      document.dispatchEvent(new CustomEvent("siftx-show-popover"));
      return Promise.resolve({ ok: popoverAccepted });
    }
    if (topFrame && message?.type === "media-updated" && message.sessionID === sessionID) document.dispatchEvent(new CustomEvent("siftx-media-updated"));
  });
  window.addEventListener("popstate", updateContext);
  window.addEventListener("hashchange", updateContext);
  window.addEventListener("pagehide", () => {
    alive = false;
    if (topFrame && sessionID) browser.runtime.sendMessage({ type: "leave", sessionID }).catch(() => {});
  });
  window.addEventListener("pageshow", () => { alive = true; announce(true).then(() => { scan(); flush(); }); });
  setInterval(updateContext, 750); // Detect isolated-world pushState/replaceState without page injection.
  setInterval(() => announce(true).then(flush), 20000); // Recover when an extension process restarts.
  start();
})();
