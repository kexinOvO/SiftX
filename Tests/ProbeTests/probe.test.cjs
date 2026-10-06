const test = require("node:test");
const assert = require("node:assert/strict");
const core = require("../../MediaProbe/Resources/probe-core.js");

test("classifies direct, HLS, DASH and MIME-only URLs", () => {
  assert.deepEqual(core.classify("https://media.test/video.mp4"), { transport: "direct", kind: "video" });
  assert.deepEqual(core.classify("https://media.test/music.mp3"), { transport: "direct", kind: "audio" });
  assert.equal(core.classify("https://media.test/master.m3u8").transport, "hls");
  assert.equal(core.classify("https://media.test/video.mpd").transport, "dash");
  assert.equal(core.classify("https://media.test/watch", "video/mp4").kind, "video");
});
test("excludes chunks and unsafe URLs", () => {
  for (const file of ["segment001.ts", "init.m4s", "chunk-002.mp4", "fragment001.mp4", "key.key"]) assert.equal(core.classify("https://media.test/" + file), null);
  for (const url of ["blob:https://site.test/123", "file:///tmp/video.mp4", "javascript:alert(1)", "https://u:p@site.test/v.mp4"]) assert.equal(core.validHTTPURL(url), null);
  assert.equal(core.validHTTPURL("https://site.test/" + "a".repeat(20000)), null);
});
test("bounded dedupe preserves signed URLs and meaningful metadata", () => {
  let resources = core.mergeResources([], [{ url: "https://media.test/v.mp4#x", width: 1920 }, { url: "https://media.test/v.mp4#y", height: 1080 }]);
  assert.equal(resources.length, 1);
  assert.equal(resources[0].height, 1080);
  assert.equal(resources[0].width, 1920);
  resources = core.mergeResources(resources, [{ url: "https://media.test/v.mp4?token=one" }, { url: "https://media.test/v.mp4?token=two" }]);
  assert.equal(resources.length, 3);
  resources = core.mergeResources(resources, Array.from({ length: 1000 }, (_, i) => ({ url: `https://media.test/v${i}.mp4` })));
  assert.equal(resources.length, 64);
});
test("manifest observations do not turn AAC segments into selectable audio", () => {
  const resources = core.mergeResources([], [{ url: "https://media.test/master.m3u8" }, { url: "https://media.test/audio001.aac" }, { url: "https://media.test/music.aac", explicit: true }]);
  assert.equal(resources.length, 2);
  assert.ok(resources.some(item => item.url.endsWith("music.aac")));
});
test("protected DOM media stays protected after normalization", () => {
  let resources = core.mergeResources([], [{ url: "https://media.test/video.mp4", protected: true, explicit: true }]);
  resources = core.mergeResources(resources, [{ url: "https://media.test/video.mp4" }]);
  assert.equal(resources[0].protected, true);
  assert.equal(resources[0].explicit, true);
});
test("page contexts use independent UUIDs, not URLs or Safari tab IDs", () => {
  assert.equal(core.validToken("f742e374-ecb9-486d-af03-d44b118741bc"), true);
  assert.equal(core.validToken("https://site.test/page"), false);
  assert.equal(core.validToken("42"), false);
});
test("explicit extensionless DOM audio keeps its real element kind", () => {
  const resource = core.normalizeResource({ url: "https://media.test/play", mime: "application/octet-stream", explicit: true, kind: "audio" });
  assert.equal(resource.kind, "audio");
  assert.equal(resource.transport, "direct");
  assert.equal(core.normalizeResource({ url: "https://media.test/init.m4s", explicit: true, kind: "video" }), null);
});
test("ordinary HTTP contexts generate UUIDs without secure-context-only randomUUID", () => {
  const provider = { getRandomValues: require("node:crypto").webcrypto.getRandomValues.bind(require("node:crypto").webcrypto) };
  const first = core.newPageToken(provider), second = core.newPageToken(provider);
  assert.equal(core.validToken(first), true);
  assert.notEqual(first, second);
});
