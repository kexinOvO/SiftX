const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const path = require("node:path");
const { randomUUID, webcrypto } = require("node:crypto");
const root = path.resolve(__dirname, "../..");

function isolatedWorlds(insecure = false) {
  const native = [], probe = [], callbacks = new Map(), attributes = new Map(), intervals = [], safariListeners = [], windowListeners = new Map();
  let probeListener;
  let loseRegistration = false;
  const location = { href: insecure ? "http://site.test/page" : "https://site.test/page" };
  const document = {
    title: "Example", baseURI: location.href,
    documentElement: { getAttribute: key => attributes.get(key), setAttribute: (key, value) => attributes.set(key, value) },
    querySelectorAll: () => [],
    addEventListener(name, fn) { const list = callbacks.get(name) || []; list.push(fn); callbacks.set(name, list); },
    dispatchEvent(event) { for (const fn of callbacks.get(event.type) || []) fn(event); }
  };
  const window = { addEventListener(name, fn) { const list = windowListeners.get(name) || []; list.push(fn); windowListeners.set(name, list); } };
  window.top = window;
  const base = {
    document, window, location, URL, crypto: insecure ? { getRandomValues: webcrypto.getRandomValues.bind(webcrypto) } : { randomUUID },
    CustomEvent: class { constructor(type) { this.type = type; } },
    MutationObserver: class { observe() {} },
    PerformanceObserver: class { observe() {} },
    performance: { getEntriesByType: () => [] },
    setTimeout() { return 1; }, clearTimeout() {}, setInterval(fn, ms) { intervals.push({ fn, ms }); }
  };
  const nativeWorld = vm.createContext({ ...base, safari: { extension: { dispatchMessage(name, message) { native.push({ name, message: structuredClone(message) }); } }, self: { addEventListener(name, fn) { if (name === "message") safariListeners.push(fn); } } } });
  const probeWorld = vm.createContext({ ...base, browser: { runtime: { onMessage: { addListener(fn) { probeListener = fn; } }, async sendMessage(message) {
    probe.push(structuredClone(message));
    if (message.type === "resources" && loseRegistration) { loseRegistration = false; return { sessionID: null }; }
    return { sessionID: message.sessionID };
  } } } });
  const run = (context, file) => vm.runInContext(fs.readFileSync(path.join(root, file), "utf8"), context);
  return {
    native, probe, location,
    toolbarClick() { return probeListener({ type: "show-popover" }); },
    startNative() { run(nativeWorld, "SafariExtension/SafariBridge.js"); },
    startProbe() { run(probeWorld, "MediaProbe/Resources/probe-core.js"); run(probeWorld, "MediaProbe/Resources/content.js"); },
    poll() { for (const interval of intervals) if (interval.ms === 750) interval.fn(); },
    query(id) { for (const fn of safariListeners) fn({ name: "siftx.queryContext", message: { requestID: id } }); },
    refresh() { for (const fn of safariListeners) fn({ name: "siftx.refresh" }); },
    loseRegistry() { loseRegistration = true; },
    heartbeat() { for (const interval of intervals) if (interval.ms === 20000) interval.fn(); },
    event(type) { for (const fn of windowListeners.get(type) || []) fn({ type }); },
    async drain() { for (let i = 0; i < 16; i++) await Promise.resolve(); }
  };
}

test("probe toolbar click crosses independent script worlds into the native popover handler", async () => {
  const h = isolatedWorlds(); h.startNative(); h.startProbe(); await h.drain();
  assert.equal((await h.toolbarClick()).ok, true);
  assert.equal(h.native.at(-1).name, "siftx.showPopover");
});

test("a probe-only page reports unavailable native UI so the toolbar can open the app", async () => {
  const h = isolatedWorlds(); h.startProbe(); await h.drain();
  assert.equal((await h.toolbarClick()).ok, false);
});

