//! Which failures reach Sentry. Same policy as macOS (`docs/diagnostics.md`):
//! only possible defects are sent, never account states or brief outages.

use crate::claude::ClaudeError;
use crate::codex::CodexError;
use crate::cookies::CookieError;
use std::collections::{HashMap, HashSet, VecDeque};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DiagnosticProvider {
    Claude,
    Codex,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DiagnosticCode {
    Unavailable,
    SignIn,
    ProtocolFailure,
    Timeout,
    InvalidData,
}

impl DiagnosticCode {
    pub fn tag(self) -> &'static str {
        match self {
            DiagnosticCode::Unavailable => "unavailable",
            DiagnosticCode::SignIn => "signIn",
            DiagnosticCode::ProtocolFailure => "protocolFailure",
            DiagnosticCode::Timeout => "timeout",
            DiagnosticCode::InvalidData => "invalidData",
        }
    }

    /// Account and setup states are shown in the app and fixed by the user.
    fn is_reportable(self) -> bool {
        !matches!(self, DiagnosticCode::Unavailable | DiagnosticCode::SignIn)
    }

    /// Sleep, resume and bad Wi-Fi cause these routinely; only a lasting outage is a signal.
    fn needs_persistence(self) -> bool {
        matches!(self, DiagnosticCode::Timeout | DiagnosticCode::ProtocolFailure)
    }
}

#[derive(Debug, Default)]
pub struct ReportPolicy {
    sent: HashMap<DiagnosticProvider, HashSet<DiagnosticCode>>,
    streaks: HashMap<DiagnosticProvider, (f64, u32)>,
    attempts: VecDeque<f64>,
}

impl ReportPolicy {
    pub const PERSISTENT_COUNT: u32 = 10;
    pub const PERSISTENT_SECONDS: f64 = 3600.0;
    pub const HOURLY_CAP: usize = 20;

    pub fn new() -> Self {
        Self::default()
    }

    /// Returns true when exactly one event should be sent for this failure.
    pub fn record_failure(
        &mut self,
        provider: DiagnosticProvider,
        code: DiagnosticCode,
        now: f64,
        online: bool,
    ) -> bool {
        if !code.is_reportable() {
            return false;
        }
        // Offline failures neither count toward a run nor break it.
        if code.needs_persistence() && !online {
            return false;
        }
        if self.sent.get(&provider).is_some_and(|codes| codes.contains(&code)) {
            return false;
        }
        if code.needs_persistence() {
            let streak = self.streaks.entry(provider).or_insert((now, 0));
            streak.1 += 1;
            if streak.1 < Self::PERSISTENT_COUNT || now - streak.0 < Self::PERSISTENT_SECONDS {
                return false;
            }
        }
        while self.attempts.front().is_some_and(|t| now - t >= 3600.0) {
            self.attempts.pop_front();
        }
        if self.attempts.len() >= Self::HOURLY_CAP {
            return false;
        }
        self.attempts.push_back(now);
        self.sent.entry(provider).or_default().insert(code);
        true
    }

    pub fn record_recovery(&mut self, provider: DiagnosticProvider) {
        self.sent.remove(&provider);
        self.streaks.remove(&provider);
    }

    /// Turning reporting off and on forgets failures but keeps the hourly cap.
    pub fn reset(&mut self) {
        self.sent.clear();
        self.streaks.clear();
    }
}

impl From<ClaudeError> for Option<DiagnosticCode> {
    fn from(error: ClaudeError) -> Self {
        match error {
            ClaudeError::SignIn => Some(DiagnosticCode::SignIn),
            ClaudeError::Offline => None,
            ClaudeError::Timeout => Some(DiagnosticCode::Timeout),
            ClaudeError::Protocol => Some(DiagnosticCode::ProtocolFailure),
            ClaudeError::InvalidData => Some(DiagnosticCode::InvalidData),
        }
    }
}

impl From<CodexError> for Option<DiagnosticCode> {
    fn from(error: CodexError) -> Self {
        Some(match error {
            CodexError::Unavailable => DiagnosticCode::Unavailable,
            CodexError::SignIn => DiagnosticCode::SignIn,
            CodexError::Protocol => DiagnosticCode::ProtocolFailure,
            CodexError::Timeout => DiagnosticCode::Timeout,
            CodexError::InvalidData => DiagnosticCode::InvalidData,
        })
    }
}

impl From<CookieError> for Option<DiagnosticCode> {
    fn from(error: CookieError) -> Self {
        Some(match error {
            CookieError::Keyring => DiagnosticCode::SignIn,
            CookieError::Encryption | CookieError::InvalidCookie => DiagnosticCode::InvalidData,
            CookieError::Unavailable | CookieError::Profile | CookieError::AppBound => DiagnosticCode::Unavailable,
            CookieError::Database => DiagnosticCode::ProtocolFailure,
        })
    }
}
