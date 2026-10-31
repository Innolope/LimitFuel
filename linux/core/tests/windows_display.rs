//! Acceptance tests written from SPEC.md only; production bodies were not inspected.
//!
//! Plan: freeze exact formatting, then test reset removal and Unicode bounds.
//! What can go wrong (W4): invalid percentages leak, provider/entry order changes,
//! resets consume the budget, or truncation splits an emoji. Deterministic exhaustive
//! combinations below cover labels, counts and both modes; no random seed is used.
//! These pure functions have no concurrency, auth, retries, migration or I/O effects.

use limitfuel_core::display::{
    short_label, tray_tooltip, PercentageMode, Provider, WindowOption, TOOLTIP_LIMIT,
};

const NOW: f64 = 1_800_000_000.0;

fn window(provider: Provider, label: &str, percent: f64, reset: Option<f64>) -> WindowOption {
    WindowOption {
        id: label.into(),
        provider,
        label: label.into(),
        percent,
        duration_minutes: None,
        is_preferred_bucket: false,
        resets_at: reset,
    }
}

#[test]
fn short_labels_follow_the_spec_table_and_exact_part_matching() {
    for (label, expected) in [
        ("Session · 5h", "5h"),
        ("Weekly · 7d", "7d"),
        ("Sonnet · 7d", "Sonnet 7d"),
        ("GPT-5 · Session · 5h", "GPT-5 5h"),
        ("Primary", "Primary"),
        ("Secondary", "Secondary"),
        ("Weekly", "Weekly"),
        ("Session", "Session"),
        // Literal fallback: retain ALL original parts when every part is a role.
        ("Session · Weekly · Primary · Secondary", "Session Weekly Primary Secondary"),
        ("Primary · Primary · 2h · Secondary", "2h"),
        ("session · WEEKLY · 5h", "session WEEKLY 5h"),
        ("Sessionish · 5h", "Sessionish 5h"),
        ("Session·5h", "Session·5h"),
        (" Session · 5h", " Session 5h"),
        (" · Session · ", " "),
        ("", ""),
        ("🦀 · Session · 5h", "🦀 5h"),
    ] {
        assert_eq!(short_label(label), expected, "{label:?}");
    }
}

#[test]
fn tooltip_formats_both_modes_claude_first_and_preserves_entry_order() {
    let claude = [
        window(Provider::Claude, "Weekly · 7d", 100.0, Some(NOW + 2.0 * 86400.0)),
        window(Provider::Claude, "Session · 5h", 42.5, Some(NOW + 2.0 * 3600.0 + 45.0 * 60.0)),
        window(Provider::Claude, "Sonnet · 7d", 0.0, None),
    ];
    let codex = [window(Provider::Codex, "GPT-5 · Primary · 2h", 7.5, Some(NOW + 59.0))];
    for (mode, expected) in [
        (PercentageMode::Used, "Claude 7d 100% · 2d, 5h 43% · 3h, Sonnet 7d 0%\nCodex GPT-5 2h 8% · 1m"),
        (PercentageMode::Remaining, "Claude 7d 0% · 2d, 5h 58% · 3h, Sonnet 7d 100%\nCodex GPT-5 2h 93% · 1m"),
    ] {
        assert_eq!(tray_tooltip(&claude, &codex, mode, NOW), expected);
    }
}

#[test]
fn tooltip_skips_invalid_percents_and_omits_empty_provider_lines() {
    let bad: Vec<_> = [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, -0.01, 100.01]
        .into_iter().map(|p| window(Provider::Claude, "bad", p, None)).collect();
    assert_eq!(tray_tooltip(&bad, &[], PercentageMode::Used, NOW), "LimitFuel");
    assert_eq!(tray_tooltip(&[], &[], PercentageMode::Remaining, NOW), "LimitFuel");
    let good = window(Provider::Claude, "Session · 5h", 0.0, Some(f64::NAN));
    let mut mixed = bad.clone();
    mixed.insert(2, good);
    assert_eq!(tray_tooltip(&mixed, &[], PercentageMode::Used, NOW), "Claude 5h 0%");
    let codex = [window(Provider::Codex, "Weekly · 7d", 100.0, Some(253402300800.0))];
    assert_eq!(tray_tooltip(&bad, &codex, PercentageMode::Remaining, NOW), "Codex 7d 0%");
}

