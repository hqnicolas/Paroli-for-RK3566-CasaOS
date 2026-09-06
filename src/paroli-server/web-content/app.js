"use strict";

const DB_NAME = "paroli_texts_db";
const DB_VERSION = 1;
const STORE_NAME = "texts_v1";
const MAX_ITEMS = 10;
const MAX_TEXT_LENGTH = 64 * 1024; // 64 KiB

const state = {
  voices: [], // [{ id, name, language }]
  languages: [], // ["pt_br", "en_us", ...]
  activeLanguage: "pt_br",
  speakers: {}, // { name: id }
  activeSpeakerId: null,
  items: [],
  selectedItemId: null,
  currentBlob: null,
  currentAudioUrl: null,
  isBusy: false,
};

const el = Object.fromEntries([
  "tts-form", "drop-zone", "text-file-input", "txt-input", "char-count",
  "clear-text-btn", "save-snippet-btn", "files-section", "files-list",
  "files-count", "clear-all-files", "language-select", "speaker-controls",
  "speaker-select", "speed-slider", "speed-value", "form-error",
  "speak-button", "speak-button-text", "job-panel", "status-badge",
  "progress-bar", "progress-title", "progress-detail", "result-panel",
  "result-meta", "audio-player", "copy-text-btn", "download-button"
].map((id) => [id, document.getElementById(id)]));

function formatBytes(bytes) {
  if (!Number.isFinite(bytes) || bytes <= 0) return "0 B";
  const units = ["B", "KiB", "MiB"];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return `${value.toFixed(unit ? 1 : 0)} ${units[unit]}`;
}

function showError(message) {
  if (!el["form-error"]) return;
  el["form-error"].textContent = message;
  el["form-error"].hidden = !message;
}

function updateCharCount() {
  const text = el["txt-input"].value || "";
  const count = text.length;
  el["char-count"].textContent = `${count.toLocaleString()} character${count === 1 ? "" : "s"}`;
  if (count > MAX_TEXT_LENGTH) {
    showError(`Text length (${count.toLocaleString()} chars) exceeds the 64 KiB limit.`);
    el["speak-button"].disabled = true;
  } else {
    if (el["form-error"].textContent.includes("64 KiB limit")) {
      showError("");
    }
    el["speak-button"].disabled = state.isBusy || count === 0;
  }
}

function updateSpeedDisplay() {
  const lengthScale = parseFloat(el["speed-slider"].value) || 1.0;
  const speedMultiplier = 1 / lengthScale;
  let label = `${speedMultiplier.toFixed(2)}×`;
  if (Math.abs(lengthScale - 1.0) < 0.03) {
    label += " (Normal)";
  } else if (lengthScale < 1.0) {
    label += " (Faster)";
  } else {
    label += " (Slower)";
  }
  el["speed-value"].textContent = label;
}

// ----------------------------------------------------------------------------
// IndexedDB Persistence
// ----------------------------------------------------------------------------

function openDb() {
  return new Promise((resolve) => {
    if (!window.indexedDB) return resolve(null);
    try {
      const req = window.indexedDB.open(DB_NAME, DB_VERSION);
      req.onupgradeneeded = (e) => {
        const db = e.target.result;
        if (!db.objectStoreNames.contains(STORE_NAME)) {
          db.createObjectStore(STORE_NAME, { keyPath: "id" });
        }
      };
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => resolve(null);
    } catch (_) {
      resolve(null);
    }
  });
}

async function dbSaveItem(item) {
  const db = await openDb();
  if (!db) return;
  try {
    const tx = db.transaction(STORE_NAME, "readwrite");
    tx.objectStore(STORE_NAME).put({
      id: item.id,
      name: item.name,
      text: item.text,
      charCount: item.charCount,
      isFile: item.isFile,
      createdAt: item.createdAt,
      language: item.language,
      audioBlob: item.audioBlob || null,
    });
  } catch (_) {}
}

