//! One thread per provider, so a slow poll never overlaps the next one, plus the
//! hourly browser-cookie recheck.

use crate::secrets::BrowserKeys;
use crate::settings::ClaudeSource;
use crate::state::{Shared, lock, now};
use crate::{telemetry, tray};
use limitfuel_core::claude::{ClaudeClient, ClaudeError};
use limitfuel_core::codex::{self, CodexClient, CodexError};
use limitfuel_core::cookies::{self, CookieError};
use limitfuel_core::diagnostics::{DiagnosticCode, DiagnosticProvider};
use limitfuel_core::display::WindowOption;
use limitfuel_core::schedule;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tauri::AppHandle;
use tauri_plugin_notification::NotificationExt;

const CLAUDE_TIMEOUT: Duration = Duration::from_secs(20);

pub fn start(app: AppHandle, shared: Arc<Shared>) {
    load_initial_cookie(&shared);
    for poll in [claude_loop as fn(AppHandle, Arc<Shared>), codex_loop, cookie_loop, label_loop] {
        let (app, shared) = (app.clone(), shared.clone());
        std::thread::spawn(move || poll(app, shared));
    }
}

fn load_initial_cookie(shared: &Shared) {
    if lock(&shared.settings).claude_source == ClaudeSource::Pasted {
        match crate::secrets::load_cookie(false) {
            Some(cookie) if cookies::validate_header(&cookie) => *lock(&shared.cookie) = Some(cookie),
            _ => {
                *lock(&shared.browser_message) = Some(if cfg!(windows) {
                    "Your saved cookie could not be read from Windows Credential Manager. Paste it again in Settings.".into()
                } else {
                    "Your saved cookie could not be read; the keyring may be locked. Paste it again in Settings.".into()
                })
            }
        }
    }
}

fn report(shared: &Shared, provider: DiagnosticProvider, code: Option<DiagnosticCode>) {
    let Some(code) = code else { return };
    if !lock(&shared.settings).diagnostics {
        return;
    }
    if lock(&shared.policy).record_failure(provider, code, now(), telemetry::online()) {
        telemetry::report(provider, code);
    }
}

fn notify_thresholds(app: &AppHandle, shared: &Shared, provider: &str, windows: &[WindowOption]) {
    if !lock(&shared.settings).notifications {
        return;
    }
    for window in windows {
        let crossed = lock(&shared.thresholds).observe(&window.id, window.percent, window.resets_at);
        if let Some(threshold) = crossed {
            let _ = app
                .notification()
                .builder()
                .title(format!("{provider} usage"))
                .body(format!("{} reached {threshold}% used.", window.label))
                .show();
        }
    }
}

fn claude_loop(app: AppHandle, shared: Arc<Shared>) {
    loop {
        let generation = shared.wake_claude.generation();
        let (interval, last) = {
            let state = lock(&shared.claude);
            (schedule::polling_interval(&state.windows, now()), state.last_started)
        };
        // Poll at once on start and after a connection change; then on the cadence.
        let delay = if last.is_some() { schedule::next_poll_delay(interval, last, now()) } else { 0.0 };
        shared.wake_claude.wait_from(generation, delay);
        let generation = shared.wake_claude.generation();
        let Some(cookie) = lock(&shared.cookie).clone() else {
            let mut state = lock(&shared.claude);
            *state = Default::default();
            state.error = Some("Not connected. Open Settings to connect Claude.".into());
            drop(state);
            tray::refresh(&app, &shared);
            // Nothing to poll until a connection change wakes this thread.
            shared.wake_claude.wait_from(generation, 86_400.0);
            continue;
        };
        let revision = shared.revision();
        lock(&shared.claude).last_started = Some(now());
        let result = ClaudeClient::new("https://claude.ai", CLAUDE_TIMEOUT).fetch(&cookie);
        if shared.revision() != revision {
            continue; // The connection changed while this request ran.
        }
        let mut state = lock(&shared.claude);
        match result {
            Ok(windows) => {
                lock(&shared.policy).record_recovery(DiagnosticProvider::Claude);
                let session: Vec<WindowOption> = windows.iter().filter(|w| w.id == "claude:five_hour").cloned().collect();
                state.windows = windows;
                state.updated_at = Some(now());
                state.stale = false;
                state.error = None;
                drop(state);
                notify_thresholds(&app, &shared, "Claude", &session);
            }
            Err(error) => {
                if error == ClaudeError::SignIn {
                    state.windows.clear();
                    state.updated_at = None;
                }
                state.stale = !state.windows.is_empty();
                state.error = Some(claude_message(error).into());
                drop(state);
                report(&shared, DiagnosticProvider::Claude, error.into());
            }
        }
        tray::refresh(&app, &shared);
    }
}

