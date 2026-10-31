//! What the settings window can ask for. No command ever returns a cookie.

use crate::secrets::{self, BrowserKeys};
use crate::autostart;
use crate::settings::ClaudeSource;
use crate::state::{Shared, lock, now};
use crate::{telemetry, tray};
use limitfuel_core::cookies;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tauri::{AppHandle, State};

type SharedState<'a> = State<'a, Arc<Shared>>;

fn saved(app: &AppHandle, shared: &Shared) -> Result<(), String> {
    let result = lock(&shared.settings).save().map_err(|_| "Settings could not be saved.".to_string());
    tray::refresh(app, shared);
    result
}

#[tauri::command]
pub fn get_state(shared: SharedState<'_>) -> Value {
    let mut state = shared.snapshot();
    state["autostart"] = json!(autostart::enabled());
    state
}

#[tauri::command]
pub fn refresh(shared: SharedState<'_>) {
    shared.wake_cookie.notify();
    shared.wake_claude.notify();
    shared.wake_codex.notify();
}

/// Explicit detection: the only path that may unlock the keyring (a prompt).
#[tauri::command]
pub async fn detect_browsers(app: AppHandle, shared: SharedState<'_>) -> Result<Value, String> {
    let shared = shared.inner().clone();
    let worker = shared.clone();
    let result = tauri::async_runtime::spawn_blocking(move || {
        let shared = worker;
        let browsers = secrets::browsers();
        if browsers.is_empty() {
            return json!({"found": 0, "errors": ["No config directory."]});
        }
        let mut found = Vec::new();
        let mut errors = Vec::new();
        for browser in browsers {
            if !browser.root.exists() {
                continue;
            }
            let keys = BrowserKeys::for_browser(&browser);
            match cookies::discover_with(secrets::SCHEME, &browser.root, None, true, now(), &keys) {
                Ok(sessions) => found.extend(sessions.into_iter().map(|s| (browser.name.to_string(), s))),
                Err(error) => errors.push(format!("{}: {}", browser.name, error.message())),
            }
        }
        let count = found.len();
        *lock(&shared.detected) = found;
        if count == 1 {
            let (browser, session) = lock(&shared.detected)[0].clone();
            connect_session(&shared, &browser, session);
        } else if count == 0 && errors.is_empty() {
            errors.push(if cfg!(windows) {
                "No signed-in Claude session found in Chrome, Edge, Brave or Chromium. Paste a cookie instead.".into()
            } else {
                "No signed-in Claude session found in Chrome, Chromium or Brave. Sign in to claude.ai, then detect again.".into()
            });
        }
        json!({"found": count, "errors": errors})
    })
    .await
    .map_err(|_| "Detection failed.".to_string())?;
    saved(&app, &shared)?;
    Ok(result)
}

fn connect_session(shared: &Shared, browser: &str, session: cookies::ChromeSession) {
    {
        let mut settings = lock(&shared.settings);
        settings.claude_source = ClaudeSource::Browser;
        settings.browser = Some(browser.to_string());
        settings.profile_id = Some(session.profile.id.clone());
    }
    // A pasted cookie no longer in use is not kept around.
    secrets::delete_cookie();
    *lock(&shared.cookie) = Some(session.cookie_header);
    *lock(&shared.browser_message) = None;
    lock(&shared.detected).clear();
    shared.bump_revision();
    shared.wake_claude.notify();
}

#[tauri::command]
pub fn use_profile(app: AppHandle, shared: SharedState<'_>, browser: String, profile_id: String) -> Result<(), String> {
    let session = lock(&shared.detected)
        .iter()
        .find(|(b, s)| *b == browser && s.profile.id == profile_id)
        .map(|(_, s)| s.clone())
        .ok_or("That profile is no longer available. Detect again.")?;
    connect_session(&shared, &browser, session);
    saved(&app, &shared)
}

