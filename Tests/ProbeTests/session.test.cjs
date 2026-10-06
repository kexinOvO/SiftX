const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const path = require("node:path");
const root = path.resolve(__dirname, "../..");
const ids = ["f742e374-ecb9-486d-af03-d44b118741bc", "ea99a710-1af7-4e36-882c-038885456864", "d8804420-1d12-4e1e-8296-360ae590b106"];

function background() {
  const messages = [], notifications = [], timers = new Set();
  let now = Date.now();
  class Clock extends Date { static now() { return now; } }
  const event = () => ({ addListener(fn) { this.listener = fn; } });
  const browser = {
    browserAction: { onClicked: event() },
    runtime: { onMessage: event(), sendNativeMessage: async (_, message) => { messages.push(structuredClone(message)); return { ok: true }; } },
    tabs: { onRemoved: event(), onUpdated: event(), sendMessage: async (...args) => { notifications.push(args); } },
    webRequest: { onBeforeRequest: event(), onHeadersReceived: event(), onCompleted: event(), onErrorOccurred: event() }
  };
  const context = vm.createContext({ browser, URL, Date: Clock, console, setTimeout: fn => { const timer = { fn }; timers.add(timer); return timer; }, clearTimeout: timer => timers.delete(timer), setInterval() {} });
  for (const file of ["probe-core.js", "background.js"]) vm.runInContext(fs.readFileSync(path.join(root, "MediaProbe/Resources", file), "utf8"), context);
  const sender = (tabID, frameId = 0, incognito = false) => ({ tab: { id: tabID, incognito }, frameId, url: "https://site.test/page" });
  return {
    messages, notifications, browser,
    advance(ms) { now += ms; },
    send(message, tabID = 1, frameId = 0, incognito = false) { return browser.runtime.onMessage.listener(message, sender(tabID, frameId, incognito)); },
    async flush() { for (const timer of [...timers]) { timers.delete(timer); timer.fn(); } for (let i = 0; i < 12; i++) await Promise.resolve(); }
  };
}

test("user refresh bypasses unchanged observation cache without repeating on later scans", async () => {
  const h = background();
  await h.send({ type: "page", sessionID: ids[0], pageURL: "https://site.test/page" });
  await h.send({ type: "resources", sessionID: ids[0], resources: [{ url: "https://media.test/index.m3u8" }], notices: [] });
  await h.flush();
  const before = h.messages.length;
  await h.send({ type: "refresh", sessionID: ids[0] });
  await h.flush();
  assert.equal(h.messages.length, before + 1);
  assert.equal(h.messages.at(-1).forceReanalysis, true);
  await h.send({ type: "resources", sessionID: ids[0], resources: [{ url: "https://media.test/index.m3u8" }], notices: [] });
  await h.flush();
  assert.equal(h.messages.length, before + 1);
});

test("refresh from another session or iframe cannot invalidate current page", async () => {
  const h = background();
  await h.send({ type: "page", sessionID: ids[0], pageURL: "https://site.test/page" });
  await h.flush();
  const before = h.messages.length;
  await h.send({ type: "refresh", sessionID: ids[1] });
  await h.send({ type: "refresh", sessionID: ids[0] }, 1, 2);
  await h.flush();
  assert.equal(h.messages.length, before);
});

test("repeated DOM scans, page announcements and range requests do not rewrite or notify unchanged media", async () => {
  const h = background();
  const page = { type: "page", sessionID: ids[0], pageURL: "https://site.test/page", title: "Video" };
  const resource = { url: "https://media.test/video.mp4", bytes: 1000 };
  await h.send(page);
  await h.send({ type: "resources", sessionID: ids[0], resources: [resource], notices: [] });
  await h.flush();
  for (let i = 0; i < 20; i++) {
    await h.send(page);
    await h.send({ type: "resources", sessionID: ids[0], resources: [resource], notices: [] });
    h.browser.webRequest.onHeadersReceived.listener({ tabId: 1, url: resource.url, statusCode: 206, responseHeaders: [{ name: "Content-Range", value: "bytes 0-99/1000" }] });
    await h.flush();
  }
  assert.equal(h.messages.filter(item => item.type === "upsert").length, 1);
  assert.equal(h.notifications.length, 1);
  await h.send({ type: "resources", sessionID: ids[0], resources: [{ ...resource, width: 1280, height: 720 }], notices: [] });
  await h.flush();
  assert.equal(h.messages.at(-1).resources[0].height, 720);
  assert.equal(h.notifications.length, 2);
  await h.send({ type: "resources", sessionID: ids[0], resources: [{ url: "https://media.test/second.mp4" }], notices: ["protected"] });
  await h.flush();
  assert.equal(h.messages.at(-1).resources.length, 2);
  assert.deepEqual(h.messages.at(-1).notices, ["protected"]);
  assert.equal(h.notifications.length, 3);
});

