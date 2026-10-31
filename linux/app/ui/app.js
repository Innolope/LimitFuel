"use strict";

const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;
const $ = (id) => document.getElementById(id);

let state = null;
let platformShown = false;

// The window is shared by Linux and Windows; only the text and the order differ.
function showPlatform() {
  if (platformShown) return;
  platformShown = true;
  for (const element of document.querySelectorAll("[data-platform]")) {
    element.hidden = element.dataset.platform !== state.platform;
  }
  if (state.platform !== "windows") return;
  // Pasting is the main path on Windows; detection is a secondary try.
  const paste = $("paste");
  paste.open = true;
  $("detect-row").before(paste);
  $("paste-summary").textContent = "Paste your claude.ai cookie";
  $("detect").textContent = "Try browser detection";
  $("detect").classList.replace("primary", "ghost");
}

const isWindows = () => state?.platform === "windows";

function relative(seconds) {
  if (seconds == null) return "";
  const age = Math.max(0, Date.now() / 1000 - seconds);
  if (age < 60) return "Updated just now";
  if (age < 3600) return `Updated ${Math.floor(age / 60)} min ago`;
  return `Updated ${Math.floor(age / 3600)} h ago`;
}

function setMessage(element, text, ok = false) {
  element.hidden = !text;
  element.textContent = text || "";
  element.classList.toggle("ok", ok);
}

function renderProvider(name, provider, connectedHint) {
  const meters = $(`${name}-meters`);
  meters.replaceChildren();
  meters.classList.toggle("stale-values", provider.stale);
  const suffix = state.settings.percentage_mode === "used" ? "used" : "left";
  for (const entry of provider.windows) {
    const meter = document.createElement("div");
    // Windows has no tray label; its tooltip lists every window.
    meter.className = "meter" + (entry.selected && !isWindows() ? " in-tray" : "");
    const head = document.createElement("div");
    head.className = "meter-head";
    const label = document.createElement("span");
    label.className = "label";
    label.textContent = entry.label;
    const value = document.createElement("span");
    value.className = "value";
    value.textContent = `${entry.percent}% ${suffix}`;
    if (entry.reset) {
      const reset = document.createElement("span");
      reset.className = "reset";
      reset.textContent = ` · resets in ${entry.reset}`;
      value.append(reset);
    }
    head.append(label, value);
    const track = document.createElement("div");
    track.className = "track";
    const fill = document.createElement("div");
    fill.className = "fill";
    if (entry.used >= 90) fill.classList.add("danger");
    else if (entry.used >= 75) fill.classList.add("warn");
    fill.style.width = `${Math.round(Math.min(1, Math.max(0, entry.fraction)) * 100)}%`;
    track.append(fill);
    meter.append(head, track);
    meters.append(meter);
  }
  const badge = $(`${name}-badge`);
  badge.className = "badge";
  if (provider.windows.length && !provider.stale) {
    badge.textContent = provider.account || "Connected";
    badge.classList.add("ok");
  } else if (provider.windows.length) {
    badge.textContent = "Last known";
    badge.classList.add("stale");
  } else {
    badge.textContent = connectedHint;
  }
  setMessage($(`${name}-message`), provider.error);
  $(`${name}-updated`).textContent = relative(provider.updatedAt);
}

function fillSelect(select, provider, selectedId) {
  select.replaceChildren();
  const automatic = new Option("Automatic (session first)", "automatic");
  select.append(automatic);
  for (const entry of provider.windows) select.append(new Option(entry.label, entry.id));
  // A saved choice that is temporarily missing stays selected as Automatic in view only.
  select.value = [...select.options].some((o) => o.value === selectedId) ? selectedId : "automatic";
}