fn claude_message(error: ClaudeError) -> &'static str {
    match error {
        ClaudeError::SignIn => "Claude signed you out. Detect your browser session again, or paste a new cookie.",
        ClaudeError::Offline => "Offline. Showing the last known values.",
        ClaudeError::Timeout => "claude.ai did not answer in time. Showing the last known values.",
        ClaudeError::Protocol => "claude.ai returned an unexpected response. Showing the last known values.",
        ClaudeError::InvalidData => "Claude usage is unavailable or in an unknown format.",
    }
}

fn codex_message(error: CodexError) -> &'static str {
    match error {
        CodexError::Unavailable => "Codex was not found. Install the Codex CLI or choose its path in Settings.",
        CodexError::SignIn => "Sign in to Codex with ChatGPT (`codex login`). API-key accounts have no plan limits.",
        CodexError::Protocol => "Codex could not read usage limits. Showing the last known values.",
        CodexError::Timeout => "Codex did not answer in time. Showing the last known values.",
        CodexError::InvalidData => "Codex returned limits in an unknown format. Update Codex and try again.",
    }
}

fn codex_executable(shared: &Shared) -> Option<PathBuf> {
    let custom = lock(&shared.settings).codex_path.clone().filter(|p| !p.is_empty()).map(PathBuf::from);
    let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("/"));
    codex::resolve_executable(custom.as_deref(), std::env::var("PATH").ok().as_deref(), &home)
}

fn codex_loop(app: AppHandle, shared: Arc<Shared>) {
    loop {
        let generation = shared.wake_codex.generation();
        let (interval, last) = {
            let state = lock(&shared.codex);
            (schedule::polling_interval(&state.windows, now()), state.last_started)
        };
        // Poll at once on start and after a connection change; then on the cadence.
        let delay = if last.is_some() { schedule::next_poll_delay(interval, last, now()) } else { 0.0 };
        shared.wake_codex.wait_from(generation, delay);
        lock(&shared.codex).last_started = Some(now());
        let result = match codex_executable(&shared) {
            Some(executable) => CodexClient { executable, timeout: codex::DEFAULT_TIMEOUT }.fetch(),
            None => Err(CodexError::Unavailable),
        };
        let mut state = lock(&shared.codex);
        match result {
            Ok(snapshot) => {
                lock(&shared.policy).record_recovery(DiagnosticProvider::Codex);
                let windows = snapshot.window_options();
                state.windows = windows.clone();
                state.account = snapshot.account_label;
                state.updated_at = Some(now());
                state.stale = false;
                state.error = None;
                drop(state);
                notify_thresholds(&app, &shared, "Codex", &windows);
            }
            Err(error) => {
                if matches!(error, CodexError::SignIn | CodexError::Unavailable) {
                    state.windows.clear();
                    state.updated_at = None;
                    state.account = None;
                }
                state.stale = !state.windows.is_empty();
                state.error = Some(codex_message(error).into());
                drop(state);
                report(&shared, DiagnosticProvider::Codex, error.into());
            }
        }
        tray::refresh(&app, &shared);
    }
}

pub fn browser_root(name: &str) -> Option<cookies::Browser> {
    crate::secrets::browsers().into_iter().find(|b| b.name == name)
}

/// Re-reads the chosen browser profile hourly. Never prompts for the keyring.
fn cookie_loop(app: AppHandle, shared: Arc<Shared>) {
    loop {
        let generation = shared.wake_cookie.generation();
        let settings = lock(&shared.settings).clone();
        if settings.claude_source == ClaudeSource::Browser {
            let browser = settings.browser.as_deref().and_then(browser_root);
            let result = match (browser, settings.profile_id.as_deref()) {
                (Some(browser), Some(profile)) => {
                    let keys = BrowserKeys::for_browser(&browser);
                    cookies::discover_with(crate::secrets::SCHEME, &browser.root, Some(profile), false, now(), &keys)
                }
                _ => Err(CookieError::Profile),
            };
            match result {
                Ok(sessions) => match sessions.into_iter().next() {
                    Some(session) => {
                        *lock(&shared.browser_message) = None;
                        let mut cookie = lock(&shared.cookie);
                        if cookie.as_deref() != Some(session.cookie_header.as_str()) {
                            *cookie = Some(session.cookie_header);
                            drop(cookie);
                            shared.bump_revision();
                            shared.wake_claude.notify();
                        }
                    }
                    None => {
                        *lock(&shared.browser_message) =
                            Some("No signed-in Claude session in that profile. Sign in to claude.ai, then detect again.".into())
                    }
                },
                Err(error) => {
                    *lock(&shared.browser_message) = Some(error.message().into());
                    // A background keyring denial is expected and says nothing about Claude.
                    if error != CookieError::Keyring {
                        report(&shared, DiagnosticProvider::Claude, error.into());
                    }
                }
            }
            tray::refresh(&app, &shared);
        }
        shared.wake_cookie.wait_from(generation, schedule::COOKIE_INTERVAL);
    }
}

/// Reset countdowns change every minute even when nothing is polled.
fn label_loop(app: AppHandle, shared: Arc<Shared>) {
    loop {
        std::thread::sleep(Duration::from_secs(30));
        tray::refresh(&app, &shared);
    }
}
