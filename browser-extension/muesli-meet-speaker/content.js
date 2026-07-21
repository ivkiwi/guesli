const MUESLI_BRIDGE_URL = "http://127.0.0.1:1477/v1/meet-speaker";
const MIN_SEND_INTERVAL_MS = 900;
const PARTICIPANT_REFRESH_INTERVAL_MS = 8000;
const MAX_PARTICIPANTS = 80;
const BACKUP_STORAGE_KEY = "muesliMeetSpeakerBridge.timeline.v1";
const BACKUP_MAX_EVENTS = 1200;
const BACKUP_FLUSH_BATCH_SIZE = 50;
const BACKUP_FLUSH_MAX_BYTES = 48000;
const BACKUP_FLUSH_INTERVAL_MS = 5000;
const SCAN_DEBOUNCE_MS = 750;
const MIN_SCAN_INTERVAL_MS = 1000;
const BACKGROUND_MIN_SCAN_INTERVAL_MS = 5000;
const CAPTION_SPEAKER_TTL_MS = 4000;
const speakerDetection = globalThis.MuesliMeetSpeakerDetection;

let lastSpeaker = "";
let lastSentAt = 0;
let lastParticipantSignature = "";
let lastParticipantSentAt = 0;
let flushingBackup = false;
let backupObservations = loadBackupObservations().slice(-BACKUP_MAX_EVENTS);
let backupDirty = false;
let backupPersistTimer = 0;
let pendingScanTimer = 0;
let lastScanAt = 0;
let lastKnownParticipants = [];
let captionsStateChecked = false;
const recentCaptionSpeakers = new Map();

function isVisible(element) {
  const rect = element.getBoundingClientRect();
  return rect.width > 0 && rect.height > 0;
}

function isDocumentVisible() {
  return document.visibilityState === "visible" && !document.hidden;
}

function scanIntervalFloorMs() {
  return isDocumentVisible() ? MIN_SCAN_INTERVAL_MS : BACKGROUND_MIN_SCAN_INTERVAL_MS;
}

function cleanName(value) {
  return value
    .replace(/\s+/g, " ")
    .replace(/\b(is speaking|speaking|is presenting|presenting|microphone is on|microphone is off|muted|unmuted)\b/gi, "")
    .replace(/[,:;-]+$/g, "")
    .trim();
}

function isClockLikeName(name) {
  return /^\d{1,2}:\d{2}(?::\d{2})?(?:\s?[AP]M)?$/i.test((name || "").trim());
}

function nameFromSpeakingLabel(label) {
  const text = cleanName(label);
  if (!/\b(speaking|is speaking)\b/i.test(label)) return "";
  if (!text || text.length < 2 || text.length > 80) return "";
  if (isClockLikeName(text)) return "";
  if (/^(you|your presentation|presentation)$/i.test(text)) return "";
  return text;
}

function cleanParticipantName(value) {
  return cleanName(value)
    .replace(/\s*\((you|me|presentation|presenting[^)]*)\)\s*/gi, " ")
    .replace(/\b(you|me)\b$/i, "")
    .replace(/\b(tiles?|participants?|people|camera|video|microphone|captions?|pin|unpin|more options)\b/gi, "")
    .replace(/\b(ask to unmute|remove from call|joined|left)\b/gi, "")
    .replace(/\s+/g, " ")
    .trim();
}

function validParticipantName(name) {
  if (!name || name.length < 2 || name.length > 80) return false;
  if (isClockLikeName(name)) return false;
  if (/[\r\n]/.test(name)) return false;
  if (/[!?]/.test(name)) return false;
  if (/^(you|me|everyone|people|chat|activities|host controls|present now|settings|leave call)$/i.test(name)) return false;
  if (/^(muted|unmuted|speaking|presenting|camera off|microphone off|turn on|turn off)$/i.test(name)) return false;
  if (/\b(click to|your|background|settings|controls|options|caption|camera|video|microphone)\b/i.test(name)) return false;
  if (/^[a-z_]+$/.test(name)) return false;
  return /[A-Za-zА-Яа-яЁё0-9]/.test(name);
}

function addSpeakerName(map, rawValue) {
  const name = cleanParticipantName(rawValue || "");
  if (!validParticipantName(name)) return;
  const key = name.toLocaleLowerCase();
  if (!map.has(key)) map.set(key, name);
}

function addParticipant(map, rawValue) {
  const raw = (rawValue || "").trim();
  if (/[\r\n]/.test(raw)) return;
  const isSelf = /\b(you|me)\b/i.test(raw);
  const name = cleanParticipantName(raw);
  if (!validParticipantName(name)) return;
  const key = name.toLocaleLowerCase();
  if (!map.has(key)) {
    map.set(key, { name, isSelf });
  } else if (isSelf) {
    map.get(key).isSelf = true;
  }
}