function render() {
  if (!state) return;
  showPlatform();
  $("version").textContent = `Version ${state.version}`;
  $("tray-warning").hidden = state.trayHost;
  renderProvider("claude", state.claude, state.connected ? "Connecting…" : "Not connected");
  renderProvider("codex", state.codex, "Not found");
  $("disconnect").hidden = !state.connected && state.settings.claude_source === "none";

  const profiles = state.detected || [];
  $("profiles").hidden = profiles.length < 2;
  const list = $("profile-list");
  list.replaceChildren();
  for (const profile of profiles) {
    const button = document.createElement("button");
    button.type = "button";
    const name = document.createElement("span");
    name.textContent = profile.name;
    const browser = document.createElement("span");
    browser.className = "browser";
    browser.textContent = profile.browser;
    button.append(name, browser);
    button.addEventListener("click", () => run(button, () =>
      invoke("use_profile", { browser: profile.browser, profileId: profile.id })));
    list.append(button);
  }
  if (state.browserMessage) setMessage($("connect-message"), state.browserMessage);

  if (document.activeElement !== $("codex-path")) $("codex-path").value = state.settings.codex_path || "";
  fillSelect($("claude-window"), state.claude, state.settings.claude_window);
  fillSelect($("codex-window"), state.codex, state.settings.codex_window);
  for (const button of document.querySelectorAll(".segmented button")) {
    button.setAttribute("aria-checked", String(button.dataset.mode === state.settings.percentage_mode));
  }
  $("notifications").checked = state.settings.notifications;
  $("autostart").checked = state.autostart;
  $("diagnostics").checked = state.settings.diagnostics;
  $("diagnostics").disabled = !state.reportingConfigured;
}

async function reload() {
  state = await invoke("get_state");
  render();
}

async function run(button, action) {
  if (button) button.disabled = true;
  try {
    return await action();
  } catch (error) {
    setMessage($("connect-message"), String(error));
  } finally {
    if (button) button.disabled = false;
    await reload();
  }
}

async function detectCodexPlaceholder() {
  const path = await invoke("detected_codex");
  $("codex-path").placeholder = path ? `Found: ${path}` : "Not found; enter the path to codex";
}

$("refresh").addEventListener("click", (e) => run(e.currentTarget, () => invoke("refresh")));
$("detect").addEventListener("click", (e) => run(e.currentTarget, async () => {
  setMessage($("connect-message"), isWindows()
    ? "Looking for a signed-in claude.ai session…"
    : "Looking for a signed-in claude.ai session… Your keyring may ask to unlock.", true);
  const result = await invoke("detect_browsers");
  if (result.found === 1) setMessage($("connect-message"), "Connected.", true);
  else if (result.found > 1) setMessage($("connect-message"), "");
  else setMessage($("connect-message"), result.errors.join("\n"));
}));
$("disconnect").addEventListener("click", (e) => run(e.currentTarget, async () => {
  await invoke("disconnect_claude");
  setMessage($("connect-message"), "Disconnected.", true);
}));
$("save-cookie").addEventListener("click", (e) => run(e.currentTarget, async () => {
  const result = await invoke("save_cookie", { header: $("cookie").value });
  $("cookie").value = "";
  const saved = isWindows() ? "Cookie saved to Windows Credential Manager." : "Cookie saved to your keyring.";
  setMessage($("connect-message"), result.stored ? saved : state?.browserMessage || "Cookie in use.", true);
}));
$("save-codex").addEventListener("click", (e) => run(e.currentTarget, async () => {
  await invoke("set_codex_path", { path: $("codex-path").value });
  await detectCodexPlaceholder();
}));
for (const [id, key] of [["claude-window", "claudeWindow"], ["codex-window", "codexWindow"]]) {
  $(id).addEventListener("change", (e) => run(null, () => invoke("set_preference", { key, value: e.target.value })));
}
for (const button of document.querySelectorAll(".segmented button")) {
  button.addEventListener("click", () => run(null, () =>
    invoke("set_preference", { key: "percentageMode", value: button.dataset.mode })));
}
for (const id of ["notifications", "autostart", "diagnostics"]) {
  $(id).addEventListener("change", (e) => run(null, () => invoke("set_preference", { key: id, value: e.target.checked })));
}

let pending = null;
listen("state-changed", () => {
  // Poll threads can emit in bursts; one redraw per frame is enough.
  if (pending) return;
  pending = requestAnimationFrame(() => { pending = null; reload(); });
});
setInterval(render, 30_000);
reload();
detectCodexPlaceholder();