for (const first of ["native", "probe"]) {
  test(`independent injected worlds share one page token when ${first} starts first`, async () => {
    const h = isolatedWorlds();
    if (first === "native") { h.startNative(); h.startProbe(); }
    else { h.startProbe(); h.startNative(); }
    await h.drain();
    assert.ok(h.native.length > 0);
    assert.ok(h.probe.some(item => item.type === "page"));
    assert.equal(h.native.at(-1).message.sessionID, h.probe.filter(item => item.type === "page").at(-1).sessionID);
  });
}
test("SPA URL generation converges across the isolated worlds without double rotation", async () => {
  const h = isolatedWorlds(); h.startNative(); h.startProbe(); await h.drain();
  const first = h.native.at(-1).message.sessionID;
  h.location.href = "https://site.test/page?route=second";
  h.poll(); await h.drain();
  const nativeID = h.native.at(-1).message.sessionID;
  const probeID = h.probe.filter(item => item.type === "page").at(-1).sessionID;
  assert.notEqual(nativeID, first);
  assert.equal(nativeID, probeID);
  h.poll(); await h.drain();
  assert.equal(h.native.at(-1).message.sessionID, nativeID);
});
test("fresh documents at exactly the same URL receive independent sessions", async () => {
  const first = isolatedWorlds(), second = isolatedWorlds();
  first.startNative(); first.startProbe(); second.startNative(); second.startProbe();
  await first.drain(); await second.drain();
  assert.notEqual(first.native.at(-1).message.sessionID, second.native.at(-1).message.sessionID);
});
test("native exact-page queries return their request nonce only through the Safari bridge", async () => {
  const h = isolatedWorlds(); h.startNative(); h.startProbe(); await h.drain();
  h.query("native-only-request-42");
  assert.equal(h.native.at(-1).message.requestID, "native-only-request-42");
  assert.ok(h.probe.every(item => item.requestID === undefined));
});
test("pagehide removes the old session and BFCache pageshow re-registers it", async () => {
  const h = isolatedWorlds(); h.startNative(); h.startProbe(); await h.drain();
  const original = h.probe.find(item => item.type === "page").sessionID;
  const registrationsBefore = h.probe.filter(item => item.type === "page").length;
  h.event("pagehide"); await h.drain();
  assert.equal(h.probe.at(-1).type, "leave");
  assert.equal(h.probe.at(-1).sessionID, original);
  h.event("pageshow"); await h.drain();
  assert.equal(h.probe.filter(item => item.type === "page").length, registrationsBefore + 1);
  // The same cached document retains its token while rejoining the background registry.
  assert.equal(h.native.at(-1).message.sessionID, original);
  assert.equal(h.probe.filter(item => item.type === "page").at(-1).sessionID, original);
});
test("both actual injected scripts run and share context on ordinary HTTP pages", async () => {
  const h = isolatedWorlds(true); h.startNative(); h.startProbe(); await h.drain();
  assert.equal(h.native.at(-1).message.sessionID, h.probe.find(item => item.type === "page").sessionID);
});

test("native refresh re-registers unchanged page and forces a new media analysis", async () => {
  const h = isolatedWorlds(); h.startNative(); h.startProbe(); await h.drain();
  const original = h.probe.find(item => item.type === "page").sessionID;
  const before = h.probe.filter(item => item.type === "page").length;
  h.refresh(); await h.drain();
  assert.ok(h.probe.filter(item => item.type === "page").length > before);
  assert.equal(h.probe.findLast(item => item.type === "refresh").sessionID, original);
  assert.equal(h.native.at(-1).message.sessionID, original);
});

test("heartbeat recovers resources after background registry is lost", async () => {
  const h = isolatedWorlds(); h.startNative(); h.startProbe(); await h.drain();
  const before = h.probe.filter(item => item.type === "page").length;
  h.loseRegistry(); h.heartbeat(); await h.drain();
  assert.equal(h.probe.filter(item => item.type === "page").length, before + 2);
  assert.equal(h.probe.at(-1).type, "resources");
});
