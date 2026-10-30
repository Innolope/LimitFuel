//! Acceptance tests for `limitfuel_core::diagnostics`, written from SPEC.md only.
//!
//! The spec lists no derives for `DiagnosticProvider` / `DiagnosticCode`, so these
//! tests rebuild values from local enums and compare through `matches!`/names.

use limitfuel_core::claude::ClaudeError;
use limitfuel_core::codex::CodexError;
use limitfuel_core::cookies::CookieError;
use limitfuel_core::diagnostics::{DiagnosticCode, DiagnosticProvider, ReportPolicy};

#[derive(Clone, Copy, Debug)]
enum P {
    Claude,
    Codex,
}

#[derive(Clone, Copy, Debug)]
enum C {
    Unavailable,
    SignIn,
    Protocol,
    Timeout,
    InvalidData,
}

fn prov(p: P) -> DiagnosticProvider {
    match p {
        P::Claude => DiagnosticProvider::Claude,
        P::Codex => DiagnosticProvider::Codex,
    }
}

fn code(c: C) -> DiagnosticCode {
    match c {
        C::Unavailable => DiagnosticCode::Unavailable,
        C::SignIn => DiagnosticCode::SignIn,
        C::Protocol => DiagnosticCode::ProtocolFailure,
        C::Timeout => DiagnosticCode::Timeout,
        C::InvalidData => DiagnosticCode::InvalidData,
    }
}

fn fail(policy: &mut ReportPolicy, p: P, c: C, now: f64, online: bool) -> bool {
    policy.record_failure(prov(p), code(c), now, online)
}

fn recover(policy: &mut ReportPolicy, p: P) {
    policy.record_recovery(prov(p));
}

fn name(c: Option<DiagnosticCode>) -> &'static str {
    match c {
        None => "none",
        Some(DiagnosticCode::Unavailable) => "Unavailable",
        Some(DiagnosticCode::SignIn) => "SignIn",
        Some(DiagnosticCode::ProtocolFailure) => "ProtocolFailure",
        Some(DiagnosticCode::Timeout) => "Timeout",
        Some(DiagnosticCode::InvalidData) => "InvalidData",
    }
}

#[test]
fn policy_constants_match_spec() {
    assert_eq!(ReportPolicy::PERSISTENT_COUNT, 10u32);
    assert_eq!(ReportPolicy::PERSISTENT_SECONDS, 3600.0);
    assert_eq!(ReportPolicy::HOURLY_CAP, 20usize);
}

#[test]
fn sign_in_and_unavailable_never_send() {
    // failure list #20 (401/403 never reported) and #21 (keyring never reported)
    for p in [P::Claude, P::Codex] {
        for c in [C::SignIn, C::Unavailable] {
            let mut policy = ReportPolicy::new();
            for i in 0..200 {
                let online = i % 2 == 0;
                let now = f64::from(i) * 7200.0; // far apart, so no cap or span effect
                assert!(
                    !fail(&mut policy, p, c, now, online),
                    "{p:?}/{c:?} must never send (i={i}, online={online})"
                );
            }
        }
    }

    // End to end through the error mappings.
    let mut policy = ReportPolicy::new();
    let claude_sign_in: Option<DiagnosticCode> = ClaudeError::SignIn.into();
    let keyring: Option<DiagnosticCode> = CookieError::Keyring.into();
    for (i, mapped) in [claude_sign_in, keyring].into_iter().enumerate() {
        let mapped = mapped.expect("sign-in style errors map to a code");
        for k in 0..30 {
            assert!(!policy.record_failure(
                DiagnosticProvider::Claude,
                mapped_clone(&mapped),
                f64::from(k) * 100.0,
                true
            ), "mapped error #{i} must not send");
        }
    }
}

/// `DiagnosticCode` has no documented `Clone`/`Copy`; rebuild it by variant.
fn mapped_clone(c: &DiagnosticCode) -> DiagnosticCode {
    match c {
        DiagnosticCode::Unavailable => DiagnosticCode::Unavailable,
        DiagnosticCode::SignIn => DiagnosticCode::SignIn,
        DiagnosticCode::ProtocolFailure => DiagnosticCode::ProtocolFailure,
        DiagnosticCode::Timeout => DiagnosticCode::Timeout,
        DiagnosticCode::InvalidData => DiagnosticCode::InvalidData,
    }
}

#[test]
fn invalid_data_sends_on_first_occurrence_once_until_recovery() {
    // failure list #12: one outage -> at most one event per provider/code until recovery
    let mut policy = ReportPolicy::new();
    assert!(fail(&mut policy, P::Claude, C::InvalidData, 0.0, true), "first occurrence sends");
    for i in 1..50 {
        assert!(
            !fail(&mut policy, P::Claude, C::InvalidData, f64::from(i) * 5.0, true),
            "repeat #{i} of the same pair must not send"
        );
    }
    // The other provider has its own pair.
    assert!(fail(&mut policy, P::Codex, C::InvalidData, 300.0, true));
    assert!(!fail(&mut policy, P::Codex, C::InvalidData, 301.0, true));

    // Recovery of one provider does not clear the other's pair.
    recover(&mut policy, P::Codex);
    assert!(!fail(&mut policy, P::Claude, C::InvalidData, 400.0, true));
    assert!(fail(&mut policy, P::Codex, C::InvalidData, 401.0, true));

    // Recovery makes the pair eligible again.
    recover(&mut policy, P::Claude);
    assert!(fail(&mut policy, P::Claude, C::InvalidData, 500.0, true));
    assert!(!fail(&mut policy, P::Claude, C::InvalidData, 501.0, true));
}

