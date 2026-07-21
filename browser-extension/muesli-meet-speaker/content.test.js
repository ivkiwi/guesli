const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const speakerDetection = require("./speaker-detection.js");
const manifest = require("./manifest.json");

const source = fs.readFileSync(path.join(__dirname, "content.js"), "utf8");

test("active speakers only come from explicit speaking state", () => {
  assert.doesNotMatch(source, /\[jscontroller\]/);
  assert.match(source, /activeSpeakersFromRecentCaptions\(\)/);
  assert.match(source, /activeSpeakersFromAriaLabels\(\)/);
  assert.match(source, /activeSpeakersFromLiveRegions\(\)/);
  assert.match(source, /activeSpeakersFromMeetTiles\(\)/);
});

test("manifest loads speaker detection before the content script", () => {
  assert.deepEqual(
    manifest.content_scripts[0].js,
    ["speaker-detection.js", "content.js"]
  );
});

test("caption speaker must match exactly one known participant", () => {
  const participants = [{ name: "Ivan Kiwi" }, { name: "Kirill Pro" }];

  assert.equal(
    speakerDetection.captionSpeakerFromLines(["Ivan Kiwi", "Доброе утро"], participants),
    "Ivan Kiwi"
  );
  assert.equal(
    speakerDetection.captionSpeakerFromLines(["Kirill Prokhorov", "Начинаем"], participants),
    "Kirill Pro"
  );
  assert.equal(
    speakerDetection.captionSpeakerFromLines(["Ivan Kiwi Доброе утро"], participants),
    "Ivan Kiwi"
  );
  assert.equal(
    speakerDetection.captionSpeakerFromLines(["Traffic Daily", "Ivan Kiwi"], participants),
    ""
  );
  assert.equal(
    speakerDetection.captionSpeakerFromLines(["Ivan", "Доброе утро"], participants),
    ""
  );
});

test("caption matcher rejects ambiguous truncated names", () => {
  const participants = [{ name: "Anton Kulin" }, { name: "Anton Kulikov" }];
  assert.equal(
    speakerDetection.captionSpeakerFromLines(["Anton Kuli", "Привет"], participants),
    ""
  );
});

test("current explicit speaking state wins over a stale caption speaker", () => {
  assert.deepEqual(
    speakerDetection.preferExplicitSpeakers(["Bob Reviewer"], ["Alice Owner"]),
    ["Bob Reviewer"]
  );
  assert.deepEqual(
    speakerDetection.preferExplicitSpeakers([], ["Alice Owner"]),
    ["Alice Owner"]
  );
});
