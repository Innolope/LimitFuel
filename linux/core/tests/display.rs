//! Acceptance tests for `limitfuel_core::display`, written from SPEC.md only.

use limitfuel_core::display::{
    duration_label, reset_label, select_option, tray_label, PercentageMode, Provider, WindowOption,
    AUTOMATIC,
};

const NOW: f64 = 1_000_000.0;

fn opt(
    id: &str,
    provider: Provider,
    percent: f64,
    duration: Option<i64>,
    preferred: bool,
) -> WindowOption {
    WindowOption {
        id: id.to_string(),
        provider,
        label: format!("label {id}"),
        percent,
        duration_minutes: duration,
        is_preferred_bucket: preferred,
        resets_at: None,
    }
}

fn claude(id: &str, percent: f64, duration: Option<i64>, preferred: bool) -> WindowOption {
    opt(id, Provider::Claude, percent, duration, preferred)
}

fn codex(id: &str, percent: f64, duration: Option<i64>, preferred: bool) -> WindowOption {
    opt(id, Provider::Codex, percent, duration, preferred)
}

#[test]
fn percentage_mode_defaults_to_remaining() {
    // spec: "default Remaining" is read as `impl Default for PercentageMode`.
    assert_eq!(PercentageMode::default(), PercentageMode::Remaining);
}

#[test]
fn displayed_percent_rounds_clamps_and_inverts() {
    // (used, expected in Used mode, expected in Remaining mode)
    let table: &[(f64, i64, i64)] = &[
        (0.0, 0, 100),
        (100.0, 100, 0),
        (50.0, 50, 50),
        (5.0, 5, 95),
        (15.0, 15, 85),
        // round half away from zero, on both sides of the inversion
        (0.5, 1, 100),   // 100 - 0.5 = 99.5 -> 100
        (49.5, 50, 51),  // 100 - 49.5 = 50.5 -> 51
        (50.5, 51, 50),  // 100 - 50.5 = 49.5 -> 50
        (99.5, 100, 1),  // 100 - 99.5 = 0.5 -> 1
        (12.5, 13, 88),  // 87.5 -> 88
        (87.5, 88, 13),  // 12.5 -> 13
        (0.4, 0, 100),
        (99.6, 100, 0),
        (0.49, 0, 100),
        (99.49, 99, 1),
        // clamping to 0..=100
        (-5.0, 0, 100),
        (-0.1, 0, 100),
        (150.0, 100, 0),
        (100.4, 100, 0),
        (1e12, 100, 0),
        (-1e12, 0, 100),
        // non-finite counts as 0 (not as 100), including +inf
        (f64::NAN, 0, 100),
        (f64::INFINITY, 0, 100),
        (f64::NEG_INFINITY, 0, 100),
    ];
    for &(used, want_used, want_remaining) in table {
        assert_eq!(
            PercentageMode::Used.displayed_percent(used),
            want_used,
            "Used mode, used={used}"
        );
        assert_eq!(
            PercentageMode::Remaining.displayed_percent(used),
            want_remaining,
            "Remaining mode, used={used}"
        );
    }
}

struct SelectCase {
    name: &'static str,
    provider: Provider,
    options: Vec<WindowOption>,
    selection: Option<&'static str>,
    expected: Option<&'static str>,
}