test("unchanged recovery heartbeats maintain native storage without invalidating the toolbar", async () => {
  const h = background();
  const page = { type: "page", sessionID: ids[0], pageURL: "https://site.test/page" };
  await h.send(page); await h.flush();
  h.advance(20000);
  await h.send(page); await h.flush();
  assert.equal(h.messages.length, 1);
  h.advance(40000);
  await h.send(page); await h.flush();
  assert.equal(h.messages.length, 2);
  assert.equal(h.notifications.length, 1);
});

test("native count changes during heartbeat still refresh the toolbar", async () => {
  const h = background();
  let count = 1;
  h.browser.runtime.sendNativeMessage = async () => ({ ok: true, count });
  const page = { type: "page", sessionID: ids[0], pageURL: "https://site.test/page" };
  await h.send(page); await h.flush();
  h.advance(60000);
  await h.send(page); await h.flush();
  assert.equal(h.notifications.length, 1);
  count = 2;
  h.advance(60000);
  await h.send(page); await h.flush();
  assert.equal(h.notifications.length, 2);
});

test("failed native ingestion is retried and does not announce unpublished results", async () => {
  const h = background();
  let attempts = 0;
  h.browser.runtime.sendNativeMessage = async () => ({ ok: ++attempts > 1 });
  const page = { type: "page", sessionID: ids[0], pageURL: "https://site.test/page" };
  await h.send(page); await h.flush();
  assert.equal(h.notifications.length, 0);
  await h.send(page); await h.flush();
  assert.equal(attempts, 2);
  assert.equal(h.notifications.length, 1);
});

test("duplicate observations queued during native analysis are coalesced after success", async () => {
  const h = background();
  let complete, calls = 0;
  h.browser.runtime.sendNativeMessage = () => {
    calls++;
    return new Promise(resolve => { complete = resolve; });
  };
  const page = { type: "page", sessionID: ids[0], pageURL: "https://site.test/page" };
  await h.send(page); await h.flush();
  await h.send(page); await h.flush();
  assert.equal(calls, 1);
  complete({ ok: true }); await h.flush();
  assert.equal(calls, 1);
  assert.equal(h.notifications.length, 1);
});

test("toolbar clicks address the clicked tab's top frame and use the native app only when unavailable", async () => {
  const h = background();
  h.browser.tabs.sendMessage = async (tabID, message, options) => {
    assert.equal(tabID, 42);
    assert.equal(message.type, "show-popover");
    assert.equal(options.frameId, 0);
    return { ok: true };
  };
  await h.browser.browserAction.onClicked.listener({ id: 42 });
  assert.equal(h.messages.length, 0);
  h.browser.tabs.sendMessage = async () => { throw new Error("No page access"); };
  await h.browser.browserAction.onClicked.listener({ id: 43 });
  assert.equal(h.messages.at(-1).type, "open-app");
});

test("same URL in separate Safari tabs retains separate page tokens and resources", async () => {
  const h = background();
  await h.send({ type: "page", sessionID: ids[0], pageURL: "https://site.test/page", title: "First" }, 1);
  await h.send({ type: "page", sessionID: ids[1], pageURL: "https://site.test/page", title: "Second" }, 2);
  await h.send({ type: "resources", sessionID: ids[0], resources: [{ url: "https://media.test/one.mp4" }] }, 1);
  await h.send({ type: "resources", sessionID: ids[1], resources: [{ url: "https://media.test/two.mp4" }] }, 2);
  await h.flush();
  const pages = h.messages.filter(item => item.type === "upsert");
  assert.equal(pages.length, 2);
  assert.equal(pages.find(item => item.sessionID === ids[0]).resources[0].url, "https://media.test/one.mp4");
  assert.equal(pages.find(item => item.sessionID === ids[1]).resources[0].url, "https://media.test/two.mp4");
  assert.equal(h.notifications.length, 2);
});