async function dbDeleteItem(id) {
  const db = await openDb();
  if (!db) return;
  try {
    const tx = db.transaction(STORE_NAME, "readwrite");
    tx.objectStore(STORE_NAME).delete(id);
  } catch (_) {}
}

async function dbClearAll() {
  const db = await openDb();
  if (!db) return;
  try {
    const tx = db.transaction(STORE_NAME, "readwrite");
    tx.objectStore(STORE_NAME).clear();
  } catch (_) {}
}

async function dbLoadAll() {
  const db = await openDb();
  if (!db) return [];
  return new Promise((resolve) => {
    try {
      const tx = db.transaction(STORE_NAME, "readonly");
      const req = tx.objectStore(STORE_NAME).getAll();
      req.onsuccess = () => {
        const items = req.result || [];
        items.sort((a, b) => (b.createdAt || 0) - (a.createdAt || 0));
        resolve(items.slice(0, MAX_ITEMS));
      };
      req.onerror = () => resolve([]);
    } catch (_) {
      resolve([]);
    }
  });
}

// ----------------------------------------------------------------------------
// Items & Queue Management
// ----------------------------------------------------------------------------

function renderItemsList() {
  const count = state.items.length;
  el["files-section"].hidden = count === 0;
  el["files-count"].textContent = `${count} / ${MAX_ITEMS}`;
  el["files-list"].replaceChildren();

  for (const item of state.items) {
    const isSelected = item.id === state.selectedItemId;
    const row = document.createElement("div");
    row.className = `file-item${isSelected ? " selected" : ""}`;
    row.setAttribute("role", "button");
    row.setAttribute("tabindex", "0");
    row.setAttribute("aria-selected", isSelected ? "true" : "false");

    const mark = document.createElement("div");
    mark.className = "file-mark";
    mark.setAttribute("aria-hidden", "true");
    mark.textContent = item.isFile ? "📄" : "✍️";

    const copy = document.createElement("div");
    copy.className = "file-copy";

    const title = document.createElement("strong");
    title.textContent = item.name;

    const meta = document.createElement("span");
    const langDisplay = item.language ? ` · ${item.language}` : "";
    const audioReady = item.audioBlob ? " · 🎵 Audio ready" : "";
    meta.textContent = `${item.charCount.toLocaleString()} chars${langDisplay}${audioReady}`;

    copy.appendChild(title);
    copy.appendChild(meta);

    const actions = document.createElement("div");
    actions.className = "file-actions";

    if (item.audioBlob) {
      const audioBadge = document.createElement("span");
      audioBadge.className = "file-badge audio-badge";
      audioBadge.textContent = "Audio";
      actions.appendChild(audioBadge);
    }

    if (isSelected) {
      const badge = document.createElement("span");
      badge.className = "file-badge";
      badge.textContent = "Selected";
      actions.appendChild(badge);
    }

    const removeBtn = document.createElement("button");
    removeBtn.type = "button";
    removeBtn.className = "remove-file-btn";
    removeBtn.setAttribute("aria-label", `Remove ${item.name}`);
    removeBtn.textContent = "×";
    removeBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      removeItem(item.id);
    });
    actions.appendChild(removeBtn);

    row.appendChild(mark);
    row.appendChild(copy);
    row.appendChild(actions);

    row.addEventListener("click", () => selectItem(item.id));
    row.addEventListener("keydown", (e) => {
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault();
        selectItem(item.id);
      }
    });

    el["files-list"].appendChild(row);
  }
}

function selectItem(itemId) {
  const item = state.items.find((i) => i.id === itemId);
  if (!item) {
    state.selectedItemId = null;
    renderItemsList();
    return;
  }

  state.selectedItemId = item.id;
  el["txt-input"].value = item.text;
  updateCharCount();

  if (item.language && state.languages.includes(item.language)) {
    el["language-select"].value = item.language;
    handleLanguageChange(item.language);
  }

  if (item.audioBlob) {
    displayAudioResult(item.audioBlob, item.text, item.language || state.activeLanguage);
  }

  renderItemsList();
}

