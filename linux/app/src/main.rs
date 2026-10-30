//! LimitFuel for Linux: Claude and Codex usage in the tray. Logic lives in
//! `limitfuel-core`; this crate is the tray, the settings window and storage.

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
