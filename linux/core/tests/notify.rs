//! Acceptance tests for `limitfuel_core::notify`, written from SPEC.md only.

use limitfuel_core::notify::{ThresholdTracker, THRESHOLDS};

const RESET: Option<f64> = Some(1_000.0);

#[test]
fn thresholds_are_25_50_75_90() {
    assert_eq!(THRESHOLDS, [25u8, 50, 75, 90]);
}

#[test]
fn observe_reports_each_threshold_once_per_window() {
    // failure list #11: the same reading on every poll gives one notification
    // per threshold per reset window.
    let mut t = ThresholdTracker::new();
    let key = "claude:five_hour";
    let steps: &[(f64, Option<u8>)] = &[
        (0.0, None),
        (10.0, None),
        (24.99, None),
        (25.0, Some(25)),
        (25.0, None), // same reading again
        (25.0, None),
        (30.0, None),
        (49.99, None),
        (50.0, Some(50)),
        (49.0, None), // a lower reading never lowers the record
        (20.0, None),
        (50.0, None), // still nothing: 50 was already reported
        (74.9, None),
        (75.0, Some(75)),
        (89.99, None),
        (90.0, Some(90)),
        (90.0, None),
        (100.0, None), // nothing above 90
        (95.0, None),
    ];
    for (i, &(used, want)) in steps.iter().enumerate() {
        assert_eq!(t.observe(key, used, RESET), want, "step {i}: used = {used}");
    }
}

#[test]
fn observe_reports_the_highest_threshold_reached_when_jumping() {
    let table: &[(f64, Option<u8>)] = &[
        (80.0, Some(75)),
        (95.0, Some(90)),
        (100.0, Some(90)),
        (60.0, Some(50)),
        (26.0, Some(25)),
        (24.0, None),
    ];
    for &(used, want) in table {
        let mut t = ThresholdTracker::new();
        assert_eq!(t.observe("k", used, RESET), want, "first reading {used}");
    }

    // A jump after a lower threshold only reports the new highest one.
    let mut t = ThresholdTracker::new();
    assert_eq!(t.observe("k", 30.0, RESET), Some(25));
    assert_eq!(t.observe("k", 80.0, RESET), Some(75));
    assert_eq!(t.observe("k", 95.0, RESET), Some(90));
    assert_eq!(t.observe("k", 99.0, RESET), None);
}

#[test]
fn lower_reading_never_lowers_the_record() {
    let mut t = ThresholdTracker::new();
    assert_eq!(t.observe("k", 60.0, RESET), Some(50));
    assert_eq!(t.observe("k", 20.0, RESET), None);
    assert_eq!(t.observe("k", 55.0, RESET), None, "50 was already recorded");
    assert_eq!(t.observe("k", 76.0, RESET), Some(75));
}

#[test]
fn new_reset_time_starts_a_new_record() {
    let mut t = ThresholdTracker::new();
    assert_eq!(t.observe("k", 95.0, Some(1_000.0)), Some(90));
    assert_eq!(t.observe("k", 95.0, Some(1_000.0)), None);

    // The window reset: usage restarts from a low value under the new reset time.
    assert_eq!(t.observe("k", 30.0, Some(2_000.0)), Some(25));
    assert_eq!(t.observe("k", 30.0, Some(2_000.0)), None);
    assert_eq!(t.observe("k", 95.0, Some(2_000.0)), Some(90));

    // A sub-second difference is a different reset time.
    assert_eq!(t.observe("k", 30.0, Some(2_000.5)), Some(25));

    // No reset time is its own record, separate from any Some(..).
    assert_eq!(t.observe("k", 60.0, None), Some(50));
    assert_eq!(t.observe("k", 60.0, None), None);
    assert_eq!(t.observe("k", 60.0, Some(3_000.0)), Some(50));
}

#[test]
fn keys_are_independent() {
    let mut t = ThresholdTracker::new();
    assert_eq!(t.observe("claude:five_hour", 60.0, RESET), Some(50));
    assert_eq!(t.observe("claude:seven_day", 60.0, RESET), Some(50));
    assert_eq!(t.observe("codex:abc:primary", 60.0, RESET), Some(50));
    assert_eq!(t.observe("claude:five_hour", 60.0, RESET), None);
    assert_eq!(t.observe("claude:seven_day", 80.0, RESET), Some(75));
    assert_eq!(t.observe("claude:five_hour", 60.0, RESET), None);
}

#[test]
fn memory_is_bounded_to_256_keys_oldest_evicted_first() {
    // failure list #24
    let mut t = ThresholdTracker::new();
    for i in 0..257 {
        assert_eq!(t.observe(&format!("k{i}"), 30.0, RESET), Some(25), "insert k{i}");
    }
    // 257 distinct keys inserted: the oldest (k0) must have been evicted, the rest remembered.
    assert_eq!(t.observe("k256", 30.0, RESET), None, "newest key is remembered");
    assert_eq!(t.observe("k255", 30.0, RESET), None);
    assert_eq!(t.observe("k1", 30.0, RESET), None, "second oldest is still remembered");
    assert_eq!(
        t.observe("k0", 30.0, RESET),
        Some(25),
        "oldest key was evicted, so the same reading is new again"
    );
}

#[test]
fn memory_is_bounded_across_many_reset_windows_of_one_key() {
    // failure list #24: the tracking key includes the reset time, so a single
    // window that resets forever must not grow memory without bound.
    let mut t = ThresholdTracker::new();
    for i in 0..300 {
        assert_eq!(t.observe("claude:five_hour", 30.0, Some(f64::from(i))), Some(25), "reset {i}");
    }
    // 300 records were created, 256 may stay: resets 44..=299 remain, 0..=43 are gone.
    assert_eq!(t.observe("claude:five_hour", 30.0, Some(299.0)), None);
    assert_eq!(t.observe("claude:five_hour", 30.0, Some(44.0)), None);
    assert_eq!(t.observe("claude:five_hour", 30.0, Some(43.0)), Some(25));
}

#[test]
fn heavy_churn_stays_correct() {
    let mut t = ThresholdTracker::new();
    for i in 0..10_000 {
        assert_eq!(t.observe(&format!("key-{i}"), 51.0, RESET), Some(50));
    }
    // Early keys long forgotten, recent ones still remembered.
    assert_eq!(t.observe("key-9999", 51.0, RESET), None);
    assert_eq!(t.observe("key-0", 51.0, RESET), Some(50));
}
