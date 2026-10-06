/* Safari Web Extension: bounded observations and a click relay to the native UI. */
"use strict";
const core = SiftXProbeCore;
const pages = new Map();
const pendingRequests = new Map();
const nativeQueues = new Map();
const requestContexts = new Map();
const MAX_PAGES = 200;
const NATIVE_HEARTBEAT_MS = 60000;

async function nativeMessage(message) {
  try { return await browser.runtime.sendNativeMessage("com.siftx.SiftX", message); }
  catch (_) { return { ok: false, error: "native-unavailable" }; }
}
browser.browserAction.onClicked.addListener(async tab => {
  try {
    const result = await browser.tabs.sendMessage(tab.id, { type: "show-popover" }, { frameId: 0 });
    if (result?.ok) return;
  } catch (_) {}
  // A restricted page may not have either content script. Still give the click
  // a useful response by opening the containing app's download window.
  await nativeMessage({ type: "open-app" });
});
function queueNative(page, forceReanalysis = false) {
  page.forceReanalysis = page.forceReanalysis === true || forceReanalysis;
  clearTimeout(page.timer);
  page.timer = setTimeout(() => {
    const previous = nativeQueues.get(page.id) || Promise.resolve();
    const operation = previous.catch(() => {}).then(async () => {
      if (pages.get(page.tabID) !== page) return;
      const message = { type: "upsert", sessionID: page.id, pageURL: page.url, title: page.title, privateBrowsing: page.privateBrowsing, resources: page.resources, notices: [...page.notices].sort() };
      const signature = JSON.stringify(message);
      const changed = signature !== page.lastNativeSignature;
      const forced = page.forceReanalysis === true;
      page.forceReanalysis = false;
      // Keep the native store alive without rescanning or invalidating the toolbar
      // for every identical DOM/network observation or recovery announcement.
      if (!forced && !changed && Date.now() - page.lastNativeAt < NATIVE_HEARTBEAT_MS) return;
      if (forced) message.forceReanalysis = true;
      const reply = await nativeMessage(message);
      if (!reply?.ok || pages.get(page.tabID) !== page) { page.forceReanalysis ||= forced; return; }
      const countChanged = Number.isInteger(reply.count) && reply.count !== page.lastNativeCount;
      page.lastNativeSignature = signature;
      page.lastNativeAt = Date.now();
      page.lastNativeCount = reply.count;
      if (changed || countChanged) {
        try { await browser.tabs.sendMessage(page.tabID, { type: "media-updated", sessionID: page.id }, { frameId: 0 }); } catch (_) {}
      }
    });
    nativeQueues.set(page.id, operation);
    operation.finally(() => { if (nativeQueues.get(page.id) === operation) nativeQueues.delete(page.id); });
  }, 250);
}
function removePage(tabID) {
  const page = pages.get(tabID);
  if (!page) return;
  clearTimeout(page.timer);
  pages.delete(tabID);
  const previous = nativeQueues.get(page.id) || Promise.resolve();
  previous.catch(() => {}).then(() => nativeMessage({ type: "remove", sessionID: page.id }));
}
function addResources(page, raw) {
  page.resources = core.mergeResources(page.resources, raw);
  page.seenAt = Date.now();
  queueNative(page);
}
function trackPending(tabID, resource) {
  const pending = pendingRequests.get(tabID) || { createdAt: Date.now(), resources: [] };
  pending.resources = core.mergeResources(pending.resources, [resource]);
  pendingRequests.set(tabID, pending);
  if (pendingRequests.size > MAX_PAGES) pendingRequests.delete(pendingRequests.keys().next().value);
}
browser.runtime.onMessage.addListener((message, sender) => {
  if (!sender.tab || !Number.isInteger(sender.tab.id) || !message || typeof message !== "object") return;
  const tabID = sender.tab.id;
  if (message.type === "page" && sender.frameId === 0 && core.validToken(message.sessionID)) {
    const url = core.validHTTPURL(message.pageURL);
    // The browser-provided sender URL is the authority, not a script-supplied hostname.
    if (!url || !core.validHTTPURL(sender.url) || new URL(sender.url).origin !== new URL(url).origin) return;
    let page = pages.get(tabID);
    if (!page || page.id !== message.sessionID) {
      removePage(tabID);
      page = { id: message.sessionID, tabID, url, title: "", resources: [], notices: new Set(), frames: new Map(), seenAt: Date.now(), privateBrowsing: sender.tab.incognito === true };
      pages.set(tabID, page);
      const pending = pendingRequests.get(tabID);
      if (pending && Date.now() - pending.createdAt < 15000) page.resources = pending.resources;
      pendingRequests.delete(tabID);
    }
    page.url = url;
    page.seenAt = Date.now();
    page.title = String(message.title || "").slice(0, 500);
    page.frames.set(0, message.sessionID);
    queueNative(page);
    if (pages.size > MAX_PAGES) removePage(pages.keys().next().value);
    return Promise.resolve({ sessionID: page.id });
  }
  const page = pages.get(tabID);
  if (!page) return Promise.resolve({ sessionID: null });
  if (message.type === "refresh" && sender.frameId === 0 && message.sessionID === page.id) {
    queueNative(page, true);
    return Promise.resolve({ ok: true });
  }
  if (message.type === "frame" && core.validToken(message.documentID)) {
    page.frames.set(sender.frameId, message.documentID);
    if (page.frames.size > 128) {
      const oldest = [...page.frames.keys()].find(id => id !== 0);
      if (oldest !== undefined) page.frames.delete(oldest);
    }
    return Promise.resolve({ sessionID: page.id });
  }
  if (message.type === "resources") {
    if (sender.frameId === 0 && message.sessionID !== page.id) return;
    if (sender.frameId !== 0 && page.frames.get(sender.frameId) !== message.documentID) return;
    if (Array.isArray(message.resources)) addResources(page, message.resources.slice(0, 64));
    if (Array.isArray(message.notices)) {
      for (const notice of message.notices) if (["blob", "protected"].includes(notice)) page.notices.add(notice);
      queueNative(page);
    }
    return Promise.resolve({ ok: true });
  }
  if (message.type === "leave" && sender.frameId === 0 && message.sessionID === page.id) {
    removePage(tabID);
    return Promise.resolve({ ok: true });
  }
});

