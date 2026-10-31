//! LimitFuel for Linux and Windows: Claude and Codex usage in the tray. Logic lives
//! in `limitfuel-core`; this crate is the tray, the settings window and storage.

// No console window behind the tray app on Windows.
#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

mod autostart;
mod commands;
mod poller;
mod secrets;
mod settings;
mod state;
mod telemetry;
mod tray;

use std::sync::Arc;
use std::sync::atomic::Ordering;
use tauri::RunEvent;

fn main() {
    // Before any GUI or instance check: a version probe must never start a second app.
    if std::env::args().skip(1).any(|arg| arg == "--version") {
        #[cfg(windows)]
        attach_console();
        println!("LimitFuel {}", env!("CARGO_PKG_VERSION"));
        return;
    }
    let settings = settings::Settings::load();
    telemetry::set_enabled(settings.diagnostics);
    let shared = Arc::new(state::Shared::new(settings));
    let setup_shared = shared.clone();
    let app = tauri::Builder::default()
        // Must be registered first: a second launch focuses this one and exits.
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| tray::show_settings(app)))
        .plugin(tauri_plugin_notification::init())
        .manage(shared)
        .invoke_handler(tauri::generate_handler![
            commands::get_state,
            commands::refresh,
            commands::detect_browsers,
            commands::use_profile,
            commands::save_cookie,
            commands::disconnect_claude,
            commands::set_codex_path,
            commands::set_preference,
            commands::detected_codex,
        ])
        .setup(move |app| {
            let handle = app.handle().clone();
            let has_host = tray::host_available();
            setup_shared.tray_host.store(has_host, Ordering::SeqCst);
            tray::create(&handle, &setup_shared)?;
            poller::start(handle.clone(), setup_shared.clone());
            if !has_host {
                // Without a tray host the icon never appears; show the status window instead.
                tray::show_settings(&handle);
            }
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("LimitFuel could not start");
    app.run(|_app, event| {
        // Closing the settings window must not quit a tray app; only Quit does.
        if let RunEvent::ExitRequested { api, code, .. } = event
            && code.is_none()
        {
            api.prevent_exit();
        }
    });
}

/// A GUI-subsystem program has no stdout in a terminal. Output redirected to a pipe or
/// file is kept; otherwise print to the console that started it.
#[cfg(windows)]
fn attach_console() {
    use windows_sys::Win32::Foundation::{GENERIC_WRITE, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::Storage::FileSystem::{CreateFileW, FILE_SHARE_WRITE, OPEN_EXISTING};
    use windows_sys::Win32::System::Console::{
        ATTACH_PARENT_PROCESS, AttachConsole, GetStdHandle, STD_OUTPUT_HANDLE, SetStdHandle,
    };
    // SAFETY: plain console calls; the opened handle becomes this process's stdout.
    unsafe {
        let current = GetStdHandle(STD_OUTPUT_HANDLE);
        if !current.is_null() && current != INVALID_HANDLE_VALUE {
            return;
        }
        if AttachConsole(ATTACH_PARENT_PROCESS) == 0 {
            return;
        }
        let name: Vec<u16> = "CONOUT$".encode_utf16().chain(Some(0)).collect();
        let null = std::ptr::null_mut();
        let console =
            CreateFileW(name.as_ptr(), GENERIC_WRITE, FILE_SHARE_WRITE, std::ptr::null(), OPEN_EXISTING, 0, null);
        if console != INVALID_HANDLE_VALUE {
            SetStdHandle(STD_OUTPUT_HANDLE, console);
        }
    }
}