function addItem(name, text, isFile = false, audioBlob = null) {
  showError("");
  if (!text || !text.trim()) return;

  const id = `item_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`;
  const item = {
    id,
    name: name || text.slice(0, 35) + (text.length > 35 ? "…" : ""),
    text: text.trim(),
    charCount: text.trim().length,
    isFile: !!isFile,
    createdAt: Date.now(),
    language: el["language-select"].value || state.activeLanguage,
    audioBlob: audioBlob || null,
  };

  state.items.unshift(item);

  while (state.items.length > MAX_ITEMS) {
    const removed = state.items.pop();
    dbDeleteItem(removed.id);
  }

  dbSaveItem(item);
  renderItemsList();
  selectItem(id);
}

function removeItem(itemId) {
  const index = state.items.findIndex((i) => i.id === itemId);
  if (index === -1) return;
  state.items.splice(index, 1);
  dbDeleteItem(itemId);

  if (state.selectedItemId === itemId) {
    if (state.items.length > 0) {
      const nextIndex = Math.min(index, state.items.length - 1);
      selectItem(state.items[nextIndex].id);
    } else {
      state.selectedItemId = null;
      renderItemsList();
    }
  } else {
    renderItemsList();
  }
}

function clearAllItems() {
  state.items = [];
  state.selectedItemId = null;
  el["text-file-input"].value = "";
  dbClearAll();
  renderItemsList();
}

// ----------------------------------------------------------------------------
// File Upload & Drag-and-Drop
// ----------------------------------------------------------------------------

function handleFiles(fileList) {
  if (!fileList || !fileList.length) return;
  const files = Array.from(fileList);

  for (const file of files) {
    if (file.size > MAX_TEXT_LENGTH) {
      showError(`File "${file.name}" is ${formatBytes(file.size)}; maximum allowed is 64 KiB.`);
      continue;
    }
    const reader = new FileReader();
    reader.onload = (e) => {
      const content = e.target?.result;
      if (typeof content === "string" && content.trim()) {
        addItem(file.name, content, true);
      }
    };
    reader.onerror = () => {
      showError(`Could not read file "${file.name}".`);
    };
    reader.readAsText(file);
  }
}

// ----------------------------------------------------------------------------
// Language & Speaker Management
// ----------------------------------------------------------------------------

const languageDisplayNames = {
  pt_br: "Portuguese (Brazil)",
  en_us: "English (US)",
  zh_cn: "Chinese (Mandarin)",
  de_de: "German",
  fr_fr: "French",
  it_it_serena: "Italian (Serena, High)",
  it_it_riccardo: "Italian (Riccardo, X-Low)",
};

async function loadVoicesAndLanguages() {
  try {
    const [voicesRes, langRes] = await Promise.allSettled([
      fetch("/v1/audio/voices", { cache: "no-store" }).then((r) => r.ok ? r.json() : null),
      fetch("/api/v1/languages", { cache: "no-store" }).then((r) => r.ok ? r.json() : null)
    ]);

    const voiceList = voicesRes.status === "fulfilled" && voicesRes.value?.data ? voicesRes.value.data : [];
    const langData = langRes.status === "fulfilled" && langRes.value ? langRes.value : { languages: [], active: "pt_br" };

    state.languages = langData.languages && langData.languages.length ? langData.languages : voiceList.map((v) => v.id);
    state.activeLanguage = langData.active || (state.languages[0] || "pt_br");

    el["language-select"].replaceChildren();
    for (const lang of state.languages) {
      const opt = document.createElement("option");
      opt.value = lang;
      const matchedVoice = voiceList.find((v) => v.id === lang || v.model === lang);
      opt.textContent = matchedVoice?.name || languageDisplayNames[lang] || lang;
      el["language-select"].appendChild(opt);
    }

    if (state.languages.includes(state.activeLanguage)) {
      el["language-select"].value = state.activeLanguage;
    }

    await loadSpeakers();
  } catch (err) {
    console.error("Error loading voice configuration:", err);
  }
}