browser.webRequest.onBeforeRequest.addListener(details => {
  if (details.tabId < 0) return;
  requestContexts.set(details.requestId, { sessionID: details.type === "main_frame" ? null : pages.get(details.tabId)?.id, createdAt: Date.now() });
  if (requestContexts.size > 2048) requestContexts.delete(requestContexts.keys().next().value);
}, { urls: ["http://*/*", "https://*/*"] });
browser.webRequest.onHeadersReceived.addListener(details => {
  if (!Number.isInteger(details.tabId) || details.tabId < 0) return;
  const headers = details.responseHeaders || [];
  const header = name => headers.find(item => item.name.toLowerCase() === name)?.value || "";
  const range = /bytes\s+\d+-\d+\/(\d+)/i.exec(header("content-range"));
  const length = range ? Number(range[1]) : details.statusCode === 206 ? undefined : Number(header("content-length")) || undefined;
  const resource = core.normalizeResource({ url: details.url, mime: header("content-type"), bytes: length });
  if (!resource) return;
  const page = pages.get(details.tabId);
  const requestContext = requestContexts.get(details.requestId);
  if (page && requestContext?.sessionID && requestContext.sessionID !== page.id) return;
  if (page) addResources(page, [resource]);
  else trackPending(details.tabId, resource);
}, { urls: ["http://*/*", "https://*/*"] }, ["responseHeaders"]);
for (const event of [browser.webRequest.onCompleted, browser.webRequest.onErrorOccurred]) {
  event.addListener(details => requestContexts.delete(details.requestId), { urls: ["http://*/*", "https://*/*"] });
}

browser.tabs.onRemoved.addListener(tabID => { removePage(tabID); pendingRequests.delete(tabID); });
browser.tabs.onUpdated.addListener((tabID, change) => {
  if (change.status === "loading") { removePage(tabID); pendingRequests.delete(tabID); }
});
setInterval(() => {
  const now = Date.now();
  for (const [tabID, pending] of pendingRequests) if (now - pending.createdAt > 15000) pendingRequests.delete(tabID);
  for (const [id, request] of requestContexts) if (now - request.createdAt > 60000) requestContexts.delete(id);
  for (const [tabID, page] of pages) if (now - page.seenAt > 6 * 60 * 60 * 1000) removePage(tabID);
  nativeMessage({ type: "prune" });
}, 60000);