#[test]
fn select_option_chooses_selection_then_short_preferred_then_first() {
    let cases = vec![
        SelectCase {
            name: "no options",
            provider: Provider::Claude,
            options: vec![],
            selection: None,
            expected: None,
        },
        SelectCase {
            name: "only other provider's options",
            provider: Provider::Claude,
            options: vec![codex("x", 10.0, Some(300), true)],
            selection: None,
            expected: None,
        },
        SelectCase {
            name: "explicit id wins over automatic choice",
            provider: Provider::Claude,
            options: vec![claude("a", 10.0, Some(300), true), claude("b", 20.0, Some(10080), false)],
            selection: Some("b"),
            expected: Some("b"),
        },
        SelectCase {
            name: "unknown explicit id falls back to automatic",
            provider: Provider::Claude,
            options: vec![claude("a", 10.0, Some(300), true), claude("b", 20.0, Some(10080), false)],
            selection: Some("zzz"),
            expected: Some("a"),
        },
        SelectCase {
            name: "explicit id of the other provider is ignored",
            provider: Provider::Claude,
            options: vec![claude("a", 10.0, Some(300), false), codex("x", 10.0, Some(60), true)],
            selection: Some("x"),
            expected: Some("a"),
        },
        SelectCase {
            name: "explicit id of an option with NaN percent is ignored",
            provider: Provider::Claude,
            options: vec![claude("a", 10.0, Some(300), false), claude("b", f64::NAN, Some(60), true)],
            selection: Some("b"),
            expected: Some("a"),
        },
        SelectCase {
            name: "explicit id of an option with negative percent is ignored",
            provider: Provider::Claude,
            options: vec![claude("a", 10.0, Some(300), false), claude("b", -1.0, Some(60), true)],
            selection: Some("b"),
            expected: Some("a"),
        },
        SelectCase {
            name: "explicit id of an option above 100 percent is ignored",
            provider: Provider::Claude,
            options: vec![claude("a", 10.0, Some(300), false), claude("b", 100.5, Some(60), true)],
            selection: Some("b"),
            expected: Some("a"),
        },
        SelectCase {
            name: "explicit id of an option with infinite percent is ignored",
            provider: Provider::Claude,
            options: vec![claude("a", 10.0, Some(300), false), claude("b", f64::INFINITY, Some(60), true)],
            selection: Some("b"),
            expected: Some("a"),
        },
        SelectCase {
            // spec: the AUTOMATIC sentinel is never looked up as an option id.
            name: "AUTOMATIC is not an option id",
            provider: Provider::Claude,
            options: vec![
                claude(AUTOMATIC, 10.0, Some(10080), false),
                claude("b", 20.0, Some(300), false),
            ],
            selection: Some(AUTOMATIC),
            expected: Some("b"),
        },
        SelectCase {
            name: "None selection is automatic",
            provider: Provider::Claude,
            options: vec![claude("a", 10.0, Some(10080), true), claude("b", 20.0, Some(300), false)],
            selection: None,
            expected: Some("b"),
        },
        SelectCase {
            name: "short window beats a preferred long one",
            provider: Provider::Claude,
            options: vec![claude("a", 10.0, Some(10080), true), claude("b", 20.0, Some(300), false)],
            selection: Some(AUTOMATIC),
            expected: Some("b"),
        },
        SelectCase {
            name: "among short windows the first preferred wins",
            provider: Provider::Claude,
            options: vec![
                claude("a", 10.0, Some(300), false),
                claude("b", 10.0, Some(60), true),
                claude("c", 10.0, Some(120), true),
            ],
            selection: None,
            expected: Some("b"),
        },
        SelectCase {
            name: "among short windows none preferred -> first short",
            provider: Provider::Claude,
            options: vec![
                claude("x", 10.0, Some(10080), false),
                claude("a", 10.0, Some(300), false),
                claude("b", 10.0, Some(60), false),
            ],
            selection: None,
            expected: Some("a"),
        },
        SelectCase {
            name: "no short windows: first preferred of all valid",
            provider: Provider::Claude,
            options: vec![
                claude("a", 10.0, Some(10080), false),
                claude("b", 10.0, Some(10080), true),
                claude("c", 10.0, None, true),
            ],
            selection: None,
            expected: Some("b"),
        },
        SelectCase {
            name: "no short windows, none preferred: first",
            provider: Provider::Claude,
            options: vec![claude("a", 10.0, Some(10080), false), claude("b", 10.0, None, false)],
            selection: None,
            expected: Some("a"),
        },
        SelectCase {
            name: "durations 1440, 0, negative and None are not short; 1439 is",
            provider: Provider::Claude,
            options: vec![
                claude("a", 10.0, Some(1440), true),
                claude("b", 10.0, Some(0), true),
                claude("c", 10.0, Some(-5), true),
                claude("d", 10.0, None, true),
                claude("e", 10.0, Some(1439), false),
            ],
            selection: None,
            expected: Some("e"),
        },
        SelectCase {
            name: "one minute is short",
            provider: Provider::Claude,
            options: vec![claude("a", 10.0, Some(1440), true), claude("b", 10.0, Some(1), false)],
            selection: None,
            expected: Some("b"),
        },
        SelectCase {
            name: "no short windows with duration 0 and 1440 -> first preferred",
            provider: Provider::Claude,
            options: vec![claude("a", 10.0, Some(0), true), claude("b", 10.0, Some(1440), true)],
            selection: None,
            expected: Some("a"),
        },
        SelectCase {
            name: "invalid percentages are never selected automatically",
            provider: Provider::Claude,
            options: vec![
                claude("a", f64::NAN, Some(300), true),
                claude("b", -0.1, Some(300), true),
                claude("c", 100.1, Some(300), true),
                claude("d", f64::INFINITY, Some(300), true),
                claude("e", 55.0, Some(10080), false),
            ],
            selection: None,
            expected: Some("e"),
        },
        SelectCase {
            name: "0 percent is valid",
            provider: Provider::Claude,
            options: vec![claude("a", 0.0, Some(300), true)],
            selection: None,
            expected: Some("a"),
        },
        SelectCase {
            name: "100 percent is valid",
            provider: Provider::Claude,
            options: vec![claude("a", 100.0, Some(300), true)],
            selection: None,
            expected: Some("a"),
        },
        SelectCase {
            name: "only invalid options",
            provider: Provider::Claude,
            options: vec![claude("a", f64::NAN, Some(300), true), claude("b", 101.0, Some(300), true)],
            selection: None,
            expected: None,
        },
        SelectCase {
            name: "provider filter applies to automatic choice (Claude)",
            provider: Provider::Claude,
            options: vec![codex("x", 10.0, Some(300), true), claude("a", 10.0, Some(10080), false)],
            selection: None,
            expected: Some("a"),
        },
        SelectCase {
            name: "provider filter applies to automatic choice (Codex)",
            provider: Provider::Codex,
            options: vec![codex("x", 10.0, Some(300), true), claude("a", 10.0, Some(10080), false)],
            selection: None,
            expected: Some("x"),
        },
        SelectCase {
            name: "explicit id for Codex",
            provider: Provider::Codex,
            options: vec![codex("x", 10.0, Some(300), true), codex("y", 10.0, Some(10080), false)],
            selection: Some("y"),
            expected: Some("y"),
        },
    ];

    for case in &cases {
        let got = select_option(case.provider, &case.options, case.selection);
        assert_eq!(got.map(|o| o.id.as_str()), case.expected, "case: {}", case.name);
        if let Some(chosen) = got {
            assert!(
                case.options.iter().any(|o| std::ptr::eq(o, chosen)),
                "case {}: result must borrow from the input slice",
                case.name
            );
        }
    }
}