async function loadSpeakers() {
  try {
    const res = await fetch("/api/v1/speakers", { cache: "no-store" });
    if (!res.ok) return;
    const speakers = await res.json();
    state.speakers = speakers || {};

    const speakerKeys = Object.keys(state.speakers);
    if (speakerKeys.length <= 1) {
      el["speaker-controls"].hidden = true;
      state.activeSpeakerId = speakerKeys.length === 1 ? state.speakers[speakerKeys[0]] : null;
    } else {
      el["speaker-controls"].hidden = false;
      el["speaker-select"].replaceChildren();
      for (const key of speakerKeys) {
        const opt = document.createElement("option");
        opt.value = state.speakers[key];
        opt.textContent = key;
        el["speaker-select"].appendChild(opt);
      }
      state.activeSpeakerId = state.speakers[speakerKeys[0]];
    }
  } catch (_) {
    el["speaker-controls"].hidden = true;
  }
}

async function handleLanguageChange(newLang) {
  state.activeLanguage = newLang;
  await loadSpeakers();
}

// ----------------------------------------------------------------------------
// Speech Synthesis
// ----------------------------------------------------------------------------

function setBusy(busy) {
  state.isBusy = busy;
  el["speak-button"].disabled = busy || !el["txt-input"].value.trim();
  el["speak-button-text"].textContent = busy ? "Synthesizing…" : "Generate Speech";
  el["job-panel"].hidden = !busy;
  if (busy) {
    el["status-badge"].textContent = "Processing";
    el["status-badge"].classList.remove("failed");
    el["result-panel"].hidden = true;
  }
}

function displayAudioResult(blob, text, language) {
  state.currentBlob = blob;
  if (state.currentAudioUrl) {
    URL.revokeObjectURL(state.currentAudioUrl);
  }
  state.currentAudioUrl = URL.createObjectURL(blob);
  el["audio-player"].src = state.currentAudioUrl;
  el["result-panel"].hidden = false;

  const lengthScale = parseFloat(el["speed-slider"].value) || 1.0;
  const speedX = (1 / lengthScale).toFixed(2);

  el["result-meta"].replaceChildren();
  const chips = [
    `Language: ${languageDisplayNames[language] || language}`,
    `Speed: ${speedX}×`,
    `Size: ${formatBytes(blob.size)}`,
    `Format: Ogg Opus (24kHz)`
  ];

  if (!el["speaker-controls"].hidden && el["speaker-select"].value !== "") {
    const speakerText = el["speaker-select"].selectedOptions[0]?.textContent || "Speaker";
    chips.splice(1, 0, `Speaker: ${speakerText}`);
  }

  for (const text of chips) {
    const chip = document.createElement("span");
    chip.textContent = text;
    el["result-meta"].appendChild(chip);
  }

  el["result-panel"].scrollIntoView({ behavior: "smooth", block: "nearest" });
}