function collectParticipants() {
  const participants = new Map();
  const labelled = [...document.querySelectorAll("[aria-label]")].filter(isVisible);
  for (const element of labelled) {
    const label = element.getAttribute("aria-label") || "";
    if (!/\b(speaking|muted|unmuted|presenting|participant|tile)\b/i.test(label)) continue;
    addParticipant(participants, label);
  }

  const listItems = [...document.querySelectorAll('[role="listitem"], [role="gridcell"]')].filter(isVisible);
  for (const item of listItems) {
    const firstLine = (item.innerText || item.textContent || "")
      .split("\n")
      .map((line) => line.trim())
      .find(Boolean);
    if (firstLine) addParticipant(participants, firstLine);
  }

  const nameNodes = [...document.querySelectorAll(".notranslate")].filter(isVisible);
  for (const node of nameNodes) {
    addParticipant(participants, node.innerText || node.textContent || "");
  }

  return [...participants.values()]
    .sort((lhs, rhs) => lhs.name.localeCompare(rhs.name))
    .slice(0, MAX_PARTICIPANTS);
}

function activeSpeakersFromAriaLabels() {
  const speakers = new Map();
  const labelled = [...document.querySelectorAll("[aria-label]")].filter(isVisible);
  for (const element of labelled) {
    const name = nameFromSpeakingLabel(element.getAttribute("aria-label") || "");
    if (name) addSpeakerName(speakers, name);
  }
  return [...speakers.values()];
}

function activeSpeakersFromLiveRegions() {
  const speakers = new Map();
  const regions = [...document.querySelectorAll('[aria-live], [role="status"], [role="log"]')].filter(isVisible);
  for (const region of regions) {
    const lines = (region.innerText || region.textContent || "")
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean);
    for (const line of lines) {
      const name = nameFromSpeakingLabel(line);
      if (name) addSpeakerName(speakers, name);
    }
  }
  return [...speakers.values()];
}

function captionCandidateLines(element) {
  if (!element || !isVisible(element)) return [];
  const text = element.innerText || element.textContent || "";
  if (text.length < 4 || text.length > 1000) return [];
  const lines = text.split("\n").map((line) => line.trim()).filter(Boolean);
  if (lines.length > 16) return [];

  const rect = element.getBoundingClientRect();
  const liveRegion = element.closest('[aria-live], [role="status"], [role="log"]');
  const inCaptionArea = rect.bottom >= window.innerHeight * 0.55
    && rect.left < window.innerWidth * 0.75;
  return liveRegion || inCaptionArea ? lines : [];
}

function recordCaptionSpeakers(mutations) {
  if (!speakerDetection || lastKnownParticipants.length === 0) return;
  const candidates = new Set();
  for (const mutation of mutations) {
    const target = mutation.target?.nodeType === Node.ELEMENT_NODE
      ? mutation.target
      : mutation.target?.parentElement;
    if (target) candidates.add(target);
    for (const node of mutation.addedNodes || []) {
      const element = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
      if (element) candidates.add(element);
    }
  }

  for (const candidate of candidates) {
    let element = candidate;
    for (let depth = 0; element && depth < 6; depth += 1, element = element.parentElement) {
      const lines = captionCandidateLines(element);
      if (lines.length === 0) continue;
      const speaker = speakerDetection.captionSpeakerFromLines(lines, lastKnownParticipants);
      if (speaker) recentCaptionSpeakers.set(speaker.toLocaleLowerCase(), { name: speaker, at: Date.now() });
    }
  }
}

function activeSpeakersFromRecentCaptions() {
  const now = Date.now();
  for (const [key, observation] of recentCaptionSpeakers) {
    if (now - observation.at > CAPTION_SPEAKER_TTL_MS) recentCaptionSpeakers.delete(key);
  }
  const latest = [...recentCaptionSpeakers.values()].sort((lhs, rhs) => rhs.at - lhs.at)[0];
  return latest ? [latest.name] : [];
}

function maybeEnableCaptions() {
  if (captionsStateChecked) return;
  const controls = [...document.querySelectorAll('button[aria-label], [role="button"][aria-label]')].filter(isVisible);
  const enabled = controls.some((control) => /^(turn off|disable) captions\b|^выключить субтитры\b/i.test(control.getAttribute("aria-label") || ""));
  if (enabled) {
    captionsStateChecked = true;
    return;
  }

  const enableButton = controls.find((control) => /^(turn on|enable) captions\b|^включить субтитры\b/i.test(control.getAttribute("aria-label") || ""));
  if (enableButton) {
    captionsStateChecked = true;
    enableButton.click();
  }
}