#[test]
fn timeout_and_protocol_need_ten_online_failures_spanning_an_hour() {
    for c in [C::Timeout, C::Protocol] {
        let ctx = format!("{c:?}");

        // Count boundary: nine failures spanning exactly an hour are not enough.
        let mut policy = ReportPolicy::new();
        for i in 0..9 {
            let t = f64::from(i) * 450.0; // 0, 450, ..., 3600
            assert!(!fail(&mut policy, P::Claude, c, t, true), "{ctx}: failure #{} at {t}", i + 1);
        }
        assert!(fail(&mut policy, P::Claude, c, 3650.0, true), "{ctx}: tenth failure sends");
        assert!(!fail(&mut policy, P::Claude, c, 3700.0, true), "{ctx}: sent once per pair");
        assert!(!fail(&mut policy, P::Claude, c, 99_999.0, true), "{ctx}: still once per pair");

        // Span boundary: ten failures in ten seconds, then the run reaches an hour.
        let mut policy = ReportPolicy::new();
        for i in 0..10 {
            assert!(
                !fail(&mut policy, P::Claude, c, f64::from(i), true),
                "{ctx}: burst failure #{}",
                i + 1
            );
        }
        assert!(!fail(&mut policy, P::Claude, c, 3599.0, true), "{ctx}: span 3599 s is too short");
        assert!(fail(&mut policy, P::Claude, c, 3600.0, true), "{ctx}: span of exactly 3600 s sends");
        assert!(!fail(&mut policy, P::Claude, c, 3601.0, true), "{ctx}: no second send");

        // Offline failures neither count nor break the run.
        let mut policy = ReportPolicy::new();
        for i in 0..8 {
            let t = f64::from(i) * 500.0; // 0 ..= 3500
            assert!(!fail(&mut policy, P::Claude, c, t, true), "{ctx}: online #{}", i + 1);
        }
        assert!(!fail(&mut policy, P::Claude, c, 3600.0, false), "{ctx}: offline never sends");
        assert!(!fail(&mut policy, P::Claude, c, 3700.0, false), "{ctx}: offline never sends");
        assert!(
            !fail(&mut policy, P::Claude, c, 4000.0, true),
            "{ctx}: ninth online failure (offline ones must not count)"
        );
        assert!(
            fail(&mut policy, P::Claude, c, 4500.0, true),
            "{ctx}: tenth online failure sends (offline ones must not break the run)"
        );

        // Offline-only outage never sends, however long.
        let mut policy = ReportPolicy::new();
        for i in 0..100 {
            assert!(!fail(&mut policy, P::Claude, c, f64::from(i) * 3600.0, false));
        }
        assert!(!fail(&mut policy, P::Claude, c, 400_000.0, true), "{ctx}: first online failure");

        // Recovery clears the run.
        let mut policy = ReportPolicy::new();
        for i in 0..9 {
            assert!(!fail(&mut policy, P::Claude, c, f64::from(i) * 500.0, true));
        }
        recover(&mut policy, P::Claude);
        assert!(
            !fail(&mut policy, P::Claude, c, 4500.0, true),
            "{ctx}: first failure after recovery starts a new run"
        );
        for i in 1..9 {
            let t = 4500.0 + f64::from(i) * 500.0; // 5000 ..= 8500
            assert!(!fail(&mut policy, P::Claude, c, t, true), "{ctx}: new run failure #{}", i + 1);
        }
        assert!(
            fail(&mut policy, P::Claude, c, 9000.0, true),
            "{ctx}: tenth failure of the new run sends"
        );

        // Providers keep separate runs.
        let mut policy = ReportPolicy::new();
        for i in 0..10 {
            let t = f64::from(i) * 500.0;
            let claude_sent = fail(&mut policy, P::Claude, c, t, true);
            let codex_sent = fail(&mut policy, P::Codex, c, t, true);
            assert_eq!(claude_sent, i == 9, "{ctx}: claude at step {i}");
            assert_eq!(codex_sent, i == 9, "{ctx}: codex at step {i}");
        }

        // After recovery the same pair can send again once a new persistent run exists.
        let mut policy = ReportPolicy::new();
        for i in 0..10 {
            fail(&mut policy, P::Claude, c, f64::from(i) * 500.0, true);
        }
        recover(&mut policy, P::Claude);
        let base = 10_000.0;
        let mut sent = false;
        for i in 0..10 {
            sent = fail(&mut policy, P::Claude, c, base + f64::from(i) * 500.0, true);
            assert_eq!(sent, i == 9, "{ctx}: second outage step {i}");
        }
        assert!(sent);
    }
}

