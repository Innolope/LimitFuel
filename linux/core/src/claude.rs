//! claude.ai usage: organization lookup, the usage endpoint and its JSON.

use crate::display::{Provider, WindowOption};
use serde_json::Value;
use std::io::ErrorKind;
use std::time::Duration;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClaudeError {
    SignIn,
    /// No route, DNS failure, refused or reset connection. Never reported.
    Offline,
    Timeout,
    Protocol,
    InvalidData,
}

const MAX_BODY: u64 = 1_048_576;
const USER_AGENT: &str = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

fn is_uuid(text: &str) -> bool {
    let groups: Vec<&str> = text.split('-').collect();
    groups.len() == 5
        && groups.iter().zip([8, 4, 4, 4, 12]).all(|(g, len)| g.len() == len && g.bytes().all(|b| b.is_ascii_hexdigit()))
}

pub fn org_id_from_cookie(header: &str) -> Option<String> {
    header
        .split(';')
        .filter_map(|part| part.trim().strip_prefix("lastActiveOrg="))
        .find(|value| is_uuid(value))
        .map(str::to_ascii_lowercase)
}

pub fn parse_bootstrap(body: &[u8]) -> Result<String, ClaudeError> {
    let json: Value = serde_json::from_slice(body).map_err(|_| ClaudeError::Protocol)?;
    json.pointer("/account/lastActiveOrgId")
        .and_then(Value::as_str)
        .filter(|id| is_uuid(id))
        .map(str::to_ascii_lowercase)
        .ok_or(ClaudeError::Protocol)
}

fn percentage(value: Option<&Value>) -> Option<f64> {
    // Value::Bool is never a Number, so booleans are rejected here too.
    let number = value?.as_f64()?;
    (number.is_finite() && (0.0..=100.0).contains(&number)).then_some(number)
}

fn reset(value: Option<&Value>) -> Option<f64> {
    value.and_then(Value::as_str).and_then(parse_iso8601)
}

fn window(id: &str, label: &str, minutes: i64, preferred: bool, percent: f64, resets_at: Option<f64>) -> WindowOption {
    WindowOption {
        id: id.into(),
        provider: Provider::Claude,
        label: label.into(),
        percent,
        duration_minutes: Some(minutes),
        is_preferred_bucket: preferred,
        resets_at,
    }
}

pub fn parse_usage(body: &[u8]) -> Result<Vec<WindowOption>, ClaudeError> {
    let json: Value = serde_json::from_slice(body).map_err(|_| ClaudeError::InvalidData)?;
    let json = json.as_object().ok_or(ClaudeError::InvalidData)?;
    let five_hour = json.get("five_hour").and_then(Value::as_object).ok_or(ClaudeError::InvalidData)?;
    let session = percentage(five_hour.get("utilization")).ok_or(ClaudeError::InvalidData)?;
    let mut windows =
        vec![window("claude:five_hour", "Session · 5h", 300, true, session, reset(five_hour.get("resets_at")))];
    for (key, id, label, preferred) in [
        ("seven_day", "claude:seven_day", "Weekly · 7d", true),
        ("seven_day_sonnet", "claude:seven_day_sonnet", "Sonnet · 7d", false),
    ] {
        let entry = json.get(key);
        if let Some(percent) = percentage(entry.and_then(|e| e.get("utilization"))) {
            windows.push(window(id, label, 10080, preferred, percent, reset(entry.and_then(|e| e.get("resets_at")))));
        }
    }
    // Fable is a model-scoped weekly limit in the `limits` array, not a top-level key.
    let fable = json.get("limits").and_then(Value::as_array).and_then(|limits| {
        limits.iter().find(|entry| entry.pointer("/scope/model/display_name").and_then(Value::as_str) == Some("Fable"))
    });
    if let Some(fable) = fable
        && let Some(percent) = percentage(fable.get("percent"))
    {
        windows.push(window("claude:seven_day_fable", "Fable · 7d", 10080, false, percent, reset(fable.get("resets_at"))));
    }
    Ok(windows)
}

fn digits(text: &str) -> Option<i64> {
    (!text.is_empty() && text.bytes().all(|b| b.is_ascii_digit())).then(|| text.parse().ok()).flatten()
}

