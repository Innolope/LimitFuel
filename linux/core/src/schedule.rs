//! Poll cadence: once a minute, every 12 s while a five-hour window is nearly used up.

use crate::display::WindowOption;

pub const USAGE_INTERVAL: f64 = 60.0;
pub const FAST_USAGE_INTERVAL: f64 = 12.0;
pub const COOKIE_INTERVAL: f64 = 3600.0;

pub fn polling_interval(options: &[WindowOption], now: f64) -> f64 {
    let near_limit = options.iter().any(|o| {
        o.percent.is_finite()
            && o.percent > 90.0
            && o.duration_minutes == Some(300)
            && o.resets_at.is_none_or(|reset| reset > now)
    });
    if near_limit { FAST_USAGE_INTERVAL } else { USAGE_INTERVAL }
}

/// Anchored to request starts, so slow or overlapping requests never spin.
pub fn next_poll_delay(interval: f64, last_started_at: Option<f64>, now: f64) -> f64 {
    match last_started_at {
        None => interval,
        Some(started) => (started + interval - now).max(1.0),
    }
}
