//! State shared by the poll threads, the tray and the settings window.

use crate::settings::Settings;
use limitfuel_core::cookies::ChromeSession;
use limitfuel_core::diagnostics::ReportPolicy;
use limitfuel_core::display::{self, WindowOption};
use limitfuel_core::notify::ThresholdTracker;
use serde_json::{Value, json};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Condvar, Mutex, MutexGuard};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// Release names, Sentry tags and the settings window's text depend on this.
pub const PLATFORM: &str = if cfg!(windows) { "windows" } else { "linux" };

pub fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

pub fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    // A panicked poll thread must not take the tray down with it.
    mutex.lock().unwrap_or_else(|e| e.into_inner())
}

#[derive(Clone, Debug, Default)]
pub struct ProviderState {
    pub windows: Vec<WindowOption>,
    pub updated_at: Option<f64>,
    pub stale: bool,
    pub error: Option<String>,
    pub account: Option<String>,
    pub last_started: Option<f64>,
}

/// Wakes one poll thread early: Refresh Now, or a connection change.
#[derive(Default)]
pub struct Wake {
    generation: Mutex<u64>,
    signal: Condvar,
}

impl Wake {
    pub fn notify(&self) {
        *lock(&self.generation) += 1;
        self.signal.notify_all();
    }

    /// Read before checking a condition, then pass to `wait_from`, so a notify
    /// that lands in between is never lost.
    pub fn generation(&self) -> u64 {
        *lock(&self.generation)
    }

    /// Sleeps up to `seconds`, returning early once notified after `start`.
    pub fn wait_from(&self, start: u64, seconds: f64) {
        let guard = lock(&self.generation);
        let timeout = Duration::from_secs_f64(seconds.clamp(0.0, 86_400.0));
        let _ = self.signal.wait_timeout_while(guard, timeout, |generation| *generation == start);
    }
}

#[derive(Default)]
pub struct Shared {
    pub settings: Mutex<Settings>,
    pub claude: Mutex<ProviderState>,
    pub codex: Mutex<ProviderState>,
    /// The Claude cookie in use. Never written to disk by this app.
    pub cookie: Mutex<Option<String>>,
    pub browser_message: Mutex<Option<String>>,
    /// Sessions from the last explicit detection, waiting for a profile choice.
    pub detected: Mutex<Vec<(String, ChromeSession)>>,
    /// Bumped whenever the Claude connection changes; older results are dropped.
    pub revision: AtomicU64,
    pub wake_claude: Wake,
    pub wake_codex: Wake,
    pub wake_cookie: Wake,
    pub policy: Mutex<ReportPolicy>,
    pub thresholds: Mutex<ThresholdTracker>,
    pub tray_host: std::sync::atomic::AtomicBool,
}

impl Shared {
    pub fn new(settings: Settings) -> Self {
        Self { settings: Mutex::new(settings), ..Default::default() }
    }

    pub fn bump_revision(&self) {
        self.revision.fetch_add(1, Ordering::SeqCst);
    }

    pub fn revision(&self) -> u64 {
        self.revision.load(Ordering::SeqCst)
    }

    /// The window each provider shows in the tray, by the saved choice.
    pub fn selected(&self) -> (Option<WindowOption>, Option<WindowOption>) {
        let settings = lock(&self.settings).clone();
        let claude = lock(&self.claude).windows.clone();
        let codex = lock(&self.codex).windows.clone();
        (
            display::select_option(display::Provider::Claude, &claude, Some(&settings.claude_window)).cloned(),
            display::select_option(display::Provider::Codex, &codex, Some(&settings.codex_window)).cloned(),
        )
    }

    pub fn tray_label(&self) -> String {
        let (claude, codex) = self.selected();
        let mode = lock(&self.settings).mode();
        display::tray_label(claude.as_ref(), codex.as_ref(), mode, now())
    }

    /// Everything the settings window renders. Contains no cookie.
    pub fn snapshot(&self) -> Value {
        let settings = lock(&self.settings).clone();
        let mode = settings.mode();
        let (claude_selected, codex_selected) = self.selected();
        let now = now();
        let provider = |state: &ProviderState, selected: &Option<WindowOption>| {
            json!({
                "windows": state.windows.iter().map(|w| json!({
                    "id": w.id,
                    "label": w.label,
                    "percent": mode.displayed_percent(w.percent),
                    "used": w.percent,
                    "fraction": mode.displayed_percent(w.percent) as f64 / 100.0,
                    "reset": display::reset_label(w.resets_at, now),
                    "selected": selected.as_ref().is_some_and(|s| s.id == w.id),
                })).collect::<Vec<_>>(),
                "updatedAt": state.updated_at,
                "stale": state.stale,
                "error": state.error,
                "account": state.account,
            })
        };
        let detected = lock(&self.detected)
            .iter()
            .map(|(browser, session)| json!({"browser": browser, "id": session.profile.id, "name": session.profile.name}))
            .collect::<Vec<_>>();
        json!({
            "version": env!("CARGO_PKG_VERSION"),
            "platform": PLATFORM,
            "claude": provider(&lock(&self.claude), &claude_selected),
            "codex": provider(&lock(&self.codex), &codex_selected),
            "connected": lock(&self.cookie).is_some(),
            "browserMessage": *lock(&self.browser_message),
            "detected": detected,
            "settings": settings,
            "secretService": crate::secrets::available(),
            "trayHost": self.tray_host.load(Ordering::SeqCst),
            "reportingConfigured": crate::telemetry::is_configured(),
        })
    }
}