test("SPA generation changes clear previous resources and reject stale content messages", async () => {
  const h = background();
  await h.send({ type: "page", sessionID: ids[0], pageURL: "https://site.test/page" });
  await h.send({ type: "resources", sessionID: ids[0], resources: [{ url: "https://media.test/old.mp4" }] });
  await h.flush();
  await h.send({ type: "page", sessionID: ids[1], pageURL: "https://site.test/page?route=two" });
  await h.send({ type: "resources", sessionID: ids[0], resources: [{ url: "https://media.test/stale.mp4" }] });
  await h.flush();
  assert.ok(h.messages.some(item => item.type === "remove" && item.sessionID === ids[0]));
  const last = h.messages.filter(item => item.type === "upsert").at(-1);
  assert.equal(last.sessionID, ids[1]);
  assert.equal(last.resources.length, 0);
});

test("requests that complete after SPA navigation cannot contaminate the new page", async () => {
  const h = background();
  await h.send({ type: "page", sessionID: ids[0], pageURL: "https://site.test/page" });
  h.browser.webRequest.onBeforeRequest.listener({ tabId: 1, requestId: "old", type: "media" });
  await h.send({ type: "page", sessionID: ids[1], pageURL: "https://site.test/page?route=two" });
  h.browser.webRequest.onHeadersReceived.listener({ tabId: 1, requestId: "old", url: "https://media.test/old.mp4", responseHeaders: [] });
  await h.flush();
  assert.equal(h.messages.filter(item => item.type === "upsert").at(-1).resources.length, 0);
});

test("iframe resource observations attach to top-page context and stale frames are rejected", async () => {
  const h = background();
  await h.send({ type: "page", sessionID: ids[0], pageURL: "https://site.test/page" });
  assert.equal((await h.send({ type: "frame", documentID: ids[1] }, 1, 8)).sessionID, ids[0]);
  await h.send({ type: "resources", documentID: ids[1], resources: [{ url: "https://media.test/frame.mp4" }] }, 1, 8);
  await h.send({ type: "resources", documentID: ids[2], resources: [{ url: "https://media.test/stale.mp4" }] }, 1, 8);
  await h.flush();
  const resources = h.messages.filter(item => item.type === "upsert").at(-1).resources;
  assert.equal(resources.length, 1);
  assert.equal(resources[0].url, "https://media.test/frame.mp4");
});

test("closed tabs remove their native state after earlier queued writes", async () => {
  const h = background();
  await h.send({ type: "page", sessionID: ids[0], pageURL: "https://site.test/page" });
  await h.flush();
  h.browser.tabs.onRemoved.listener(1);
  await h.flush();
  assert.equal(h.messages.at(-1).type, "remove");
  assert.equal(h.messages.at(-1).sessionID, ids[0]);
});

test("network media before document registration is bounded and transferred to that document", async () => {
  const h = background();
  for (let i = 0; i < 1000; i++) h.browser.webRequest.onHeadersReceived.listener({ tabId: 1, url: `https://media.test/video-${i}.mp4`, responseHeaders: [] });
  await h.send({ type: "page", sessionID: ids[0], pageURL: "https://site.test/page" });
  await h.flush();
  assert.equal(h.messages.at(-1).resources.length, 64);
});

test("partial-content responses use the total range length and private browsing is explicit", async () => {
  const h = background();
  await h.send({ type: "page", sessionID: ids[0], pageURL: "https://site.test/page" }, 1, 0, true);
  h.browser.webRequest.onHeadersReceived.listener({ tabId: 1, url: "https://media.test/video.mp4", statusCode: 206, responseHeaders: [{ name: "Content-Range", value: "bytes 0-99/123456" }, { name: "Content-Length", value: "100" }] });
  await h.flush();
  assert.equal(h.messages.at(-1).privateBrowsing, true);
  assert.equal(h.messages.at(-1).resources[0].bytes, 123456);
});

test("MIME-discovered signed resources are preserved while raw transport chunks are discarded", async () => {
  const h = background();
  await h.send({ type: "page", sessionID: ids[0], pageURL: "https://site.test/page" });
  for (const [url, type] of [["https://media.test/play?signature=x", "video/mp4"], ["https://media.test/chunk", "video/iso.segment"], ["https://media.test/segment001.ts", "video/mp2t"]]) {
    h.browser.webRequest.onHeadersReceived.listener({ tabId: 1, url, responseHeaders: [{ name: "Content-Type", value: type }] });
  }
  await h.flush();
  assert.equal(h.messages.at(-1).resources.length, 1);
  assert.equal(h.messages.at(-1).resources[0].url, "https://media.test/play?signature=x");
});