async function runSynthesis() {
  showError("");
  const text = el["txt-input"].value.trim();
  if (!text) {
    showError("Please enter text to synthesize.");
    return;
  }

  const language = el["language-select"].value || state.activeLanguage;
  const lengthScale = parseFloat(el["speed-slider"].value) || 1.0;
  let speakerId = null;

  if (!el["speaker-controls"].hidden && el["speaker-select"].value !== "") {
    speakerId = parseInt(el["speaker-select"].value, 10);
  }

  setBusy(true);

  try {
    const payload = {
      text: text,
      language: language,
      length_scale: lengthScale,
      audio_format: "opus",
    };
    if (speakerId !== null && Number.isInteger(speakerId)) {
      payload.speaker_id = speakerId;
    }

    const response = await fetch("/api/v1/synthesise", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });

    if (!response.ok) {
      let errMsg = `Synthesis failed (HTTP ${response.status}).`;
      try {
        const errText = await response.text();
        if (errText) errMsg = errText;
      } catch (_) {}
      throw new Error(errMsg);
    }

    const blob = await response.blob();
    setBusy(false);

    displayAudioResult(blob, text, language);

    // Save audio blob to the active item or create new snippet in queue
    if (state.selectedItemId) {
      const item = state.items.find((i) => i.id === state.selectedItemId);
      if (item) {
        item.audioBlob = blob;
        item.text = text;
        item.language = language;
        dbSaveItem(item);
        renderItemsList();
      }
    } else {
      addItem(null, text, false, blob);
    }

    // Auto play
    try {
      el["audio-player"].play();
    } catch (_) {}

  } catch (error) {
    setBusy(false);
    showError(error.message || "An unexpected error occurred during synthesis.");
  }
}

// ----------------------------------------------------------------------------
// Audio Download & Text Copy
// ----------------------------------------------------------------------------

function downloadAudio() {
  if (!state.currentBlob) return;
  const url = URL.createObjectURL(state.currentBlob);
  const a = document.createElement("a");
  a.href = url;
  const lang = el["language-select"].value || "speech";
  const stamp = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19);
  a.download = `paroli-${lang}-${stamp}.ogg`;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

async function copyText() {
  const text = el["txt-input"].value;
  try {
    await navigator.clipboard.writeText(text);
    el["copy-text-btn"].textContent = "Copied!";
    setTimeout(() => {
      el["copy-text-btn"].textContent = "Copy text";
    }, 1500);
  } catch (_) {
    el["txt-input"].select();
  }
}

// ----------------------------------------------------------------------------
// Event Listeners & Startup
// ----------------------------------------------------------------------------

el["txt-input"].addEventListener("input", updateCharCount);
el["speed-slider"].addEventListener("input", updateSpeedDisplay);

el["clear-text-btn"].addEventListener("click", () => {
  el["txt-input"].value = "";
  updateCharCount();
  el["txt-input"].focus();
});

el["save-snippet-btn"].addEventListener("click", () => {
  const text = el["txt-input"].value.trim();
  if (text) addItem(null, text, false);
});

el["clear-all-files"].addEventListener("click", clearAllItems);
el["language-select"].addEventListener("change", (e) => handleLanguageChange(e.target.value));

el["tts-form"].addEventListener("submit", (e) => {
  e.preventDefault();
  runSynthesis();
});

el["copy-text-btn"].addEventListener("click", copyText);
el["download-button"].addEventListener("click", downloadAudio);

// Drag and drop for drop zone
["dragenter", "dragover"].forEach((eventName) => {
  el["drop-zone"].addEventListener(eventName, (e) => {
    e.preventDefault();
    el["drop-zone"].classList.add("dragging");
  });
});

["dragleave", "drop"].forEach((eventName) => {
  el["drop-zone"].addEventListener(eventName, (e) => {
    e.preventDefault();
    el["drop-zone"].classList.remove("dragging");
  });
});

el["drop-zone"].addEventListener("drop", (e) => {
  e.preventDefault();
  el["drop-zone"].classList.remove("dragging");
  if (e.dataTransfer?.files?.length) {
    handleFiles(e.dataTransfer.files);
  }
});

el["text-file-input"].addEventListener("change", (e) => {
  if (e.target.files?.length) {
    handleFiles(e.target.files);
    e.target.value = "";
  }
});

// Initialization
async function init() {
  updateCharCount();
  updateSpeedDisplay();
  await loadVoicesAndLanguages();

  const saved = await dbLoadAll();
  for (const item of saved) {
    state.items.push(item);
  }
  if (state.items.length > 0) {
    renderItemsList();
  }
}

window.addEventListener("DOMContentLoaded", init);