function tileHasSpeakingState(tile) {
  const label = tile.getAttribute("aria-label") || "";
  if (/\b(speaking|is speaking)\b/i.test(label)) return true;
  if (tile.matches('[data-is-speaking="true"], [data-speaking="true"]')) return true;
  return [...tile.querySelectorAll('[aria-label], [data-is-speaking], [data-speaking]')].some((element) => {
    const childLabel = element.getAttribute("aria-label") || "";
    return /\b(speaking|is speaking)\b/i.test(childLabel)
      || element.getAttribute("data-is-speaking") === "true"
      || element.getAttribute("data-speaking") === "true";
  });
}

function activeSpeakersFromMeetTiles() {
  const speakers = new Map();
  const tiles = [...document.querySelectorAll('[role="gridcell"], [role="listitem"], [data-participant-id]')]
    .filter(isVisible)
    .filter(tileHasSpeakingState);
  for (const tile of tiles) {
    const speakerCountBeforeTile = speakers.size;
    const labelName = nameFromSpeakingLabel(tile.getAttribute("aria-label") || "");
    if (labelName) addSpeakerName(speakers, labelName);
    const nameNode = [...tile.querySelectorAll(".notranslate")].find(isVisible);
    if (nameNode) addSpeakerName(speakers, nameNode.innerText || nameNode.textContent || "");
    if (speakers.size === speakerCountBeforeTile) {
      const firstLine = (tile.innerText || tile.textContent || "")
        .split("\n")
        .map((line) => line.trim())
        .find(Boolean);
      if (firstLine) addSpeakerName(speakers, firstLine);
    }
  }
  return [...speakers.values()];
}

function mergeSpeakerGroups(groups) {
  const speakers = new Map();
  for (const group of groups) {
    for (const name of group) addSpeakerName(speakers, name);
  }
  return [...speakers.values()];
}

function detectActiveSpeakers() {
  const explicitSpeakers = mergeSpeakerGroups([
    activeSpeakersFromAriaLabels(),
    activeSpeakersFromLiveRegions(),
    activeSpeakersFromMeetTiles()
  ]);
  return speakerDetection?.preferExplicitSpeakers(
    explicitSpeakers,
    activeSpeakersFromRecentCaptions()
  ) || explicitSpeakers;
}

async function sendObservation(activeSpeakers) {
  const now = Date.now();
  const participants = collectParticipants();
  lastKnownParticipants = participants;
  const name = activeSpeakers[0] || "";
  const speakerSignature = activeSpeakers.join("\n");
  const participantSignature = participants.map((participant) => `${participant.name}|${participant.isSelf}`).join("\n");
  const shouldSendSpeaker = speakerSignature && (speakerSignature !== lastSpeaker || now - lastSentAt >= MIN_SEND_INTERVAL_MS);
  const shouldSendParticipants = participants.length > 0
    && (participantSignature !== lastParticipantSignature || now - lastParticipantSentAt >= PARTICIPANT_REFRESH_INTERVAL_MS);
  if (!shouldSendSpeaker && !shouldSendParticipants) return;

  if (shouldSendSpeaker) {
    lastSpeaker = speakerSignature;
    lastSentAt = now;
  }
  if (shouldSendParticipants) {
    lastParticipantSignature = participantSignature;
    lastParticipantSentAt = now;
  }

  const body = {
    meetingURL: location.href,
    observedAt: new Date(now).toISOString(),
    observedAtMs: now,
    participants,
    source: "google-meet-extension"
  };
  if (activeSpeakers.length) body.activeSpeakers = activeSpeakers;
  if (name) body.speakerName = name;

  const backupId = storeBackupObservation(body);
  try {
    await postBridgePayload(body);
    removeBackupObservations([backupId]);
  } catch (_) {
    // Local app may be closed. Stay quiet inside Meet.
  }
}

function loadBackupObservations() {
  try {
    const raw = localStorage.getItem(BACKUP_STORAGE_KEY);
    const parsed = raw ? JSON.parse(raw) : [];
    return Array.isArray(parsed) ? parsed : [];
  } catch (_) {
    return [];
  }
}

function persistBackupObservations() {
  if (!backupDirty) return;
  try {
    localStorage.setItem(BACKUP_STORAGE_KEY, JSON.stringify(backupObservations.slice(-BACKUP_MAX_EVENTS)));
    backupDirty = false;
  } catch (_) {
    // If storage is unavailable or full, live push still works.
  }
}

function persistBackupObservationsNow() {
  if (backupPersistTimer) {
    clearTimeout(backupPersistTimer);
    backupPersistTimer = 0;
  }
  persistBackupObservations();
}