#[test]
fn hourly_cap_is_global_rolling_and_survives_recovery() {
    let mut policy = ReportPolicy::new();
    // Twenty sends at t = 0..=19, alternating providers, each followed by recovery
    // (recovery must not reset the cap).
    for i in 0..20 {
        let p = if i % 2 == 0 { P::Claude } else { P::Codex };
        assert!(fail(&mut policy, p, C::InvalidData, f64::from(i), true), "send #{i}");
        recover(&mut policy, p);
    }
    // The 21st attempt inside the hour is dropped, for either provider.
    assert!(!fail(&mut policy, P::Claude, C::InvalidData, 20.0, true), "cap reached (claude)");
    recover(&mut policy, P::Claude);
    assert!(!fail(&mut policy, P::Codex, C::InvalidData, 21.0, true), "cap reached (codex)");
    recover(&mut policy, P::Codex);
    assert!(!fail(&mut policy, P::Claude, C::InvalidData, 3599.0, true), "send@0 is still within the hour");
    recover(&mut policy, P::Claude);

    // At exactly 3600 s the send made at t=0 no longer counts.
    assert!(fail(&mut policy, P::Claude, C::InvalidData, 3600.0, true), "window slid past t=0");
    recover(&mut policy, P::Claude);
    // Now sends at t=1..=19 plus t=3600 fill the cap again.
    assert!(!fail(&mut policy, P::Codex, C::InvalidData, 3600.0, true), "cap full again");
    recover(&mut policy, P::Codex);
    // One second later the send at t=1 ages out.
    assert!(fail(&mut policy, P::Codex, C::InvalidData, 3601.0, true), "window slid past t=1");
}

#[test]
fn reset_forgets_sent_pairs_and_runs() {
    let mut policy = ReportPolicy::new();
    assert!(fail(&mut policy, P::Claude, C::InvalidData, 0.0, true));
    assert!(!fail(&mut policy, P::Claude, C::InvalidData, 1.0, true));
    policy.reset();
    assert!(
        fail(&mut policy, P::Claude, C::InvalidData, 2.0, true),
        "after reset the same pair may send again"
    );

    // Persistent runs are forgotten too.
    let mut policy = ReportPolicy::new();
    for i in 0..9 {
        assert!(!fail(&mut policy, P::Codex, C::Timeout, f64::from(i) * 500.0, true));
    }
    policy.reset();
    assert!(
        !fail(&mut policy, P::Codex, C::Timeout, 4500.0, true),
        "run restarted by reset: this would be the tenth failure otherwise"
    );
}

#[test]
fn claude_errors_map_to_diagnostic_codes() {
    let table: Vec<(ClaudeError, &str)> = vec![
        (ClaudeError::Offline, "none"),
        (ClaudeError::Timeout, "Timeout"),
        (ClaudeError::Protocol, "ProtocolFailure"),
        (ClaudeError::InvalidData, "InvalidData"),
        (ClaudeError::SignIn, "SignIn"),
    ];
    for (error, want) in table {
        let label = format!("{error:?}");
        let mapped: Option<DiagnosticCode> = error.into();
        assert_eq!(name(mapped), want, "ClaudeError::{label}");
    }
}

#[test]
fn codex_errors_map_name_for_name() {
    let table: Vec<(CodexError, &str)> = vec![
        (CodexError::Unavailable, "Unavailable"),
        (CodexError::SignIn, "SignIn"),
        (CodexError::Protocol, "ProtocolFailure"),
        (CodexError::Timeout, "Timeout"),
        (CodexError::InvalidData, "InvalidData"),
    ];
    for (error, want) in table {
        let label = format!("{error:?}");
        let mapped: Option<DiagnosticCode> = error.into();
        assert_eq!(name(mapped), want, "CodexError::{label}");
    }
}

#[test]
fn cookie_errors_map_to_diagnostic_codes() {
    // failure list #21: a locked/denied keyring is a sign-in problem, never reported.
    let table: Vec<(CookieError, &str)> = vec![
        (CookieError::Keyring, "SignIn"),
        (CookieError::Encryption, "InvalidData"),
        (CookieError::InvalidCookie, "InvalidData"),
        (CookieError::Unavailable, "Unavailable"),
        (CookieError::Profile, "Unavailable"),
        (CookieError::Database, "ProtocolFailure"),
    ];
    for (error, want) in table {
        let label = format!("{error:?}");
        let mapped: Option<DiagnosticCode> = error.into();
        assert_eq!(name(mapped), want, "CookieError::{label}");
    }
}

#[test]
fn events_carry_only_provider_and_code() {
    // failure list #26: the reporting surface is (provider, code) and nothing else;
    // every mapped value is one of the five documented codes.
    for mapped in [
        Option::<DiagnosticCode>::from(ClaudeError::Protocol),
        Option::<DiagnosticCode>::from(CodexError::Timeout),
        Option::<DiagnosticCode>::from(CookieError::Database),
    ] {
        let n = name(mapped);
        assert!(
            ["Unavailable", "SignIn", "ProtocolFailure", "Timeout", "InvalidData"].contains(&n),
            "unexpected code {n}"
        );
    }
}
