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

function nameFromSpeakingLabel(label) {
  const text = cleanName(label);
  if (!/\b(speaking|is speaking)\b/i.test(label)) return "";
  if (!text || text.length < 2 || text.length > 80) return "";
  if (/^(you|your presentation|presentation)$/i.test(text)) return "";
  return text;
}

function cleanParticipantName(value) {
  return cleanName(value)
    .replace(/\s*\((you|me)\)\s*/gi, " ")
    .replace(/\b(you|me)\b$/i, "")
    .replace(/\b(tiles?|participants?|people|camera|video|microphone|captions?|pin|unpin|more options)\b/gi, "")
    .replace(/\b(ask to unmute|remove from call|joined|left)\b/gi, "")
    .replace(/\s+/g, " ")
    .trim();
}

function validParticipantName(name) {
  if (!name || name.length < 2 || name.length > 80) return false;
  if (/^(you|me|everyone|people|chat|activities|host controls|present now|settings|leave call)$/i.test(name)) return false;
  if (/^(muted|unmuted|speaking|presenting|camera off|microphone off)$/i.test(name)) return false;
  return /[A-Za-zА-Яа-яЁё0-9]/.test(name);
}

function addParticipant(map, rawValue) {
  const raw = (rawValue || "").trim();
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
    if (!/\b(speaking|muted|unmuted|presenting|camera|video|microphone|participant|tile)\b/i.test(label)) continue;
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

  return [...participants.values()]
    .sort((lhs, rhs) => lhs.name.localeCompare(rhs.name))
    .slice(0, MAX_PARTICIPANTS);
}

function activeSpeakerFromAriaLabels() {
  const labelled = [...document.querySelectorAll("[aria-label]")].filter(isVisible);
  for (const element of labelled) {
    const name = nameFromSpeakingLabel(element.getAttribute("aria-label") || "");
    if (name) return name;
  }
  return "";
}

function activeSpeakerFromLiveRegions() {
  const regions = [...document.querySelectorAll('[aria-live], [role="status"], [role="log"]')].filter(isVisible);
  for (const region of regions) {
    const lines = (region.innerText || region.textContent || "")
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean);
    for (const line of lines) {
      const name = nameFromSpeakingLabel(line);
      if (name) return name;
    }
  }
  return "";
}

function activeSpeakerFromCaptions() {
  const regions = [...document.querySelectorAll('[aria-live], [role="log"], [jscontroller]')].filter(isVisible);
  for (const region of regions) {
    const lines = (region.innerText || "")
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean);
    if (lines.length < 2) continue;
    const possibleName = cleanName(lines[0]);
    if (possibleName.length >= 2 && possibleName.length <= 80 && !/[.!?]$/.test(possibleName)) {
      return possibleName;
    }
  }
  return "";
}

function detectActiveSpeaker() {
  return activeSpeakerFromAriaLabels()
    || activeSpeakerFromLiveRegions()
    || activeSpeakerFromCaptions();
}

async function sendObservation(name) {
  const now = Date.now();
  const participants = collectParticipants();
  const participantSignature = participants.map((participant) => `${participant.name}|${participant.isSelf}`).join("\n");
  const shouldSendSpeaker = name && (name !== lastSpeaker || now - lastSentAt >= MIN_SEND_INTERVAL_MS);
  const shouldSendParticipants = participants.length > 0
    && (participantSignature !== lastParticipantSignature || now - lastParticipantSentAt >= PARTICIPANT_REFRESH_INTERVAL_MS);
  if (!shouldSendSpeaker && !shouldSendParticipants) return;

  if (shouldSendSpeaker) {
    lastSpeaker = name;
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
    const response = await sendBackgroundMessage({ type: "muesli.postBridgePayload", payload });
    if (!response?.ok) {
      throw new Error(response?.error || "Guesli bridge request failed");
    }
    return;
  }

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
  sendObservation(detectActiveSpeaker());
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

const observer = new MutationObserver(() => scheduleSample());
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
