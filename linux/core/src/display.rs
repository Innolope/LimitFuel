//! What the tray shows: window selection, percentages and reset countdowns.

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Provider {
    Claude,
    Codex,
}

impl Provider {
    pub fn name(self) -> &'static str {
        match self {
            Provider::Claude => "Claude",
            Provider::Codex => "Codex",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum PercentageMode {
    Used,
    #[default]
    Remaining,
}

impl PercentageMode {
    /// The tray and the menu share this, so both show one number.
    pub fn displayed_percent(self, used: f64) -> i64 {
        let clamped = if used.is_finite() { used.clamp(0.0, 100.0) } else { 0.0 };
        let value = match self {
            PercentageMode::Used => clamped,
            PercentageMode::Remaining => 100.0 - clamped,
        };
        // f64::round rounds half away from zero, like Swift's toNearestOrAwayFromZero.
        value.round() as i64
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct WindowOption {
    pub id: String,
    pub provider: Provider,
    pub label: String,
    pub percent: f64,
    pub duration_minutes: Option<i64>,
    pub is_preferred_bucket: bool,
    pub resets_at: Option<f64>,
}

impl WindowOption {
    fn is_valid(&self) -> bool {
        self.percent.is_finite() && (0.0..=100.0).contains(&self.percent)
    }
}

pub const AUTOMATIC: &str = "automatic";

/// A saved choice wins while that window exists; otherwise the shortest
/// (session-length) window of the preferred bucket.
pub fn select_option<'a>(
    provider: Provider,
    options: &'a [WindowOption],
    selection_id: Option<&str>,
) -> Option<&'a WindowOption> {
    let valid: Vec<&WindowOption> =
        options.iter().filter(|o| o.provider == provider && o.is_valid()).collect();
    if let Some(id) = selection_id.filter(|id| *id != AUTOMATIC)
        && let Some(selected) = valid.iter().find(|o| o.id == id)
    {
        return Some(selected);
    }
    let sessions: Vec<&WindowOption> = valid
        .iter()
        .copied()
        .filter(|o| matches!(o.duration_minutes, Some(m) if m > 0 && m < 1440))
        .collect();
    let candidates = if sessions.is_empty() { valid } else { sessions };
    candidates.iter().find(|o| o.is_preferred_bucket).or(candidates.first()).copied()
}

const MIN_TIMESTAMP: f64 = -62_135_596_800.0;
const MAX_TIMESTAMP: f64 = 253_402_300_799.0;

pub fn reset_label(resets_at: Option<f64>, now: f64) -> Option<String> {
    let resets_at = resets_at?;
    let in_range = |t: f64| t.is_finite() && (MIN_TIMESTAMP..=MAX_TIMESTAMP).contains(&t);
    if !in_range(resets_at) || !in_range(now) {
        return None;
    }
    let remaining = resets_at - now;
    if remaining <= 0.0 {
        return Some("0m".into());
    }
    // Choose the unit before rounding: 23h50m stays 24h, not 1d.
    if remaining >= 86_400.0 {
        return Some(format!("{}d", ((remaining + 43_200.0) / 86_400.0).floor() as i64));
    }
    // The displayed hour advances at minute 45, inclusive.
    if remaining >= 3_600.0 {
        return Some(format!("{}h", ((remaining + 900.0) / 3_600.0).floor() as i64));
    }
    Some(format!("{}m", (remaining / 60.0).ceil() as i64))
}

pub fn tray_label(
    claude: Option<&WindowOption>,
    codex: Option<&WindowOption>,
    mode: PercentageMode,
    now: f64,
) -> String {
    let entries: Vec<String> = [(Provider::Claude, claude), (Provider::Codex, codex)]
        .into_iter()
        .filter_map(|(provider, option)| {
            let option = option?;
            let mut text = format!("{} {}%", provider.name(), mode.displayed_percent(option.percent));
            if let Some(reset) = reset_label(option.resets_at, now) {
                text.push_str(" · ");
                text.push_str(&reset);
            }
            Some(text)
        })
        .collect();
    if entries.is_empty() { "LimitFuel".into() } else { entries.join("  ") }
}

pub fn duration_label(minutes: i64) -> String {
    if minutes % 1440 == 0 {
        format!("{}d", minutes / 1440)
    } else if minutes % 60 == 0 {
        format!("{}h", minutes / 60)
    } else {
        format!("{minutes}m")
    }
}

/// Windows keeps 128 UTF-16 units of tooltip, including the terminator.
pub const TOOLTIP_LIMIT: usize = 127;

pub fn short_label(label: &str) -> String {
    let _ = label;
    unimplemented!()
}

pub fn tray_tooltip(claude: &[WindowOption], codex: &[WindowOption], mode: PercentageMode, now: f64) -> String {
    let _ = (claude, codex, mode, now);
    unimplemented!()
}
