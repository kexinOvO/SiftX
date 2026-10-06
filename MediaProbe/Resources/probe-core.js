/* Shared pure probe rules. No page history or credentials are stored here. */
(function (root) {
  "use strict";
  const maximumURLLength = 16384;
  function newPageToken(provider = root.crypto) {
    if (typeof provider.randomUUID === "function") return provider.randomUUID();
    // randomUUID is HTTPS-only; getRandomValues also works on ordinary HTTP pages.
    const bytes = new Uint8Array(16);
    provider.getRandomValues(bytes);
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    const hex = [...bytes].map(value => value.toString(16).padStart(2, "0")).join("");
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  }
  function validHTTPURL(value, base) {
    if (typeof value !== "string" || !value || value.length > maximumURLLength) return null;
    try {
      const url = new URL(value, base);
      if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) return null;
      url.hash = "";
      return url.href;
    } catch (_) { return null; }
  }
  function classify(value, mime = "", explicit = false, kind = "video") {
    const url = validHTTPURL(value);
    if (!url) return null;
    const path = new URL(url).pathname.toLowerCase();
    const type = String(mime).split(";")[0].trim().toLowerCase();
    if (/\.(m4s|cmfa|cmfv|ts|vtt|srt|key)$/.test(path) || ["video/mp2t", "video/iso.segment", "audio/iso.segment"].includes(type)) return null;
    const segment = /(?:^|[\/_.-])(?:seg(?:ment)?|chunk|frag(?:ment)?|init)(?:[\/_.-]|\d)/.test(path);
    if (segment && !explicit) return null;
    if (/\.m3u8$/.test(path) || ["application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl"].includes(type)) return { transport: "hls", kind: "video" };
    if (/\.mpd$/.test(path) || type === "application/dash+xml") return { transport: "dash", kind: "video" };
    if (/\.(mp4|mov|webm|m4v|ogv)$/.test(path) || type.startsWith("video/")) return { transport: "direct", kind: "video" };
    if (/\.(m4a|aac|mp3|wav|ogg|oga|flac|aiff|aif)$/.test(path) || type.startsWith("audio/")) return { transport: "direct", kind: "audio" };
    return explicit ? { transport: "direct", kind: kind === "audio" ? "audio" : "video" } : null;
  }
  function normalizeResource(raw) {
    if (!raw || typeof raw !== "object") return null;
    const url = validHTTPURL(raw.url);
    const classification = classify(url, raw.mime, raw.explicit === true, raw.kind);
    if (!classification) return null;
    const dimension = value => Number.isInteger(value) && value > 0 && value <= 32768 ? value : undefined;
    const bytes = Number.isSafeInteger(raw.bytes) && raw.bytes > 0 ? raw.bytes : undefined;
    const result = {
      url, ...classification, mime: String(raw.mime || "").slice(0, 128),
      title: raw.title ? String(raw.title).slice(0, 500) : undefined,
      width: dimension(raw.width), height: dimension(raw.height), bytes,
      explicit: raw.explicit === true, protected: raw.protected === true,
      thumbnail: validHTTPURL(raw.thumbnail) || undefined
    };
    for (const key of Object.keys(result)) if (result[key] === undefined) delete result[key];
    return result;
  }
  function mergeResources(existing, additions, limit = 64) {
    const map = new Map(existing.map(item => [item.url, item]));
    for (const raw of additions) {
      const item = normalizeResource(raw);
      if (item) {
        const previous = map.get(item.url);
        map.set(item.url, { ...previous, ...item, explicit: item.explicit || previous?.explicit || false, protected: item.protected || previous?.protected || false });
      }
    }
    const items = [...map.values()];
    const manifests = items.filter(item => item.transport !== "direct");
    // A playlist's AAC and numbered MP4 fragments are not standalone quality choices.
    const selected = manifests.length ? items.filter(item => item.transport !== "direct" || item.explicit || !(/\.aac(?:\?|$)/i.test(item.url) || /\/(?:\d{1,12}|(?:audio|video)[_.-]?\d{1,12})(?:[_-]\d+)?\.(?:mp4|m4a)(?:\?|$)/i.test(item.url))) : items;
    return selected.sort((a, b) => Number(b.transport !== "direct") - Number(a.transport !== "direct")).slice(0, limit);
  }
  function validToken(value) { return typeof value === "string" && /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i.test(value); }
  const api = { newPageToken, validHTTPURL, classify, normalizeResource, mergeResources, validToken };
  root.SiftXProbeCore = api;
  if (typeof module === "object" && module.exports) module.exports = api;
})(typeof globalThis === "object" ? globalThis : this);