/// Days from 1970-01-01 to a proleptic Gregorian date (Howard Hinnant's algorithm).
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let yoe = year - era * 400;
    let doy = (153 * (month + if month > 2 { -3 } else { 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM)`, the forms claude.ai sends.
pub fn parse_iso8601(text: &str) -> Option<f64> {
    let (date, rest) = text.split_once('T')?;
    let mut date_parts = date.split('-');
    let (year, month, day) =
        (digits(date_parts.next()?)?, digits(date_parts.next()?)?, digits(date_parts.next()?)?);
    if date_parts.next().is_some() || date.len() != 10 {
        return None;
    }
    let (clock, offset) = if let Some(clock) = rest.strip_suffix('Z').or_else(|| rest.strip_suffix('z')) {
        (clock, 0)
    } else {
        let split = rest.rfind(['+', '-'])?;
        let (clock, zone) = rest.split_at(split);
        let sign = if zone.starts_with('-') { -1 } else { 1 };
        let (hours, minutes) = zone[1..].split_once(':')?;
        let (hours, minutes) = (digits(hours)?, digits(minutes)?);
        if hours.to_string().len() > 2 || hours > 23 || minutes > 59 {
            return None;
        }
        (clock, sign * (hours * 3600 + minutes * 60))
    };
    let (whole, fraction) = match clock.split_once('.') {
        Some((whole, fraction)) => (whole, Some(fraction)),
        None => (clock, None),
    };
    let mut clock_parts = whole.split(':');
    let (hour, minute, second) =
        (digits(clock_parts.next()?)?, digits(clock_parts.next()?)?, digits(clock_parts.next()?)?);
    if clock_parts.next().is_some() || whole.len() != 8 {
        return None;
    }
    let days_in_month = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 => 29,
        2 => 28,
        _ => return None,
    };
    if !(1..=days_in_month).contains(&day) || hour > 23 || minute > 59 || second > 60 {
        return None;
    }
    let fraction = match fraction {
        Some(f) if digits(f).is_some() => format!("0.{f}").parse::<f64>().ok()?,
        Some(_) => return None,
        None => 0.0,
    };
    let seconds = days_from_civil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second - offset;
    Some(seconds as f64 + fraction)
}

pub struct ClaudeClient {
    base_url: String,
    agent: ureq::Agent,
}

impl ClaudeClient {
    pub fn new(base_url: &str, timeout: Duration) -> Self {
        let agent = ureq::Agent::config_builder()
            .timeout_global(Some(timeout))
            .max_redirects(0)
            .max_redirects_will_error(false)
            .http_status_as_error(false)
            .user_agent(USER_AGENT)
            .build()
            .into();
        Self { base_url: base_url.trim_end_matches('/').to_string(), agent }
    }

    pub fn fetch(&self, cookie_header: &str) -> Result<Vec<WindowOption>, ClaudeError> {
        let org = match org_id_from_cookie(cookie_header) {
            Some(org) => org,
            None => parse_bootstrap(&self.get("/api/bootstrap", cookie_header)?)?,
        };
        parse_usage(&self.get(&format!("/api/organizations/{org}/usage"), cookie_header)?)
    }

    fn get(&self, path: &str, cookie_header: &str) -> Result<Vec<u8>, ClaudeError> {
        let mut response = self
            .agent
            .get(format!("{}{path}", self.base_url))
            .header("Cookie", cookie_header)
            .header("Accept", "*/*")
            .header("Origin", "https://claude.ai")
            .header("Referer", "https://claude.ai")
            .call()
            .map_err(classify)?;
        match response.status().as_u16() {
            200 => {
                // ureq's limit is exclusive; allow exactly MAX_BODY and reject anything longer.
                let body = response.body_mut().with_config().limit(MAX_BODY + 1).read_to_vec().map_err(classify)?;
                if body.len() as u64 > MAX_BODY { Err(ClaudeError::InvalidData) } else { Ok(body) }
            }
            401 | 403 => Err(ClaudeError::SignIn),
            _ => Err(ClaudeError::Protocol),
        }
    }
}

fn classify(error: ureq::Error) -> ClaudeError {
    match error {
        ureq::Error::Timeout(_) => ClaudeError::Timeout,
        ureq::Error::HostNotFound | ureq::Error::ConnectionFailed => ClaudeError::Offline,
        ureq::Error::BodyExceedsLimit(_) => ClaudeError::InvalidData,
        ureq::Error::Io(io) => match io.kind() {
            ErrorKind::TimedOut | ErrorKind::WouldBlock => ClaudeError::Timeout,
            ErrorKind::ConnectionRefused
            | ErrorKind::ConnectionReset
            | ErrorKind::ConnectionAborted
            | ErrorKind::NotConnected
            | ErrorKind::HostUnreachable
            | ErrorKind::NetworkUnreachable
            | ErrorKind::NetworkDown
            | ErrorKind::AddrNotAvailable => ClaudeError::Offline,
            _ => ClaudeError::Protocol,
        },
        _ => ClaudeError::Protocol,
    }
}
