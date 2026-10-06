/* Safari App Extension world. Shared DOM context links it to the independent probe. */
(() => {
  "use strict";
  if (window !== window.top) return;
  const attribute = "data-siftx-page-context";
  const eventName = "siftx-page-context-changed";
  let previousURL = location.href;
  function newPageToken() {
    if (typeof crypto.randomUUID === "function") return crypto.randomUUID();
    const bytes = new Uint8Array(16);
    crypto.getRandomValues(bytes);
    bytes[6] = (bytes[6] & 15) | 64; bytes[8] = (bytes[8] & 63) | 128;
    const hex = [...bytes].map(value => value.toString(16).padStart(2, "0")).join("");
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  }
  function context() {
    if (!document.documentElement) return null;
    let value;
    try { value = JSON.parse(document.documentElement.getAttribute(attribute)); } catch (_) {}
    if (!value || !/^[a-f0-9-]{36}$/i.test(value.id || "") || value.url !== location.href) {
      value = { id: newPageToken(), url: location.href };
      document.documentElement.setAttribute(attribute, JSON.stringify(value));
      document.dispatchEvent(new CustomEvent(eventName));
    }
    return value;
  }
  function announce(requestID) {
    const value = context();
    if (!value) { setTimeout(() => announce(requestID), 20); return; }
    safari.extension.dispatchMessage("siftx.context", { sessionID: value.id, pageURL: location.href, title: document.title.slice(0, 500), requestID: requestID || "" });
  }
  safari.self.addEventListener("message", event => {
    if (event.name === "siftx.queryContext") announce(event.message?.requestID);
    if (event.name === "siftx.refresh") {
      document.dispatchEvent(new CustomEvent(eventName));
      document.dispatchEvent(new CustomEvent("siftx-refresh-media"));
      announce();
    }
  });
  document.addEventListener(eventName, () => announce());
  document.addEventListener("siftx-media-updated", () => announce());
  document.addEventListener("siftx-show-popover", () => {
    safari.extension.dispatchMessage("siftx.showPopover");
    document.dispatchEvent(new CustomEvent("siftx-popover-accepted"));
  });
  window.addEventListener("pageshow", () => announce());
  setInterval(() => {
    if (location.href !== previousURL) { previousURL = location.href; announce(); }
  }, 750);
  announce();
})();