#[tauri::command]
pub async fn save_cookie(app: AppHandle, shared: SharedState<'_>, header: String) -> Result<Value, String> {
    let header = header.trim().to_string();
    if !cookies::validate_header(&header) {
        return Err("That is not a valid Claude cookie header. Copy the whole Cookie value, including sessionKey.".into());
    }
    let to_store = header.clone();
    let stored = tauri::async_runtime::spawn_blocking(move || secrets::store_cookie(&to_store)).await.unwrap_or(false);
    {
        let mut settings = lock(&shared.settings);
        settings.claude_source = ClaudeSource::Pasted;
        settings.browser = None;
        settings.profile_id = None;
    }
    *lock(&shared.cookie) = Some(header);
    *lock(&shared.browser_message) = (!stored).then(|| {
        if cfg!(windows) {
            "Saved for this session only: Windows Credential Manager could not store it.".to_string()
        } else {
            "Saved for this session only: no unlocked keyring (Secret Service) is available.".to_string()
        }
    });
    shared.bump_revision();
    shared.wake_claude.notify();
    saved(&app, &shared)?;
    Ok(json!({"stored": stored}))
}

#[tauri::command]
pub fn disconnect_claude(app: AppHandle, shared: SharedState<'_>) -> Result<(), String> {
    {
        let mut settings = lock(&shared.settings);
        settings.claude_source = ClaudeSource::None;
        settings.browser = None;
        settings.profile_id = None;
    }
    secrets::delete_cookie();
    *lock(&shared.cookie) = None;
    *lock(&shared.browser_message) = None;
    shared.bump_revision();
    shared.wake_claude.notify();
    saved(&app, &shared)
}

#[tauri::command]
pub fn set_codex_path(app: AppHandle, shared: SharedState<'_>, path: String) -> Result<(), String> {
    let path = path.trim();
    if !path.is_empty() && !Path::new(path).is_absolute() {
        return Err(if cfg!(windows) {
            r"Use an absolute path, such as C:\Users\you\AppData\Roaming\npm\codex.cmd.".into()
        } else {
            "Use an absolute path, such as /usr/local/bin/codex.".into()
        });
    }
    lock(&shared.settings).codex_path = (!path.is_empty()).then(|| path.to_string());
    shared.wake_codex.notify();
    saved(&app, &shared)
}

#[tauri::command]
pub fn set_preference(app: AppHandle, shared: SharedState<'_>, key: String, value: Value) -> Result<(), String> {
    let mut settings = lock(&shared.settings);
    match (key.as_str(), &value) {
        ("claudeWindow", Value::String(id)) if id.len() <= 4096 => settings.claude_window = id.clone(),
        ("codexWindow", Value::String(id)) if id.len() <= 4096 => settings.codex_window = id.clone(),
        ("percentageMode", Value::String(mode)) if mode == "used" || mode == "remaining" => {
            settings.percentage_mode = mode.clone()
        }
        ("notifications", Value::Bool(on)) => settings.notifications = *on,
        ("diagnostics", Value::Bool(on)) => {
            settings.diagnostics = *on;
            telemetry::set_enabled(*on);
            // Off and on again forgets failures but keeps the hourly cap.
            lock(&shared.policy).reset();
        }
        ("autostart", Value::Bool(on)) => {
            drop(settings);
            autostart::set(*on).map_err(|_| "Open at login could not be changed.".to_string())?;
            tray::refresh(&app, &shared);
            return Ok(());
        }
        _ => return Err("Unknown setting.".into()),
    }
    drop(settings);
    saved(&app, &shared)
}

#[tauri::command]
pub fn detected_codex(shared: SharedState<'_>) -> Option<String> {
    let custom = lock(&shared.settings).codex_path.clone().filter(|p| !p.is_empty()).map(PathBuf::from);
    let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("/"));
    limitfuel_core::codex::resolve_executable(custom.as_deref(), std::env::var("PATH").ok().as_deref(), &home)
        .map(|p| p.display().to_string())
}