#[test]
fn reset_label_rounds_at_documented_boundaries() {
    // (remaining seconds, expected label)
    let table: &[(f64, &str)] = &[
        (-1_000_000.0, "0m"),
        (-1.0, "0m"),
        (0.0, "0m"),
        (0.001, "1m"),
        (1.0, "1m"),
        (59.0, "1m"),
        (60.0, "1m"),
        (60.5, "2m"),
        (61.0, "2m"),
        (120.0, "2m"),
        (3540.0, "59m"),
        (3599.0, "60m"),
        (3599.9, "60m"),
        (3600.0, "1h"),
        (4499.0, "1h"),
        (5400.0, "1h"),
        (6299.0, "1h"),
        (6300.0, "2h"),     // 1h45m rounds up
        (9899.0, "2h"),     // 2h44m59s
        (9900.0, "3h"),     // 2h45m
        (10800.0, "3h"),
        (85499.0, "23h"),   // 23h44m59s
        (85500.0, "24h"),   // 23h45m
        (85800.0, "24h"),   // 23h50m
        (86399.0, "24h"),
        (86399.5, "24h"),
        (86400.0, "1d"),
        (129599.0, "1d"),
        (129600.0, "2d"),
        (432000.0, "5d"),
        (604800.0, "7d"),
        (8_640_000.0, "100d"),
    ];
    for &(remaining, want) in table {
        assert_eq!(
            reset_label(Some(NOW + remaining), NOW).as_deref(),
            Some(want),
            "remaining = {remaining} s"
        );
    }
}

