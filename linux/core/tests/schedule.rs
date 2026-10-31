//! Acceptance tests for `limitfuel_core::schedule`, written from SPEC.md only.

use limitfuel_core::display::{Provider, WindowOption};
use limitfuel_core::schedule::{
    next_poll_delay, polling_interval, COOKIE_INTERVAL, FAST_USAGE_INTERVAL, USAGE_INTERVAL,
};

const NOW: f64 = 1_000_000.0;

fn win(
    provider: Provider,
    percent: f64,
    duration: Option<i64>,
    resets_at: Option<f64>,
) -> WindowOption {
    WindowOption {
        id: "w".to_string(),
        provider,
        label: "w".to_string(),
        percent,
        duration_minutes: duration,
        is_preferred_bucket: true,
        resets_at,
    }
}

#[test]
fn interval_constants_match_spec() {
    assert_eq!(USAGE_INTERVAL, 60.0);
    assert_eq!(FAST_USAGE_INTERVAL, 12.0);
    assert_eq!(COOKIE_INTERVAL, 3600.0);
}

#[test]
fn polling_interval_speeds_up_only_for_a_hot_live_five_hour_window() {
    struct Case {
        name: &'static str,
        options: Vec<WindowOption>,
        fast: bool,
    }
    let cases = vec![
        Case { name: "no options", options: vec![], fast: false },
        Case {
            name: "91% five-hour window, no reset known",
            options: vec![win(Provider::Claude, 91.0, Some(300), None)],
            fast: true,
        },
        Case {
            name: "91% five-hour window, reset in the future",
            options: vec![win(Provider::Claude, 91.0, Some(300), Some(NOW + 1.0))],
            fast: true,
        },
        Case {
            name: "reset exactly now is not after now",
            options: vec![win(Provider::Claude, 91.0, Some(300), Some(NOW))],
            fast: false,
        },
        Case {
            name: "reset in the past",
            options: vec![win(Provider::Claude, 99.0, Some(300), Some(NOW - 5.0))],
            fast: false,
        },
        Case {
            name: "exactly 90% is not above 90",
            options: vec![win(Provider::Claude, 90.0, Some(300), None)],
            fast: false,
        },
        Case {
            name: "just above 90%",
            options: vec![win(Provider::Claude, 90.0001, Some(300), None)],
            fast: true,
        },
        Case {
            name: "100%",
            options: vec![win(Provider::Claude, 100.0, Some(300), None)],
            fast: true,
        },
        Case {
            name: "NaN percent",
            options: vec![win(Provider::Claude, f64::NAN, Some(300), None)],
            fast: false,
        },
        Case {
            name: "infinite percent is not finite",
            options: vec![win(Provider::Claude, f64::INFINITY, Some(300), None)],
            fast: false,
        },
        Case {
            name: "weekly window above 90%",
            options: vec![win(Provider::Claude, 95.0, Some(10080), None)],
            fast: false,
        },
        Case {
            name: "window without a duration",
            options: vec![win(Provider::Claude, 95.0, None, None)],
            fast: false,
        },
        Case {
            name: "299 and 301 minute windows are not five-hour windows",
            options: vec![
                win(Provider::Claude, 95.0, Some(299), None),
                win(Provider::Claude, 95.0, Some(301), None),
            ],
            fast: false,
        },
        Case {
            name: "a later option qualifies",
            options: vec![
                win(Provider::Claude, 10.0, Some(300), None),
                win(Provider::Claude, 95.0, Some(10080), None),
                win(Provider::Claude, 92.0, Some(300), Some(NOW + 100.0)),
            ],
            fast: true,
        },
        Case {
            name: "provider does not matter",
            options: vec![win(Provider::Codex, 92.0, Some(300), Some(NOW + 100.0))],
            fast: true,
        },
        Case {
            // spec: only "finite percent > 90" is required, so 150 qualifies.
            name: "finite percent above 100 still counts",
            options: vec![win(Provider::Claude, 150.0, Some(300), None)],
            fast: true,
        },
        Case {
            name: "low usage",
            options: vec![win(Provider::Claude, 5.0, Some(300), None)],
            fast: false,
        },
    ];
    for case in &cases {
        let want = if case.fast { FAST_USAGE_INTERVAL } else { USAGE_INTERVAL };
        assert_eq!(polling_interval(&case.options, NOW), want, "case: {}", case.name);
    }
}

#[test]
fn next_poll_delay_is_anchored_to_start_times_with_one_second_floor() {
    // failure list #16: retries only on the next scheduled poll, cadence anchored
    // to start times, never faster than once per second.
    // (interval, last_started_at, now, expected)
    let table: &[(f64, Option<f64>, f64, f64)] = &[
        (60.0, None, 100.0, 60.0),
        (12.0, None, 100.0, 12.0),
        (60.0, Some(100.0), 130.0, 30.0),
        (60.0, Some(100.0), 100.0, 60.0),
        (12.0, Some(0.0), 5.0, 7.0),
        (60.0, Some(100.5), 130.25, 30.25),
        (60.0, Some(100.0), 158.0, 2.0),
        (60.0, Some(100.0), 159.0, 1.0),
        (60.0, Some(100.0), 159.5, 1.0), // 0.5 s left -> floor of 1 s
        (60.0, Some(100.0), 160.0, 1.0), // due now -> 1 s, no tight loop
        (60.0, Some(100.0), 500.0, 1.0), // long overdue -> 1 s
        (12.0, Some(100.0), 1_000_000.0, 1.0),
        // spec: literal formula max(1, last + interval - now); a start time in the
        // future (clock went backwards) simply yields the larger delay.
        (60.0, Some(200.0), 100.0, 160.0),
    ];
    for &(interval, last, now, want) in table {
        let got = next_poll_delay(interval, last, now);
        assert!(
            (got - want).abs() < 1e-9,
            "next_poll_delay({interval}, {last:?}, {now}) = {got}, want {want}"
        );
    }
}