#[test]
fn tooltip_preserves_exactly_127_units_including_resets_when_they_fit() {
    for (length, reset, suffix) in [(117, None, ""), (112, Some(NOW + 60.0), " · 1m")] {
        let label = "x".repeat(length);
        let expected = format!("Claude {label} 1%{suffix}");
        assert_eq!(expected.encode_utf16().count(), 127);
        assert_eq!(tray_tooltip(&[window(Provider::Claude, &label, 1.0, reset)], &[], PercentageMode::Used, NOW), expected);
    }
    let label = "x".repeat(113);
    assert_eq!(tray_tooltip(&[window(Provider::Claude, &label, 1.0, Some(NOW + 60.0))], &[], PercentageMode::Used, NOW), format!("Claude {label} 1%"));
}

#[test]
fn tooltip_drops_all_resets_before_truncating() {
    // 126 units without resets; 136 with resets, so the second build fits.
    let label = "x".repeat(53);
    let claude = [window(Provider::Claude, &label, 1.0, Some(NOW + 60.0))];
    let codex = [window(Provider::Codex, &label, 2.0, Some(NOW + 60.0))];
    let expected = format!("Claude {label} 1%\nCodex {label} 2%");
    assert!(expected.encode_utf16().count() <= TOOLTIP_LIMIT);
    assert!(format!("Claude {label} 1% · 1m\nCodex {label} 2% · 1m").encode_utf16().count() > TOOLTIP_LIMIT);
    assert_eq!(tray_tooltip(&claude, &codex, PercentageMode::Used, NOW), expected);
}

#[test]
fn tooltip_truncates_longest_whole_character_prefix_and_trims_separators() {
    assert_eq!(TOOLTIP_LIMIT, 127);
    for suffix in ["tail", "🦀tail", " ,\ntail"] {
        // The first 126 units end in separators; all must be trimmed before ellipsis.
        let label = format!("{} ,\n{suffix}", "a".repeat(116));
        let windows = [window(Provider::Claude, &label, 1.0, None)];
        assert_eq!(tray_tooltip(&windows, &[], PercentageMode::Used, NOW), format!("Claude {}…", "a".repeat(116)));
    }
    // At unit 126 there is only room for half an emoji: keep neither half.
    let label = format!("{}🦀tail", "x".repeat(118));
    assert_eq!(tray_tooltip(&[window(Provider::Claude, &label, 1.0, None)], &[], PercentageMode::Used, NOW), format!("Claude {}…", "x".repeat(118)));
}

#[test]
fn tooltip_generated_inputs_obey_utf16_budget_and_preserve_fitting_text() {
    // 1,800 deterministic inputs: 5 alphabets x 10 lengths x 18 counts x 2 modes.
    for atom in ["a", "🦀", "a🚀", "界", "e\u{301}"] {
        for length in [0, 1, 2, 7, 30, 55, 60, 119, 127, 300] {
            for count in 0..18 {
                for mode in [PercentageMode::Used, PercentageMode::Remaining] {
                    let labels: Vec<_> = (0..count).map(|i| format!("{}-{i}", atom.repeat(length))).collect();
                    let claude: Vec<_> = labels.iter().map(|l| window(Provider::Claude, l, 25.0, None)).collect();
                    let codex: Vec<_> = labels.iter().rev().map(|l| window(Provider::Codex, l, 25.0, None)).collect();
                    let p = if mode == PercentageMode::Used { 25 } else { 75 };
                    let raw = if count == 0 { "LimitFuel".into() } else {
                        format!("Claude {}\nCodex {}",
                            labels.iter().map(|l| format!("{l} {p}%")).collect::<Vec<_>>().join(", "),
                            labels.iter().rev().map(|l| format!("{l} {p}%")).collect::<Vec<_>>().join(", "))
                    };
                    let actual = tray_tooltip(&claude, &codex, mode, NOW);
                    let utf16: Vec<_> = actual.encode_utf16().collect();
                    assert!(utf16.len() <= TOOLTIP_LIMIT, "length={length} count={count} atom={atom}");
                    assert!(char::decode_utf16(utf16).all(|ch| ch.is_ok()));
                    if raw.encode_utf16().count() <= TOOLTIP_LIMIT {
                        assert_eq!(actual, raw, "a fitting tooltip must remain unchanged");
                    } else {
                        let mut prefix = String::new();
                        let mut units = 0;
                        for ch in raw.chars() {
                            if units + ch.len_utf16() > 126 { break; }
                            prefix.push(ch);
                            units += ch.len_utf16();
                        }
                        let expected = format!("{}…", prefix.trim_end_matches([' ', ',', '\n']));
                        assert_eq!(actual, expected, "longest prefix must be preserved");
                    }
                }
            }
        }
    }
}