#[test]
fn reset_label_rejects_missing_and_out_of_range_times() {
    const MIN: f64 = -62135596800.0;
    const MAX: f64 = 253402300799.0;

    assert_eq!(reset_label(None, NOW), None);
    // spec: non-finite values are outside the range, hence None.
    let none_cases: &[(f64, f64, &str)] = &[
        (MIN - 1.0, 0.0, "resets_at one second before the minimum"),
        (MAX + 1.0, 0.0, "resets_at one second past year 9999"),
        (0.0, MIN - 1.0, "now one second before the minimum"),
        (0.0, MAX + 1.0, "now one second past year 9999"),
        (f64::NAN, 0.0, "resets_at NaN"),
        (f64::INFINITY, 0.0, "resets_at +inf"),
        (f64::NEG_INFINITY, 0.0, "resets_at -inf"),
        (0.0, f64::NAN, "now NaN"),
        (0.0, f64::INFINITY, "now +inf"),
        (1e18, 0.0, "resets_at far future"),
    ];
    for &(resets_at, now, why) in none_cases {
        assert_eq!(reset_label(Some(resets_at), now), None, "{why}");
    }

    // The boundaries themselves are inside the range.
    assert_eq!(reset_label(Some(MIN), MIN).as_deref(), Some("0m"));
    assert_eq!(reset_label(Some(MAX), MAX).as_deref(), Some("0m"));
    assert_eq!(reset_label(Some(MAX), 0.0).as_deref(), Some("2932897d"));
    assert_eq!(reset_label(Some(0.0), MIN).as_deref(), Some("719162d"));
}

#[test]
fn tray_label_joins_entries_with_two_spaces() {
    let mut c = claude("claude:five_hour", 5.0, Some(300), true);
    c.resets_at = Some(NOW + 10800.0); // "3h"
    let mut x = codex("codex:abc:primary", 15.0, Some(10080), true);
    x.resets_at = Some(NOW + 432000.0); // "5d"

    // Remaining mode (the macOS default)
    assert_eq!(
        tray_label(Some(&c), Some(&x), PercentageMode::Remaining, NOW),
        "Claude 95% · 3h  Codex 85% · 5d"
    );
    // Used mode
    assert_eq!(
        tray_label(Some(&c), Some(&x), PercentageMode::Used, NOW),
        "Claude 5% · 3h  Codex 15% · 5d"
    );
    // Single provider
    assert_eq!(
        tray_label(Some(&c), None, PercentageMode::Remaining, NOW),
        "Claude 95% · 3h"
    );
    assert_eq!(
        tray_label(None, Some(&x), PercentageMode::Remaining, NOW),
        "Codex 85% · 5d"
    );
    // Nothing connected
    assert_eq!(tray_label(None, None, PercentageMode::Remaining, NOW), "LimitFuel");
    assert_eq!(tray_label(None, None, PercentageMode::Used, NOW), "LimitFuel");
}

#[test]
fn tray_label_reset_suffix_edge_cases() {
    // No reset: no suffix.
    let c = claude("claude:five_hour", 5.0, Some(300), true);
    let mut x = codex("codex:abc:primary", 15.0, Some(300), true);
    assert_eq!(
        tray_label(Some(&c), Some(&x), PercentageMode::Remaining, NOW),
        "Claude 95%  Codex 85%"
    );

    // Reset in the past: "0m".
    x.resets_at = Some(NOW - 60.0);
    assert_eq!(
        tray_label(None, Some(&x), PercentageMode::Remaining, NOW),
        "Codex 85% · 0m"
    );

    // Out-of-range reset: reset_label is None, so no suffix.
    x.resets_at = Some(253402300800.0);
    assert_eq!(tray_label(None, Some(&x), PercentageMode::Remaining, NOW), "Codex 85%");

    // The percentage follows displayed_percent rounding (49.5 used -> 50.5 left -> 51).
    let mut half = claude("claude:five_hour", 49.5, Some(300), true);
    half.resets_at = Some(NOW + 59.0);
    assert_eq!(
        tray_label(Some(&half), None, PercentageMode::Remaining, NOW),
        "Claude 51% · 1m"
    );
    assert_eq!(
        tray_label(Some(&half), None, PercentageMode::Used, NOW),
        "Claude 50% · 1m"
    );
}

#[test]
fn duration_label_picks_largest_exact_unit() {
    let table: &[(i64, &str)] = &[
        (1, "1m"),
        (45, "45m"),
        (59, "59m"),
        (60, "1h"),
        (90, "90m"),
        (120, "2h"),
        (300, "5h"),
        (1380, "23h"),
        (1439, "1439m"),
        (1440, "1d"),
        (1500, "25h"),
        (2880, "2d"),
        (2900, "2900m"),
        (10080, "7d"),
        (43200, "30d"),
    ];
    for &(minutes, want) in table {
        assert_eq!(duration_label(minutes), want, "minutes = {minutes}");
    }
}
