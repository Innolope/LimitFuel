//! The tray icon, its label and its menu. On Linux (StatusNotifierItem) a click
//! always opens the menu, so the menu carries every usage line. Windows has no
//! label next to the icon, so there the tooltip lists every limit too.

use crate::state::{ProviderState, Shared, lock, now};
use limitfuel_core::display;
use std::sync::{Arc, Mutex};
use tauri::image::Image;
use tauri::menu::{Menu, MenuBuilder, MenuItemBuilder};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder, Wry};

const TRAY_ID: &str = "main";
static LAST_SHOWN: Mutex<Option<Shown>> = Mutex::new(None);

#[derive(Clone)]
struct Shown {
    label: String,
    tooltip: String,
    lines: Vec<String>,
}

fn tooltip(shared: &Shared) -> String {
    if !cfg!(windows) {
        return "LimitFuel".into();
    }
    let mode = lock(&shared.settings).mode();
    let claude = lock(&shared.claude).windows.clone();
    let codex = lock(&shared.codex).windows.clone();
    display::tray_tooltip(&claude, &codex, mode, now())
}

fn menu_lines(shared: &Shared) -> Vec<String> {
    let mode = lock(&shared.settings).mode();
    let suffix = match mode {
        display::PercentageMode::Used => "used",
        display::PercentageMode::Remaining => "left",
    };
    let now = now();
    let mut lines = Vec::new();
    for (name, state) in [("Claude", lock(&shared.claude).clone()), ("Codex", lock(&shared.codex).clone())] {
        let ProviderState { windows, stale, error, .. } = state;
        if windows.is_empty() {
            if let Some(error) = error {
                lines.push(format!("{name}: {}", short(&error)));
            }
            continue;
        }
        for window in windows {
            let mut line =
                format!("{name} · {}: {}% {suffix}", window.label, mode.displayed_percent(window.percent));
            if let Some(reset) = display::reset_label(window.resets_at, now) {
                line.push_str(&format!(", resets in {reset}"));
            }
            if stale {
                line.push_str(" (last known)");
            }
            lines.push(line);
        }
    }
    if lines.is_empty() {
        lines.push("Open Settings to connect Claude or Codex".into());
    }
    lines
}

/// First sentence only; the full message is in Settings.
fn short(message: &str) -> String {
    message.split(". ").next().unwrap_or(message).trim_end_matches('.').to_string()
}

fn build_menu(app: &AppHandle, lines: &[String]) -> tauri::Result<Menu<Wry>> {
    let mut builder = MenuBuilder::new(app);
    for (index, line) in lines.iter().enumerate() {
        builder = builder.item(&MenuItemBuilder::with_id(format!("line-{index}"), line).enabled(false).build(app)?);
    }
    builder
        .separator()
        .text("refresh", "Refresh Now")
        .text("settings", "Settings…")
        .separator()
        .text("quit", "Quit LimitFuel")
        .build()
}

pub fn create(app: &AppHandle, shared: &Shared) -> tauri::Result<()> {
    let lines = menu_lines(shared);
    let label = shared.tray_label();
    let tooltip = tooltip(shared);
    TrayIconBuilder::with_id(TRAY_ID)
        .icon(Image::from_bytes(include_bytes!("../icons/tray.png"))?)
        .title(&label)
        .tooltip(&tooltip)
        .menu(&build_menu(app, &lines)?)
        .show_menu_on_left_click(true)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "refresh" => {
                let shared = app.state::<Arc<Shared>>();
                shared.wake_cookie.notify();
                shared.wake_claude.notify();
                shared.wake_codex.notify();
            }
            "settings" => show_settings(app),
            "quit" => app.exit(0),
            _ => {}
        })
        .build(app)?;
    *lock(&LAST_SHOWN) = Some(Shown { label, tooltip, lines });
    Ok(())
}

/// Updates the label, tooltip and menu only when their text changed: replacing a
/// menu closes it on some desktops, and this runs every 30 seconds.
pub fn refresh(app: &AppHandle, shared: &Shared) {
    let next = Shown { label: shared.tray_label(), tooltip: tooltip(shared), lines: menu_lines(shared) };
    let _ = app.emit("state-changed", ());
    let mut shown = lock(&LAST_SHOWN);
    let old = shown.replace(next.clone());
    drop(shown);
    let (label_changed, tooltip_changed, lines_changed) = match &old {
        Some(old) => (old.label != next.label, old.tooltip != next.tooltip, old.lines != next.lines),
        None => (true, true, true),
    };
    if !label_changed && !tooltip_changed && !lines_changed {
        return;
    }
    let handle = app.clone();
    let _ = app.run_on_main_thread(move || {
        let Some(tray) = handle.tray_by_id(TRAY_ID) else { return };
        if label_changed {
            let _ = tray.set_title(Some(&next.label));
        }
        if tooltip_changed {
            let _ = tray.set_tooltip(Some(&next.tooltip));
        }
        if lines_changed
            && let Ok(menu) = build_menu(&handle, &next.lines)
        {
            let _ = tray.set_menu(Some(menu));
        }
    });
}

pub fn show_settings(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("settings") {
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
        return;
    }
    let _ = WebviewWindowBuilder::new(app, "settings", WebviewUrl::App("index.html".into()))
        .title("LimitFuel")
        .inner_size(560.0, 760.0)
        .min_inner_size(440.0, 480.0)
        .build();
}

/// Whether a StatusNotifierItem host is running. Vanilla GNOME has none without
/// the AppIndicator extension, and the icon would silently never appear.
#[cfg(target_os = "linux")]
pub fn host_available() -> bool {
    let check = || -> zbus::Result<bool> {
        let connection = zbus::blocking::Connection::session()?;
        let proxy = zbus::blocking::fdo::DBusProxy::new(&connection)?;
        Ok(proxy.name_has_owner("org.kde.StatusNotifierWatcher".try_into()?)?)
    };
    check().unwrap_or(false)
}

#[cfg(not(target_os = "linux"))]
pub fn host_available() -> bool {
    true
}
