const test = require("node:test");
const assert = require("node:assert/strict");
const core = require("../../MediaProbe/Resources/probe-core.js");

test("relative HTTP media URLs keep query tokens but not fragments", () => {
  assert.equal(
    core.validHTTPURL("../media/video.mp4?token=signed#player", "https://site.test/watch/page"),
    "https://site.test/media/video.mp4?token=signed"
  );
  assert.equal(core.validHTTPURL("https://user:password@site.test/video.mp4"), null);
  assert.equal(core.validHTTPURL("javascript:alert(1)", "https://site.test/watch"), null);
  assert.equal(core.validHTTPURL("not a url"), null);
});

test("untrusted metadata is bounded and invalid thumbnails are discarded", () => {
  const resource = core.normalizeResource({
    url: "https://media.test/video.mp4#chapter",
    mime: "video/mp4;" + "x".repeat(200),
    title: "A".repeat(800),
    width: 32768,
    height: 32769,
    bytes: Number.MAX_SAFE_INTEGER,
    thumbnail: "file:///private/thumbnail.png",
    protected: true
  });
  assert.equal(resource.url, "https://media.test/video.mp4");
  assert.equal(resource.mime.length, 128);
  assert.equal(resource.title.length, 500);
  assert.equal(resource.width, 32768);
  assert.equal("height" in resource, false);
  assert.equal(resource.bytes, Number.MAX_SAFE_INTEGER);
  assert.equal("thumbnail" in resource, false);
  assert.equal(resource.protected, true);

  const invalid = core.normalizeResource({
    url: "https://media.test/audio.mp3", width: -1, height: 0, bytes: Number.MAX_SAFE_INTEGER + 1
  });
  assert.equal("width" in invalid, false);
  assert.equal("height" in invalid, false);
  assert.equal("bytes" in invalid, false);
});

test("playlist choices take priority over observed fragments when capped", () => {
  const resources = core.mergeResources([], [
    { url: "https://media.test/01.mp4" },
    { url: "https://media.test/audio001.aac" },
    { url: "https://media.test/master.m3u8" },
    { url: "https://media.test/recording.aac", explicit: true, kind: "audio" }
  ], 2);
  assert.equal(resources.length, 2);
  assert.equal(resources[0].transport, "hls");
  assert.equal(resources[1].url, "https://media.test/recording.aac");
  assert.equal(resources[1].kind, "audio");
});

test("duplicate discoveries preserve protection and accumulate valid metadata", () => {
  const url = "https://media.test/video.mp4";
  const merged = core.mergeResources([], [
    { url, width: 640, protected: true, explicit: true },
    { url, height: 360, protected: false, explicit: false }
  ]);
  assert.equal(merged.length, 1);
  assert.equal(merged[0].width, 640);
  assert.equal(merged[0].height, 360);
  assert.equal(merged[0].protected, true);
  assert.equal(merged[0].explicit, true);
});

test("fallback page token uses the UUID version and variant bits", () => {
  const provider = { getRandomValues(bytes) { bytes.fill(0); return bytes; } };
  const token = core.newPageToken(provider);
  assert.equal(token, "00000000-0000-4000-8000-000000000000");
  assert.equal(core.validToken(token), true);
  assert.equal(core.validToken("00000000-0000-1000-8000-000000000000"), false);
  assert.equal(core.validToken("00000000-0000-4000-7000-000000000000"), false);
});
