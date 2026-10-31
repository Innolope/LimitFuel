//! Error reporting, same contract as macOS (`docs/diagnostics.md`): enum-only events,
//! an allowlisted payload, and an opt-out that stops sending at once.

use limitfuel_core::diagnostics::{DiagnosticCode, DiagnosticProvider};
use sentry::protocol::Event;
use std::borrow::Cow;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

static ENABLED: AtomicBool = AtomicBool::new(false);
static GUARD: Mutex<Option<sentry::ClientInitGuard>> = Mutex::new(None);

const DSN: &str = env!("LIMITFUEL_SENTRY_DSN");

pub fn is_configured() -> bool {
    !DSN.is_empty()
}

/// Keeps the event id, time, level, release, fixed tags and function names only.
fn scrub(mut event: Event<'static>) -> Option<Event<'static>> {
    if !ENABLED.load(Ordering::SeqCst) {
        return None;
    }
    event.user = None;
    event.request = None;
    event.server_name = None;
    event.breadcrumbs = Default::default();
    event.extra = Default::default();
    event.modules = Default::default();
    event.debug_meta = Default::default();
    event.contexts.retain(|key, _| key == "os");
    event.tags.retain(|key, _| key == "provider" || key == "code" || key == "platform");
    event.tags.insert("platform".into(), crate::state::PLATFORM.into());
    if event.message.as_deref().is_some_and(|message| message != "Connection error") {
        event.message = None;
    }
    for exception in event.exception.values.iter_mut() {
        // Panic messages can carry formatted values; keep the type only.
        exception.value = None;
        exception.module = None;
        if let Some(stacktrace) = exception.stacktrace.as_mut() {
            stacktrace.frames.truncate(256);
            for frame in stacktrace.frames.iter_mut() {
                frame.abs_path = None;
                frame.filename = None;
                frame.lineno = None;
                frame.colno = None;
                frame.pre_context.clear();
                frame.context_line = None;
                frame.post_context.clear();
                frame.vars.clear();
            }
        }
    }
    event.exception.values.truncate(8);
    event.threads.values.clear();
    Some(event)
}

pub fn set_enabled(enabled: bool) {
    ENABLED.store(enabled, Ordering::SeqCst);
    let mut guard = GUARD.lock().unwrap_or_else(|e| e.into_inner());
    if enabled && guard.is_none() && is_configured() {
        let mut options = sentry::ClientOptions::default();
        let release = format!("limitfuel-{}@{}", crate::state::PLATFORM, env!("CARGO_PKG_VERSION"));
        options.release = Some(Cow::Owned(release));
        options.environment = Some("production".into());
        options.server_name = None;
        options.send_default_pii = false;
        options.attach_stacktrace = false;
        options.max_breadcrumbs = 0;
        options.before_send = Some(Arc::new(scrub));
        *guard = Some(sentry::init((DSN, options)));
    }
}

pub fn report(provider: DiagnosticProvider, code: DiagnosticCode) {
    if !ENABLED.load(Ordering::SeqCst) {
        return;
    }
    let provider = match provider {
        DiagnosticProvider::Claude => "claude",
        DiagnosticProvider::Codex => "codex",
    };
    sentry::with_scope(
        |scope| {
            scope.set_tag("provider", provider);
            scope.set_tag("code", code.tag());
        },
        || sentry::capture_message("Connection error", sentry::Level::Error),
    );
}

/// Whether any network route exists. Failures without one say nothing about the providers.
#[cfg(not(windows))]
pub fn online() -> bool {
    let has_default = |path: &str, matches: &dyn Fn(&[&str]) -> bool| {
        std::fs::read_to_string(path)
            .map(|table| table.lines().skip(1).any(|line| matches(&line.split_whitespace().collect::<Vec<_>>())))
            .unwrap_or(false)
    };
    // IPv4: destination 00000000 on a non-loopback interface.
    let ipv4 = has_default("/proc/net/route", &|f| f.len() > 1 && f[1] == "00000000" && f[0] != "lo");
    // IPv6: ::/0 on a non-loopback interface (the table has no header line).
    let ipv6 = std::fs::read_to_string("/proc/net/ipv6_route")
        .map(|table| {
            table.lines().any(|line| {
                let f: Vec<&str> = line.split_whitespace().collect();
                f.len() > 9 && f[0] == "00000000000000000000000000000000" && f[1] == "00" && f[9] != "lo"
            })
        })
        .unwrap_or(false);
    ipv4 || ipv6
}

/// Whether a default route (IPv4 or IPv6) exists on an interface other than loopback.
#[cfg(windows)]
pub fn online() -> bool {
    use windows_sys::Win32::NetworkManagement::IpHelper::{
        FreeMibTable, GetIpForwardTable2, MIB_IPFORWARD_ROW2, MIB_IPFORWARD_TABLE2,
    };
    use windows_sys::Win32::Networking::WinSock::AF_UNSPEC;
    const IF_TYPE_SOFTWARE_LOOPBACK: u64 = 24;
    let mut table: *mut MIB_IPFORWARD_TABLE2 = std::ptr::null_mut();
    // SAFETY: on success Windows allocates the table, released with FreeMibTable.
    unsafe {
        if GetIpForwardTable2(AF_UNSPEC, &mut table) != 0 || table.is_null() {
            return false;
        }
        let first = (&raw const (*table).Table).cast::<MIB_IPFORWARD_ROW2>();
        let rows = std::slice::from_raw_parts(first, (*table).NumEntries as usize);
        // The interface type is the top 16 bits of its LUID.
        let found = rows.iter().any(|row| {
            row.DestinationPrefix.PrefixLength == 0 && (row.InterfaceLuid.Value >> 48) != IF_TYPE_SOFTWARE_LOOPBACK
        });
        FreeMibTable(table.cast());
        found
    }
}