function scheduleBackupPersist() {
  backupDirty = true;
  if (backupPersistTimer) return;
  backupPersistTimer = setTimeout(() => {
    backupPersistTimer = 0;
    persistBackupObservations();
  }, BACKUP_FLUSH_INTERVAL_MS);
}

function storeBackupObservation(body) {
  const id = `${body.observedAtMs}-${Math.random().toString(36).slice(2)}`;
  backupObservations.push({ id, body });
  backupObservations = backupObservations.slice(-BACKUP_MAX_EVENTS);
  scheduleBackupPersist();
  return id;
}

function removeBackupObservations(ids) {
  const remove = new Set(ids);
  const previousLength = backupObservations.length;
  backupObservations = backupObservations.filter((entry) => !remove.has(entry.id));
  if (backupObservations.length !== previousLength) {
    scheduleBackupPersist();
  }
}

async function postBridgePayload(payload) {
  if (typeof chrome !== "undefined" && chrome.runtime?.sendMessage) {
    try {
      const response = await sendBackgroundMessage({ type: "muesli.postBridgePayload", payload });
      if (!response?.ok) {
        throw new Error(response?.error || "Guesli bridge request failed");
      }
      return;
    } catch (error) {
      if (!/Extension context invalidated/i.test(error?.message || "")) {
        throw error;
      }
    }
  }

  await fetchBridgePayload(payload);
}

async function fetchBridgePayload(payload) {
  const response = await fetch(MUESLI_BRIDGE_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload)
  });
  if (!response.ok) {
    throw new Error(`Guesli bridge returned ${response.status}`);
  }
}

function sendBackgroundMessage(message) {
  return new Promise((resolve, reject) => {
    chrome.runtime.sendMessage(message, (response) => {
      const error = chrome.runtime.lastError;
      if (error) {
        reject(new Error(error.message));
      } else {
        resolve(response);
      }
    });
  });
}

async function flushBackupObservations() {
  if (flushingBackup) return;
  if (backupObservations.length === 0) return;

  flushingBackup = true;
  const batch = selectBackupBatch(backupObservations);
  try {
    await postBridgePayload({
      meetingURL: location.href,
      observations: batch.map((entry) => entry.body),
      source: "google-meet-extension-backup"
    });
    removeBackupObservations(batch.map((entry) => entry.id));
  } catch (_) {
    // Keep the local backup for the next flush.
  } finally {
    flushingBackup = false;
  }
}

function selectBackupBatch(observations) {
  const batch = [];
  for (const entry of observations.slice(0, BACKUP_MAX_EVENTS)) {
    const candidate = batch.concat(entry);
    const payload = {
      meetingURL: location.href,
      observations: candidate.map((candidateEntry) => candidateEntry.body),
      source: "google-meet-extension-backup"
    };
    if (batch.length > 0 && JSON.stringify(payload).length > BACKUP_FLUSH_MAX_BYTES) break;
    batch.push(entry);
    if (batch.length >= BACKUP_FLUSH_BATCH_SIZE) break;
  }
  return batch.length > 0 ? batch : observations.slice(0, 1);
}

function sample() {
  const now = Date.now();
  const elapsed = now - lastScanAt;
  const floorMs = scanIntervalFloorMs();
  if (elapsed < floorMs) {
    scheduleSample(floorMs - elapsed);
    return;
  }
  if (pendingScanTimer) {
    clearTimeout(pendingScanTimer);
    pendingScanTimer = 0;
  }
  lastScanAt = now;
  maybeEnableCaptions();
  sendObservation(detectActiveSpeakers());
}

function scheduleSample(delayMs = SCAN_DEBOUNCE_MS) {
  if (pendingScanTimer) {
    clearTimeout(pendingScanTimer);
  }
  const elapsed = Date.now() - lastScanAt;
  const waitMs = Math.max(delayMs, scanIntervalFloorMs() - elapsed, 0);
  pendingScanTimer = setTimeout(() => {
    pendingScanTimer = 0;
    sample();
  }, waitMs);
}

function handleVisibilityChange() {
  persistBackupObservationsNow();
  scheduleSample(0);
}

const observer = new MutationObserver((mutations) => {
  recordCaptionSpeakers(mutations);
  scheduleSample();
});
observer.observe(document.documentElement, {
  subtree: true,
  childList: true,
  characterData: true,
  attributes: true,
  attributeFilter: ["aria-label", "class", "data-is-speaking", "data-speaking"]
});

window.addEventListener("pagehide", persistBackupObservationsNow);
document.addEventListener("visibilitychange", handleVisibilityChange);

setInterval(sample, 1500);
setInterval(flushBackupObservations, BACKUP_FLUSH_INTERVAL_MS);
sample();
flushBackupObservations();
