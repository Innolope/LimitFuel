// Table-driven cases are tuples on purpose.
// Fake executables, symlinks and permission bits are Unix-only; Windows has its own tests.
#![cfg(unix)]
#![allow(clippy::type_complexity)]

//! Acceptance tests for `limitfuel_core::codex`, written from SPEC.md only.
//!
//! `CodexClient::fetch` runs against a fake `codex` executable (a Python script
//! written into a temp dir) that speaks the newline-delimited JSON-RPC from the
//! spec, appends every request it receives to a log file, and can misbehave in
//! scripted ways (EOF, errors, server requests, hangs, oversized output).

use std::fs;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant};

use limitfuel_core::codex::{
    parse_limits, resolve_executable, window_label, CodexBucket, CodexClient, CodexError,
    CodexSnapshot, CodexWindow, DEFAULT_TIMEOUT,
};
use limitfuel_core::display::Provider;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

const MIB: usize = 1024 * 1024;

fn close(a: f64, b: f64) -> bool {
    (a - b).abs() < 1e-6
}

fn sha256_hex(text: &str) -> String {
    let digest = Sha256::digest(text.as_bytes());
    let bytes: &[u8] = digest.as_ref();
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Runs every item on its own thread and reports all failures together, so
/// table-driven tests that spawn processes stay fast.
fn par<T: Send>(items: Vec<T>, f: impl Fn(T) + Sync) {
    let failures: Mutex<Vec<String>> = Mutex::new(Vec::new());
    thread::scope(|s| {
        for item in items {
            let f = &f;
            let failures = &failures;
            s.spawn(move || {
                let outcome =
                    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| f(item)));
                if let Err(payload) = outcome {
                    let msg = payload
                        .downcast_ref::<String>()
                        .cloned()
                        .or_else(|| payload.downcast_ref::<&str>().map(|s| s.to_string()))
                        .unwrap_or_else(|| "panic".to_string());
                    failures.lock().unwrap().push(msg);
                }
            });
        }
    });
    let failures = failures.into_inner().unwrap();
    assert!(
        failures.is_empty(),
        "{} case(s) failed:\n{}",
        failures.len(),
        failures.join("\n---\n")
    );
}

fn err_of<T>(result: Result<T, CodexError>, why: &str) -> CodexError {
    match result {
        Ok(_) => panic!("{why}: expected an error, got Ok"),
        Err(e) => e,
    }
}

// ---------------------------------------------------------------------------
// parse_limits
// ---------------------------------------------------------------------------

fn win(used: f64, minutes: i64, resets: i64) -> Value {
    json!({"usedPercent": used, "windowDurationMins": minutes, "resetsAt": resets})
}

fn bucket_json(limit_id: Option<&str>, name: Option<&str>, primary: Value, secondary: Value) -> Value {
    let mut m = serde_json::Map::new();
    if let Some(id) = limit_id {
        m.insert("limitId".into(), json!(id));
    }
    m.insert("limitName".into(), name.map_or(Value::Null, |n| json!(n)));
    m.insert("primary".into(), primary);
    m.insert("secondary".into(), secondary);
    Value::Object(m)
}

fn by_id(entries: Vec<(&str, Value)>) -> Value {
    let mut m = serde_json::Map::new();
    for (id, b) in entries {
        m.insert(id.to_string(), b);
    }
    json!({ "rateLimitsByLimitId": Value::Object(m) })
}

fn parse(v: &Value) -> Result<Vec<CodexBucket>, CodexError> {
    parse_limits(&serde_json::to_vec(v).unwrap())
}

fn expect_window(w: &Option<CodexWindow>, used: f64, minutes: Option<i64>, resets: Option<f64>, why: &str) {
    let w = w.as_ref().unwrap_or_else(|| panic!("{why}: window should be present"));
    assert!(close(w.used_percent, used), "{why}: used {} != {used}", w.used_percent);
    assert_eq!(w.window_duration_mins, minutes, "{why}: duration");
    match (w.resets_at, resets) {
        (Some(g), Some(e)) => assert!(close(g, e), "{why}: resets {g} != {e}"),
        (None, None) => {}
        (g, e) => panic!("{why}: resets {g:?} != {e:?}"),
    }
}

#[test]
fn default_timeout_is_forty_five_seconds() {
    assert_eq!(DEFAULT_TIMEOUT, Duration::from_secs(45));
}

#[test]
fn parse_limits_reads_buckets_sorted_by_id() {
    // spec: `body` is the JSON object of the account/rateLimits/read result;
    // in rateLimitsByLimitId the bucket id is the object key.
    let v = by_id(vec![
        ("codex_spark", bucket_json(None, Some("Spark"), win(10.0, 300, 1900000000), Value::Null)),
        ("codex", bucket_json(None, None, win(42.0, 300, 1900000000), win(7.5, 10080, 1900500000))),
        ("beta", bucket_json(Some("beta"), Some("Beta"), Value::Null, win(1.0, 60, 1900000001))),
    ]);
    let buckets = parse(&v).expect("valid limits");
    let got: Vec<(&str, &str)> = buckets.iter().map(|b| (b.id.as_str(), b.name.as_str())).collect();
    assert_eq!(got, vec![("beta", "Beta"), ("codex", "codex"), ("codex_spark", "Spark")]);

    let codex = &buckets[1];
    expect_window(&codex.primary, 42.0, Some(300), Some(1900000000.0), "codex primary");
    expect_window(&codex.secondary, 7.5, Some(10080), Some(1900500000.0), "codex secondary");
    assert!(buckets[0].primary.is_none(), "null window is None");
    expect_window(&buckets[0].secondary, 1.0, Some(60), Some(1900000001.0), "beta secondary");
    expect_window(&buckets[2].primary, 10.0, Some(300), Some(1900000000.0), "spark primary");
    assert!(buckets[2].secondary.is_none());
}

#[test]
fn parse_limits_falls_back_to_single_rate_limits_object() {
    let single = bucket_json(None, None, win(5.0, 300, 1900000000), Value::Null);
    let named = bucket_json(Some("codex_x"), Some("X"), win(6.0, 300, 1900000000), Value::Null);
    let cases: Vec<(&str, Value, &str, &str)> = vec![
        ("rateLimits only", json!({ "rateLimits": single.clone() }), "codex", "codex"),
        ("rateLimits with limitId", json!({ "rateLimits": named.clone() }), "codex_x", "X"),
        (
            "empty rateLimitsByLimitId",
            json!({ "rateLimitsByLimitId": {}, "rateLimits": single.clone() }),
            "codex",
            "codex",
        ),
        (
            "null rateLimitsByLimitId",
            json!({ "rateLimitsByLimitId": null, "rateLimits": single.clone() }),
            "codex",
            "codex",
        ),
        (
            "non-empty rateLimitsByLimitId wins over rateLimits",
            json!({ "rateLimitsByLimitId": { "codex_x": named.clone() }, "rateLimits": single.clone() }),
            "codex_x",
            "X",
        ),
    ];
    for (why, v, id, name) in cases {
        let buckets = parse(&v).unwrap_or_else(|e| panic!("{why}: {e:?}"));
        assert_eq!(buckets.len(), 1, "{why}");
        assert_eq!(buckets[0].id, id, "{why}");
        assert_eq!(buckets[0].name, name, "{why}");
    }
}

#[test]
fn parse_limits_window_shapes_and_boundaries() {
    let one = |primary: Value, secondary: Value| json!({ "rateLimits": bucket_json(None, None, primary, secondary) });

    // absent / null / without usedPercent -> None
    let v = json!({"rateLimits": {"limitId": "codex"}});
    let b = parse(&v).unwrap();
    assert!(b[0].primary.is_none() && b[0].secondary.is_none(), "absent windows");
    let b = parse(&one(Value::Null, Value::Null)).unwrap();
    assert!(b[0].primary.is_none() && b[0].secondary.is_none(), "null windows");
    let b = parse(&one(json!({"windowDurationMins": 300, "resetsAt": 1900000000}), Value::Null)).unwrap();
    assert!(b[0].primary.is_none(), "window without usedPercent is None");

    // optional fields inside a window
    let b = parse(&one(json!({"usedPercent": 10}), json!({"usedPercent": 20, "windowDurationMins": null, "resetsAt": null}))).unwrap();
    expect_window(&b[0].primary, 10.0, None, None, "bare primary");
    expect_window(&b[0].secondary, 20.0, None, None, "null optionals");

    // boundaries that are valid
    let ok_cases: Vec<(&str, Value, f64, Option<i64>, Option<f64>)> = vec![
        ("used 0", json!({"usedPercent": 0, "windowDurationMins": 1, "resetsAt": 0}), 0.0, Some(1), Some(0.0)),
        ("used 100", json!({"usedPercent": 100}), 100.0, None, None),
        // spec: only usedPercent < 0 is invalid, so values above 100 are kept as reported.
        ("used 120", json!({"usedPercent": 120}), 120.0, None, None),
        ("used fractional", json!({"usedPercent": 33.3}), 33.3, None, None),
        (
            "resetsAt at year 9999",
            json!({"usedPercent": 1, "resetsAt": 253402300799i64}),
            1.0,
            None,
            Some(253402300799.0),
        ),
        (
            "resetsAt fractional",
            json!({"usedPercent": 1, "resetsAt": 1900000000.5}),
            1.0,
            None,
            Some(1900000000.5),
        ),
        ("huge duration", json!({"usedPercent": 1, "windowDurationMins": 525600}), 1.0, Some(525600), None),
    ];
    for (why, window, used, minutes, resets) in ok_cases {
        let b = parse(&one(window, Value::Null)).unwrap_or_else(|e| panic!("{why}: {e:?}"));
        expect_window(&b[0].primary, used, minutes, resets, why);
    }

    // bucket count, id and name length limits
    let id200 = "i".repeat(200);
    let name200 = "n".repeat(200);
    let v = by_id(vec![(id200.as_str(), bucket_json(None, Some(&name200), win(1.0, 300, 1900000000), Value::Null))]);
    let b = parse(&v).expect("200-char id and name are fine");
    assert_eq!(b[0].id, id200);
    assert_eq!(b[0].name, name200);

    let mut m = serde_json::Map::new();
    for i in 0..64 {
        m.insert(format!("b{i:02}"), bucket_json(None, None, win(1.0, 300, 1900000000), Value::Null));
    }
    let b = parse(&json!({ "rateLimitsByLimitId": Value::Object(m) })).expect("64 buckets are fine");
    assert_eq!(b.len(), 64);
    let sorted: Vec<&str> = b.iter().map(|x| x.id.as_str()).collect();
    let mut expected = sorted.clone();
    expected.sort();
    assert_eq!(sorted, expected, "buckets sorted by id");
}

#[test]
fn parse_limits_rejects_malformed_documents() {
    // failure list #3: negative percent, fractional duration, reset past year 9999,
    // 65 buckets -> InvalidData.
    let good_window = win(1.0, 300, 1900000000);
    let one = |primary: Value| json!({ "rateLimits": bucket_json(None, None, primary, Value::Null) });
    let one_secondary = |secondary: Value| json!({ "rateLimits": bucket_json(None, None, Value::Null, secondary) });

    let mut too_many = serde_json::Map::new();
    for i in 0..65 {
        too_many.insert(format!("b{i:02}"), bucket_json(None, None, good_window.clone(), Value::Null));
    }

    let id201 = "i".repeat(201);
    let name201 = "n".repeat(201);

    let cases: Vec<(&str, Value)> = vec![
        ("65 buckets", json!({ "rateLimitsByLimitId": Value::Object(too_many) })),
        ("neither bucket source", json!({})),
        ("only unrelated fields", json!({"foo": 1})),
        ("empty rateLimitsByLimitId and no rateLimits", json!({"rateLimitsByLimitId": {}})),
        ("empty rateLimitsByLimitId and null rateLimits", json!({"rateLimitsByLimitId": {}, "rateLimits": null})),
        ("rateLimits is null", json!({"rateLimits": null})),
        ("rateLimits is a string", json!({"rateLimits": "x"})),
        ("empty id key", by_id(vec![("", bucket_json(None, None, good_window.clone(), Value::Null))])),
        ("201-char id key", by_id(vec![(id201.as_str(), bucket_json(None, None, good_window.clone(), Value::Null))])),
        (
            "201-char limitId in rateLimits",
            json!({ "rateLimits": bucket_json(Some(&id201), None, good_window.clone(), Value::Null) }),
        ),
        (
            "201-char limitName",
            json!({ "rateLimits": bucket_json(None, Some(&name201), good_window.clone(), Value::Null) }),
        ),
        ("negative usedPercent", one(json!({"usedPercent": -1, "windowDurationMins": 300}))),
        ("slightly negative usedPercent", one(json!({"usedPercent": -0.01}))),
        ("boolean usedPercent true", one(json!({"usedPercent": true}))),
        ("boolean usedPercent false", one(json!({"usedPercent": false}))),
        ("string usedPercent", one(json!({"usedPercent": "50"}))),
        ("array usedPercent", one(json!({"usedPercent": [1]}))),
        ("object usedPercent", one(json!({"usedPercent": {"v": 1}}))),
        ("fractional duration", one(json!({"usedPercent": 1, "windowDurationMins": 300.5}))),
        ("zero duration", one(json!({"usedPercent": 1, "windowDurationMins": 0}))),
        ("negative duration", one(json!({"usedPercent": 1, "windowDurationMins": -5}))),
        ("string duration", one(json!({"usedPercent": 1, "windowDurationMins": "300"}))),
        ("boolean duration", one(json!({"usedPercent": 1, "windowDurationMins": true}))),
        ("reset past year 9999", one(json!({"usedPercent": 1, "resetsAt": 253402300800i64}))),
        ("reset far in the future", one(json!({"usedPercent": 1, "resetsAt": 1_000_000_000_000_000i64}))),
        ("negative reset", one(json!({"usedPercent": 1, "resetsAt": -1}))),
        ("negative percent in the secondary window", one_secondary(json!({"usedPercent": -5}))),
        ("fractional duration in the secondary window", one_secondary(json!({"usedPercent": 5, "windowDurationMins": 10080.5}))),
        ("reset past 9999 in the secondary window", one_secondary(json!({"usedPercent": 5, "resetsAt": 253402300800i64}))),
        (
            "one bad bucket among good ones",
            by_id(vec![
                ("a", bucket_json(None, None, good_window.clone(), Value::Null)),
                ("b", bucket_json(None, None, json!({"usedPercent": -3}), Value::Null)),
                ("c", bucket_json(None, None, good_window.clone(), Value::Null)),
            ]),
        ),
    ];
    for (why, v) in &cases {
        assert_eq!(err_of(parse(v), why), CodexError::InvalidData, "{why}");
    }

    let raw_bad: Vec<(&str, Vec<u8>)> = vec![
        ("empty body", b"".to_vec()),
        ("not json", b"codex: command failed".to_vec()),
        ("truncated json", br#"{"rateLimits":{"limitId":"#.to_vec()),
        ("top-level array", b"[]".to_vec()),
        ("top-level string", br#""x""#.to_vec()),
        ("top-level number", b"7".to_vec()),
        ("top-level null", b"null".to_vec()),
        ("invalid utf-8", vec![0xff, 0xfe]),
    ];
    for (why, body) in &raw_bad {
        assert_eq!(err_of(parse_limits(body), why), CodexError::InvalidData, "{why}");
    }
}

#[test]
fn parse_limits_rejects_bodies_over_one_mebibyte() {
    // failure list #23: > 1 MiB rejected; exactly 1 MiB still parses.
    let json = serde_json::to_string(&json!({ "rateLimits": bucket_json(None, None, win(1.0, 300, 1900000000), Value::Null) })).unwrap();
    let pad = |total: usize| {
        let mut v = json.clone().into_bytes();
        v.resize(total, b' ');
        v
    };
    assert!(parse_limits(&pad(MIB)).is_ok(), "exactly 1 MiB is accepted");
    assert_eq!(err_of(parse_limits(&pad(MIB + 1)), "1 MiB + 1"), CodexError::InvalidData);
    assert_eq!(err_of(parse_limits(&pad(3 * MIB)), "3 MiB"), CodexError::InvalidData);
}

// ---------------------------------------------------------------------------
// window_label / window_options
// ---------------------------------------------------------------------------

#[test]
fn window_label_names_known_windows_and_formats_others() {
    let table: &[(Option<i64>, &str, &str)] = &[
        (Some(300), "Primary", "Session · 5h"),
        (Some(300), "Secondary", "Session · 5h"),
        (Some(10080), "Secondary", "Weekly · 7d"),
        (Some(10080), "Primary", "Weekly · 7d"),
        (Some(60), "Primary", "Primary · 1h"),
        (Some(120), "Role", "Role · 2h"),
        (Some(1440), "Secondary", "Secondary · 1d"),
        (Some(45), "X", "X · 45m"),
        (Some(90), "Primary", "Primary · 90m"),
        (None, "Primary", "Primary"),
        (None, "Secondary", "Secondary"),
    ];
    for &(minutes, role, want) in table {
        assert_eq!(window_label(minutes, role), want, "window_label({minutes:?}, {role:?})");
    }
}

fn cw(used: f64, minutes: Option<i64>, resets: Option<f64>) -> Option<CodexWindow> {
    Some(CodexWindow { used_percent: used, window_duration_mins: minutes, resets_at: resets })
}

fn cb(id: &str, name: &str, primary: Option<CodexWindow>, secondary: Option<CodexWindow>) -> CodexBucket {
    CodexBucket { id: id.to_string(), name: name.to_string(), primary, secondary }
}

fn snapshot(buckets: Vec<CodexBucket>) -> CodexSnapshot {
    CodexSnapshot { account_label: None, buckets }
}

#[test]
fn window_options_single_codex_bucket_has_stable_ids_and_no_prefix() {
    let opts = snapshot(vec![cb(
        "codex",
        "codex",
        cw(42.0, Some(300), Some(1900000000.0)),
        cw(7.5, Some(10080), Some(1900500000.0)),
    )])
    .window_options();
    assert_eq!(opts.len(), 2);
    // sha256("codex"), computed independently of the test helper
    let h = "57de4cf40144bdf7d00010f2f5557a7d642c2b9705309bfade167dd313e2ca93";
    assert_eq!(sha256_hex("codex"), h);

    assert_eq!(opts[0].id, format!("codex:{h}:primary"));
    assert_eq!(opts[0].label, "Session · 5h");
    assert_eq!(opts[0].provider, Provider::Codex);
    assert!(close(opts[0].percent, 42.0));
    assert_eq!(opts[0].duration_minutes, Some(300));
    assert!(opts[0].is_preferred_bucket);
    assert_eq!(opts[0].resets_at, Some(1900000000.0));

    assert_eq!(opts[1].id, format!("codex:{h}:secondary"));
    assert_eq!(opts[1].label, "Weekly · 7d");
    assert_eq!(opts[1].provider, Provider::Codex);
    assert!(close(opts[1].percent, 7.5));
    assert_eq!(opts[1].duration_minutes, Some(10080));
    assert!(opts[1].is_preferred_bucket);
    assert_eq!(opts[1].resets_at, Some(1900500000.0));
}

#[test]
fn window_options_prefix_rules() {
    let h = |s: &str| sha256_hex(s);
    // (description, buckets, expected labels in order)
    struct Case {
        why: &'static str,
        buckets: Vec<CodexBucket>,
        labels: Vec<String>,
        ids: Vec<String>,
        preferred: Vec<bool>,
    }
    let w300 = || cw(10.0, Some(300), None);
    let w10080 = || cw(20.0, Some(10080), None);
    let cases = vec![
        Case {
            why: "name 'Codex' is not prefixed (case-insensitive)",
            buckets: vec![cb("codex", "Codex", w300(), None)],
            labels: vec!["Session · 5h".into()],
            ids: vec![format!("codex:{}:primary", h("codex"))],
            preferred: vec![true],
        },
        Case {
            why: "name 'CODEX' is not prefixed (case-insensitive)",
            buckets: vec![cb("codex", "CODEX", w300(), None)],
            labels: vec!["Session · 5h".into()],
            ids: vec![format!("codex:{}:primary", h("codex"))],
            preferred: vec![true],
        },
        Case {
            why: "a non-codex bucket id with name 'codex' is not prefixed but not preferred",
            buckets: vec![cb("codex_alt", "codex", None, w10080())],
            labels: vec!["Weekly · 7d".into()],
            ids: vec![format!("codex:{}:secondary", h("codex_alt"))],
            preferred: vec![false],
        },
        Case {
            why: "a single bucket with another name is prefixed",
            buckets: vec![cb("codex_spark", "Spark", w300(), w10080())],
            labels: vec!["Spark · Session · 5h".into(), "Spark · Weekly · 7d".into()],
            ids: vec![
                format!("codex:{}:primary", h("codex_spark")),
                format!("codex:{}:secondary", h("codex_spark")),
            ],
            preferred: vec![false, false],
        },
        Case {
            why: "more than one bucket: every window is prefixed",
            buckets: vec![
                cb("codex", "codex", w300(), w10080()),
                cb("codex_spark", "Spark", w300(), None),
            ],
            labels: vec![
                "codex · Session · 5h".into(),
                "codex · Weekly · 7d".into(),
                "Spark · Session · 5h".into(),
            ],
            ids: vec![
                format!("codex:{}:primary", h("codex")),
                format!("codex:{}:secondary", h("codex")),
                format!("codex:{}:primary", h("codex_spark")),
            ],
            preferred: vec![true, true, false],
        },
        Case {
            why: "duplicate names show the id in parentheses",
            buckets: vec![cb("a", "Shared", w300(), None), cb("b", "Shared", w300(), w10080())],
            labels: vec![
                "Shared (a) · Session · 5h".into(),
                "Shared (b) · Session · 5h".into(),
                "Shared (b) · Weekly · 7d".into(),
            ],
            ids: vec![
                format!("codex:{}:primary", h("a")),
                format!("codex:{}:primary", h("b")),
                format!("codex:{}:secondary", h("b")),
            ],
            preferred: vec![false, false, false],
        },
        Case {
            why: "buckets without windows contribute nothing; order is bucket order, primary then secondary",
            buckets: vec![
                cb("x", "X", None, None),
                cb("y", "Y", None, w10080()),
                cb("z", "Z", w300(), w10080()),
            ],
            labels: vec![
                "Y · Weekly · 7d".into(),
                "Z · Session · 5h".into(),
                "Z · Weekly · 7d".into(),
            ],
            ids: vec![
                format!("codex:{}:secondary", h("y")),
                format!("codex:{}:primary", h("z")),
                format!("codex:{}:secondary", h("z")),
            ],
            preferred: vec![false, false, false],
        },
    ];
    for case in cases {
        let opts = snapshot(case.buckets).window_options();
        let labels: Vec<&str> = opts.iter().map(|o| o.label.as_str()).collect();
        let want: Vec<&str> = case.labels.iter().map(String::as_str).collect();
        assert_eq!(labels, want, "labels: {}", case.why);
        let ids: Vec<&str> = opts.iter().map(|o| o.id.as_str()).collect();
        let want: Vec<&str> = case.ids.iter().map(String::as_str).collect();
        assert_eq!(ids, want, "ids: {}", case.why);
        let preferred: Vec<bool> = opts.iter().map(|o| o.is_preferred_bucket).collect();
        assert_eq!(preferred, case.preferred, "preferred: {}", case.why);
        assert!(opts.iter().all(|o| o.provider == Provider::Codex), "{}", case.why);
    }

    assert!(snapshot(vec![]).window_options().is_empty());

    // Other durations use "{role} · {duration}": only the duration part is asserted.
    let opts = snapshot(vec![cb("codex", "codex", cw(1.0, Some(120), None), None)]).window_options();
    assert_eq!(opts.len(), 1);
    assert!(opts[0].label.ends_with(" · 2h"), "label was {:?}", opts[0].label);
    assert_eq!(opts[0].duration_minutes, Some(120));

    // A window with no duration still yields an option whose label is just the role.
    let opts = snapshot(vec![cb("codex", "codex", cw(1.0, None, None), None)]).window_options();
    assert_eq!(opts.len(), 1);
    assert!(!opts[0].label.is_empty());
    assert_eq!(opts[0].duration_minutes, None);
}

// ---------------------------------------------------------------------------
// resolve_executable
// ---------------------------------------------------------------------------

fn make_file(path: &Path, executable: bool) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, "#!/bin/sh\nexit 0\n").unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(if executable { 0o755 } else { 0o644 })).unwrap();
}

fn is_exec_file(p: &str) -> bool {
    fs::metadata(p).map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0).unwrap_or(false)
}

fn system_has_codex() -> bool {
    is_exec_file("/usr/local/bin/codex") || is_exec_file("/usr/bin/codex")
}

fn path_env(dirs: &[&Path]) -> String {
    std::env::join_paths(dirs).unwrap().into_string().unwrap()
}

#[test]
fn resolve_executable_prefers_custom_then_path_then_home_fallbacks() {
    let tmp = tempfile::tempdir().unwrap();
    let t = tmp.path();
    let home = t.join("home");
    fs::create_dir_all(&home).unwrap();

    // custom executable file wins over everything
    let custom = t.join("custom/mycodex");
    make_file(&custom, true);
    let bin_a = t.join("bin_a");
    make_file(&bin_a.join("codex"), true);
    let env_a = path_env(&[bin_a.as_path()]);
    assert_eq!(resolve_executable(Some(&custom), Some(&env_a), &home), Some(custom.clone()));

    // a custom path that is not an executable file is ignored: file without +x, directory, missing
    let not_exec = t.join("custom/not_exec");
    make_file(&not_exec, false);
    let a_dir = t.join("custom/a_dir");
    fs::create_dir_all(&a_dir).unwrap();
    let missing = t.join("custom/missing");
    for bad in [&not_exec, &a_dir, &missing] {
        assert_eq!(
            resolve_executable(Some(bad), Some(&env_a), &home),
            Some(bin_a.join("codex")),
            "custom {bad:?} must be ignored in favour of PATH"
        );
    }

    // PATH order: the first directory holding an executable codex wins
    let bin_b = t.join("bin_b");
    make_file(&bin_b.join("codex"), true);
    let env_ab = path_env(&[bin_a.as_path(), bin_b.as_path()]);
    let env_ba = path_env(&[bin_b.as_path(), bin_a.as_path()]);
    assert_eq!(resolve_executable(None, Some(&env_ab), &home), Some(bin_a.join("codex")));
    assert_eq!(resolve_executable(None, Some(&env_ba), &home), Some(bin_b.join("codex")));

    // non-executable files and directories named codex are skipped
    let bin_c = t.join("bin_c");
    make_file(&bin_c.join("codex"), false);
    let bin_d = t.join("bin_d");
    fs::create_dir_all(bin_d.join("codex")).unwrap();
    let env_cdb = path_env(&[bin_c.as_path(), bin_d.as_path(), bin_b.as_path()]);
    assert_eq!(resolve_executable(None, Some(&env_cdb), &home), Some(bin_b.join("codex")));

    // a symlink to an executable file counts as an executable file
    let bin_s = t.join("bin_s");
    fs::create_dir_all(&bin_s).unwrap();
    symlink(bin_b.join("codex"), bin_s.join("codex")).unwrap();
    let env_s = path_env(&[bin_s.as_path()]);
    assert_eq!(resolve_executable(None, Some(&env_s), &home), Some(bin_s.join("codex")));
}

#[test]
fn resolve_executable_home_fallbacks_and_absence() {
    let tmp = tempfile::tempdir().unwrap();
    let t = tmp.path();

    // ~/.local/bin/codex comes before ~/.npm-global/bin/codex
    let home = t.join("home1");
    make_file(&home.join(".local/bin/codex"), true);
    make_file(&home.join(".npm-global/bin/codex"), true);
    assert_eq!(resolve_executable(None, None, &home), Some(home.join(".local/bin/codex")));
    assert_eq!(resolve_executable(None, Some(""), &home), Some(home.join(".local/bin/codex")));

    // a non-executable ~/.local/bin/codex is skipped
    let home = t.join("home2");
    make_file(&home.join(".local/bin/codex"), false);
    make_file(&home.join(".npm-global/bin/codex"), true);
    assert_eq!(resolve_executable(None, None, &home), Some(home.join(".npm-global/bin/codex")));

    // only npm-global
    let home = t.join("home3");
    make_file(&home.join(".npm-global/bin/codex"), true);
    assert_eq!(resolve_executable(None, None, &home), Some(home.join(".npm-global/bin/codex")));

    // PATH beats the home fallbacks
    let home = t.join("home4");
    make_file(&home.join(".local/bin/codex"), true);
    let bin = t.join("bin_path");
    make_file(&bin.join("codex"), true);
    let env = path_env(&[bin.as_path()]);
    assert_eq!(resolve_executable(None, Some(&env), &home), Some(bin.join("codex")));

    // A custom path beats the home fallbacks too.
    let custom = t.join("c/codex-custom");
    make_file(&custom, true);
    assert_eq!(resolve_executable(Some(&custom), None, &home), Some(custom.clone()));

    // Nothing anywhere under the temp dirs: the answer depends only on the fixed
    // system locations, which this test cannot control.
    let empty_home = t.join("empty_home");
    fs::create_dir_all(&empty_home).unwrap();
    let empty_bin = t.join("empty_bin");
    fs::create_dir_all(&empty_bin).unwrap();
    make_file(&empty_bin.join("not-codex"), true);
    let env = path_env(&[empty_bin.as_path()]);
    let found = resolve_executable(None, Some(&env), &empty_home);
    if system_has_codex() {
        assert!(found.is_some(), "a system codex exists, so something must be found");
    } else {
        assert_eq!(found, None);
        assert_eq!(resolve_executable(None, None, &empty_home), None);
    }
}

// ---------------------------------------------------------------------------
// Fake codex executable
// ---------------------------------------------------------------------------

const FAKE_CODEX: &str = r####"#!/usr/bin/env python3
import json, os, signal, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(HERE, "cfg.json")) as f:
    CFG = json.load(f)
LOG = os.path.join(HERE, "log.txt")


def log(line):
    with open(LOG, "a") as f:
        f.write(line + "\n")


def write_all(data):
    view = memoryview(data)
    try:
        while len(view):
            n = os.write(1, view)
            view = view[n:]
    except OSError:
        os._exit(0)


def send(obj):
    write_all((json.dumps(obj) + "\n").encode())


log("ARGV " + " ".join(sys.argv[1:]))
log("PID %d" % os.getpid())
log("PGID %d" % os.getpgrp())
try:
    same = os.path.samestat(os.fstat(2), os.stat("/dev/null"))
except Exception:
    same = False
log("STDERR_DEVNULL %d" % (1 if same else 0))
if CFG.get("ignore_sigterm"):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
if CFG.get("spawn_child"):
    child = subprocess.Popen(["sleep", "300"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log("CHILD %d" % child.pid)

WIN_P = {"usedPercent": 42, "windowDurationMins": 300, "resetsAt": 1900000000}
WIN_S = {"usedPercent": 7.5, "windowDurationMins": 10080, "resetsAt": 1900500000}
BUCKET = {"limitId": "codex", "limitName": None, "primary": WIN_P, "secondary": WIN_S}
DEFAULTS = {
    "initialize": {"userAgent": "fake-codex/1.0"},
    "account/read": {
        "account": {"type": "chatgpt", "email": "user@example.com", "planType": "plus"},
        "requiresOpenaiAuth": True,
    },
    "account/rateLimits/read": {"rateLimits": BUCKET, "rateLimitsByLimitId": {"codex": BUCKET}},
}
counts = {}


def result_for(method, n):
    custom = CFG.get("results", {}).get(method)
    if custom is None:
        return DEFAULTS[method]
    return custom[min(n, len(custom)) - 1]


def run_hook(h, mid):
    a = h["action"]
    if a == "send":
        for m in h["msgs"]:
            send(m)
    elif a == "eof":
        os._exit(0)
    elif a == "hang":
        while True:
            time.sleep(1)
    elif a == "rpc_error":
        send({"id": mid, "error": {"code": h.get("code", -32000), "message": "boom"}})
    elif a == "blob":
        pre = '{"method":"big/notification","params":{"pad":"'
        post = '"}}'
        pad = h["bytes"] - len(pre) - len(post)
        data = (pre + "x" * pad + post).encode()
        if h.get("newline", True):
            data += b"\n"
        write_all(data)
        if h.get("then") == "hang":
            while True:
                time.sleep(1)
    elif a == "flood":
        line = ('{"method":"noise","params":{"pad":"' + "x" * h["line_bytes"] + '"}}\n').encode()
        batch = line * 500
        for _ in range(h["lines"] // 500):
            write_all(batch)
    elif a == "partial":
        write_all(h["text"].encode())
        if h.get("then", "hang") == "hang":
            while True:
                time.sleep(1)


def hooks(method, nth, phase):
    return [
        h
        for h in CFG.get("hooks", [])
        if h["method"] == method and h.get("nth", 1) in (0, nth) and h["phase"] == phase
    ]


def handle(method, mid, has_id):
    n = counts.get(method, 0) + 1
    counts[method] = n
    for h in hooks(method, n, "before"):
        run_hook(h, mid)
    instead = hooks(method, n, "instead")
    if instead:
        for h in instead:
            run_hook(h, mid)
        return
    if method not in DEFAULTS:
        if has_id:
            send({"id": mid, "error": {"code": -32601, "message": "unknown method"}})
        return
    if CFG.get("noise"):
        send({"method": "thread/started", "params": {"threadId": "t1"}})
    send({"id": mid, "result": result_for(method, n)})
    for h in hooks(method, n, "after"):
        run_hook(h, mid)


def lines():
    buf = b""
    while True:
        chunk = os.read(0, 65536)
        if not chunk:
            return
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            yield line


for raw in lines():
    if not raw.strip():
        continue
    try:
        msg = json.loads(raw)
    except Exception:
        log("BADJSON")
        continue
    method = msg.get("method")
    if method is None:
        err = msg.get("error")
        code = err.get("code") if isinstance(err, dict) else "-"
        log("RESP id=%s code=%s" % (json.dumps(msg.get("id")), code))
        continue
    has_id = "id" in msg
    log("RPC %s id=%s %s" % (method, json.dumps(msg["id"]) if has_id else "-", json.dumps(msg.get("params"), sort_keys=True)))
    handle(method, msg.get("id"), has_id)
os._exit(0)
"####;

#[derive(Debug, Clone)]
struct Rpc {
    method: String,
    id: Option<i64>,
    params: Value,
}

struct Fake {
    dir: tempfile::TempDir,
    exe: PathBuf,
}

fn hook(method: &str, nth: i64, phase: &str, extra: Value) -> Value {
    let mut m = extra.as_object().expect("hook body is an object").clone();
    m.insert("method".into(), json!(method));
    m.insert("nth".into(), json!(nth));
    m.insert("phase".into(), json!(phase));
    Value::Object(m)
}

fn instead(method: &str, action: Value) -> Value {
    hook(method, 1, "instead", action)
}

fn account(email: &str) -> Value {
    json!({"account": {"type": "chatgpt", "email": email, "planType": "plus"}, "requiresOpenaiAuth": true})
}

fn limits_with_primary(used: f64) -> Value {
    let b = json!({"limitId": "codex", "limitName": null,
        "primary": {"usedPercent": used, "windowDurationMins": 300, "resetsAt": 1900000000},
        "secondary": {"usedPercent": 7.5, "windowDurationMins": 10080, "resetsAt": 1900500000}});
    json!({"rateLimits": b, "rateLimitsByLimitId": {"codex": b}})
}

impl Fake {
    fn new(cfg: Value) -> Fake {
        let dir = tempfile::tempdir().unwrap();
        let exe = dir.path().join("codex");
        let mut cfg = cfg;
        if !cfg.is_object() {
            cfg = json!({});
        }
        fs::write(dir.path().join("cfg.json"), serde_json::to_vec(&cfg).unwrap()).unwrap();
        fs::write(&exe, FAKE_CODEX).unwrap();
        fs::set_permissions(&exe, fs::Permissions::from_mode(0o755)).unwrap();
        // Let the write handle be fully released before anything execs the script.
        thread::sleep(Duration::from_millis(15));
        Fake { dir, exe }
    }

    fn client(&self, timeout_secs: f64) -> CodexClient {
        CodexClient { executable: self.exe.clone(), timeout: Duration::from_secs_f64(timeout_secs) }
    }

    fn lines(&self) -> Vec<String> {
        fs::read_to_string(self.dir.path().join("log.txt"))
            .unwrap_or_default()
            .lines()
            .map(str::to_string)
            .collect()
    }

    fn value(&self, prefix: &str) -> Option<String> {
        self.lines().iter().find_map(|l| l.strip_prefix(prefix).map(|r| r.trim().to_string()))
    }

    fn rpcs(&self) -> Vec<Rpc> {
        self.lines()
            .iter()
            .filter_map(|l| l.strip_prefix("RPC "))
            .map(|rest| {
                let mut parts = rest.splitn(3, ' ');
                let method = parts.next().unwrap().to_string();
                let id = parts.next().unwrap().strip_prefix("id=").unwrap().to_string();
                let params = parts.next().unwrap_or("null");
                Rpc {
                    method,
                    id: if id == "-" { None } else { Some(id.parse().expect("numeric id")) },
                    params: serde_json::from_str(params).expect("params are JSON"),
                }
            })
            .collect()
    }

    fn methods(&self) -> Vec<String> {
        self.rpcs().into_iter().map(|r| r.method).collect()
    }

    fn ids_of(&self, method: &str) -> Vec<i64> {
        self.rpcs().into_iter().filter(|r| r.method == method).filter_map(|r| r.id).collect()
    }

    fn pid(&self) -> Option<i32> {
        self.value("PID ").and_then(|v| v.parse().ok())
    }

    fn child_pid(&self) -> Option<i32> {
        self.value("CHILD ").and_then(|v| v.parse().ok())
    }

    /// failure list #14: whatever the exit path, nothing from the fake survives.
    fn assert_cleaned_up(&self, why: &str) {
        // The process may still be starting when it is killed early. Wait for its
        // PID line; if none shows up it must also not show up later.
        let deadline = Instant::now() + Duration::from_secs(2);
        while self.pid().is_none() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(25));
        }
        match self.pid() {
            None => {
                thread::sleep(Duration::from_millis(1500));
                assert!(
                    self.pid().is_none(),
                    "{why}: the fake started after fetch returned, so it was not killed"
                );
            }
            Some(pid) => {
                assert!(
                    pid_gone_within(pid, Duration::from_secs(4)),
                    "{why}: fake process {pid} still exists after fetch returned (not killed or not reaped)"
                );
                if let Some(child) = self.child_pid() {
                    assert!(
                        pid_gone_within(child, Duration::from_secs(4)),
                        "{why}: grandchild {child} survived: the whole process group must be killed"
                    );
                }
            }
        }
    }

    fn wait_for_line(&self, wanted: &str, secs: f64) -> bool {
        let deadline = Instant::now() + Duration::from_secs_f64(secs);
        loop {
            if self.lines().iter().any(|l| l == wanted) {
                return true;
            }
            if Instant::now() >= deadline {
                return false;
            }
            thread::sleep(Duration::from_millis(25));
        }
    }
}

fn pid_gone_within(pid: i32, within: Duration) -> bool {
    let deadline = Instant::now() + within;
    loop {
        let rc = unsafe { libc::kill(pid, 0) };
        if rc != 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH) {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        thread::sleep(Duration::from_millis(20));
    }
}

// Generous: only reached when something is wrong, and cold Python starts can take seconds on a loaded CI box.
const LONG: f64 = 120.0;

fn assert_snapshot_defaults(snap: &CodexSnapshot) {
    assert_eq!(snap.account_label.as_deref(), Some("user@example.com"));
    assert_eq!(snap.buckets.len(), 1);
    let b = &snap.buckets[0];
    assert_eq!(b.id, "codex");
    assert_eq!(b.name, "codex");
    expect_window(&b.primary, 42.0, Some(300), Some(1900000000.0), "primary");
    expect_window(&b.secondary, 7.5, Some(10080), Some(1900500000.0), "secondary");
}

// ---------------------------------------------------------------------------
// fetch
// ---------------------------------------------------------------------------

#[test]
fn fetch_speaks_the_documented_rpc_sequence_in_its_own_process_group() {
    let fake = Fake::new(json!({"noise": true, "spawn_child": true}));
    let snap = fake.client(LONG).fetch().expect("fetch succeeds against the fake");
    assert_snapshot_defaults(&snap);

    // argv
    assert_eq!(fake.value("ARGV ").as_deref(), Some("app-server --listen stdio://"));

    // exact RPC order and ids
    assert_eq!(
        fake.methods(),
        vec!["initialize", "initialized", "account/read", "account/rateLimits/read"]
    );
    let rpcs = fake.rpcs();
    assert_eq!(rpcs[0].id, Some(1), "initialize is id 1");
    assert_eq!(rpcs[1].id, None, "initialized is a notification");
    assert_eq!(rpcs[2].id, Some(2), "account/read is id 2");
    assert_eq!(rpcs[2].params.get("refreshToken"), Some(&json!(false)), "refreshToken: false");
    assert_eq!(rpcs[3].id, Some(3), "account/rateLimits/read is id 3");

    // stderr is discarded (/dev/null)
    assert_eq!(fake.value("STDERR_DEVNULL ").as_deref(), Some("1"), "stderr must go to /dev/null");

    // own process group: the fake leads a group that is not ours
    let pid: i32 = fake.pid().expect("fake logged its pid");
    let pgid: i32 = fake.value("PGID ").and_then(|v| v.parse().ok()).expect("fake logged its pgid");
    assert_eq!(pgid, pid, "the child must lead its own process group");
    assert_ne!(pgid, unsafe { libc::getpgrp() }, "must not share the caller's process group");

    // failure list #14: the fake and its grandchild are gone on a successful exit too
    fake.assert_cleaned_up("success");
}

#[test]
fn fetch_label_comes_from_the_account_email_up_to_200_chars() {
    let long_email = format!("{}@example.com", "a".repeat(290));
    let cases: Vec<(&str, Value, Option<&str>)> = vec![
        ("plain email", account("someone@example.org"), Some("someone@example.org")),
        (
            "no email",
            json!({"account": {"type": "chatgpt", "planType": "plus"}, "requiresOpenaiAuth": true}),
            None,
        ),
        (
            "null email",
            json!({"account": {"type": "chatgpt", "email": null}, "requiresOpenaiAuth": true}),
            None,
        ),
    ];
    par(cases, |(why, acct, want)| {
        let fake = Fake::new(json!({"results": {"account/read": [acct]}}));
        let snap = fake.client(LONG).fetch().unwrap_or_else(|e| panic!("{why}: {e:?}"));
        assert_eq!(snap.account_label.as_deref(), want, "{why}");
        assert_eq!(snap.buckets.len(), 1, "{why}");
    });

    // spec: "at most 200 chars" - truncated or dropped, never longer.
    let fake = Fake::new(json!({"results": {"account/read": [account(&long_email)]}}));
    let snap = fake.client(LONG).fetch().expect("long email must not fail the fetch");
    if let Some(label) = &snap.account_label {
        assert!(label.chars().count() <= 200, "label has {} chars", label.chars().count());
    }
}

#[test]
fn fetch_treats_non_chatgpt_accounts_as_sign_in() {
    // failure list #22: Codex signed in with an API key -> SignIn
    let cases: Vec<(&str, Value)> = vec![
        ("API key account", json!({"account": {"type": "apiKey"}, "requiresOpenaiAuth": false})),
        ("API key account with email", json!({"account": {"type": "apiKey", "email": "a@b.c"}, "requiresOpenaiAuth": false})),
        ("unknown account type", json!({"account": {"type": "other"}, "requiresOpenaiAuth": true})),
        // spec: "an account that is not type chatgpt" includes no account at all.
        ("null account", json!({"account": null, "requiresOpenaiAuth": true})),
        ("account without a type", json!({"account": {"email": "a@b.c"}, "requiresOpenaiAuth": true})),
    ];
    par(cases, |(why, acct)| {
        let fake = Fake::new(json!({"results": {"account/read": [acct]}, "spawn_child": true}));
        let result = fake.client(LONG).fetch();
        assert_eq!(err_of(result, why), CodexError::SignIn, "{why}");
        fake.assert_cleaned_up(why);
    });
}

fn update_notice(auth_mode: Value) -> Value {
    json!({"method": "account/updated", "params": {"authMode": auth_mode}})
}

#[test]
fn fetch_handles_account_updated_notifications() {
    // authMode other than chatgpt -> SignIn
    par(
        vec![("apikey", json!("apikey")), ("apiKey", json!("apiKey"))],
        |(why, mode)| {
            let fake = Fake::new(json!({"hooks": [
                hook("account/read", 1, "after", json!({"action": "send", "msgs": [update_notice(mode)]}))
            ]}));
            let result = fake.client(LONG).fetch();
            assert_eq!(err_of(result, why), CodexError::SignIn, "authMode {why}");
            fake.assert_cleaned_up(why);
        },
    );

    // spec decision (SPEC.md, codex fetch): only an authMode *string* other than "chatgpt" is a
    // sign-out. A null or missing mode is confirmed by re-reading the account, like macOS.
    let fake = Fake::new(json!({
        "results": {
            "account/read": [account("same@example.com"), account("same@example.com")],
            "account/rateLimits/read": [limits_with_primary(11.0), limits_with_primary(77.0)]
        },
        "hooks": [hook("account/read", 1, "after", json!({"action": "send", "msgs": [update_notice(Value::Null)]}))]
    }));
    fake.client(LONG).fetch().expect("a null authMode is confirmed by a re-read");
    assert_eq!(fake.ids_of("account/read"), vec![2, 4], "null authMode re-reads the account once");
    fake.assert_cleaned_up("null authMode");

    // chatgpt + same email: exactly one extra account/read, limits are NOT re-read
    let fake = Fake::new(json!({
        "results": {
            "account/read": [account("same@example.com"), account("same@example.com")],
            "account/rateLimits/read": [limits_with_primary(11.0), limits_with_primary(77.0)]
        },
        "hooks": [hook("account/read", 1, "after", json!({"action": "send", "msgs": [update_notice(json!("chatgpt"))]}))]
    }));
    let snap = fake.client(LONG).fetch().expect("same-email update succeeds");
    assert_eq!(fake.ids_of("account/read"), vec![2, 4], "one extra account/read with id 4");
    assert_eq!(fake.ids_of("account/rateLimits/read"), vec![3], "limits are not re-read for the same email");
    assert_eq!(snap.account_label.as_deref(), Some("same@example.com"));
    expect_window(&snap.buckets[0].primary, 11.0, Some(300), Some(1900000000.0), "limits from the first read");
    fake.assert_cleaned_up("same email");

    // chatgpt + different email: account re-read (id 4) and limits re-read (id 5)
    let fake = Fake::new(json!({
        "results": {
            "account/read": [account("first@example.com"), account("second@example.com")],
            "account/rateLimits/read": [limits_with_primary(11.0), limits_with_primary(77.0)]
        },
        "hooks": [hook("account/read", 1, "after", json!({"action": "send", "msgs": [update_notice(json!("chatgpt"))]}))]
    }));
    let snap = fake.client(LONG).fetch().expect("different-email update succeeds");
    assert_eq!(fake.ids_of("account/read"), vec![2, 4]);
    assert_eq!(fake.ids_of("account/rateLimits/read"), vec![3, 5], "limits re-read with id 5");
    // spec: the label and limits describe the account that is signed in after the update.
    assert_eq!(snap.account_label.as_deref(), Some("second@example.com"));
    expect_window(&snap.buckets[0].primary, 77.0, Some(300), Some(1900000000.0), "limits from the re-read");
    fake.assert_cleaned_up("different email");

    // a further update while re-reading is a protocol error
    let again = || hook("account/read", 1, "after", json!({"action": "send", "msgs": [update_notice(json!("chatgpt"))]}));
    let during_account = json!({
        "results": {"account/read": [account("a@example.com"), account("b@example.com")]},
        "hooks": [again(), hook("account/read", 2, "before", json!({"action": "send", "msgs": [update_notice(json!("chatgpt"))]}))]
    });
    let during_limits = json!({
        "results": {
            "account/read": [account("a@example.com"), account("b@example.com")],
            "account/rateLimits/read": [limits_with_primary(11.0), limits_with_primary(77.0)]
        },
        "hooks": [again(), hook("account/rateLimits/read", 2, "before", json!({"action": "send", "msgs": [update_notice(json!("chatgpt"))]}))]
    });
    let during_account_same = json!({
        "results": {"account/read": [account("a@example.com"), account("a@example.com")]},
        "hooks": [again(), hook("account/read", 2, "before", json!({"action": "send", "msgs": [update_notice(json!("chatgpt"))]}))]
    });
    par(
        vec![
            ("second update during the account re-read", during_account),
            ("second update during the account re-read (same email)", during_account_same),
            ("second update during the limits re-read", during_limits),
        ],
        |(why, cfg)| {
            let fake = Fake::new(cfg);
            let result = fake.client(LONG).fetch();
            assert_eq!(err_of(result, why), CodexError::Protocol, "{why}");
            fake.assert_cleaned_up(why);
        },
    );
}

#[test]
fn fetch_answers_server_requests_with_method_not_found_and_fails_sign_in() {
    // (why, trigger method, request id as JSON, expected RESP log line)
    let cases: Vec<(&str, &str, Value, &str)> = vec![
        ("during initialize", "initialize", json!(77), "RESP id=77 code=-32601"),
        ("during account/read", "account/read", json!(78), "RESP id=78 code=-32601"),
        ("during account/rateLimits/read", "account/rateLimits/read", json!(79), "RESP id=79 code=-32601"),
        ("string id", "account/read", json!("srv-1"), "RESP id=\"srv-1\" code=-32601"),
    ];
    par(cases, |(why, trigger, id, expected_line)| {
        // The fake ignores SIGTERM so that it can still log the reply it was sent
        // before the client's SIGKILL arrives 0.5 s later.
        let fake = Fake::new(json!({
            "ignore_sigterm": true,
            "spawn_child": true,
            "hooks": [instead(trigger, json!({
                "action": "send",
                "msgs": [{"id": id, "method": "item/tool/requestUserInput", "params": {"questions": []}}]
            }))]
        }));
        let result = fake.client(LONG).fetch();
        assert_eq!(err_of(result, why), CodexError::SignIn, "{why}");
        assert!(
            fake.wait_for_line(expected_line, 4.0),
            "{why}: the server request must get a -32601 error reply; log was {:?}",
            fake.lines()
        );
        // SIGTERM is ignored, so this also proves the SIGKILL escalation.
        fake.assert_cleaned_up(why);
    });
}

#[test]
fn fetch_maps_eof_and_rpc_errors_to_protocol() {
    let mut cases: Vec<(String, Value)> = Vec::new();
    for method in ["initialize", "account/read", "account/rateLimits/read"] {
        cases.push((
            format!("EOF instead of the {method} reply"),
            json!({"spawn_child": true, "hooks": [instead(method, json!({"action": "eof"}))]}),
        ));
        cases.push((
            format!("JSON-RPC error for {method}"),
            json!({"spawn_child": true, "hooks": [instead(method, json!({"action": "rpc_error"}))]}),
        ));
    }
    par(cases, |(why, cfg)| {
        let fake = Fake::new(cfg);
        let result = fake.client(LONG).fetch();
        assert_eq!(err_of(result, &why), CodexError::Protocol, "{why}");
        // failure list #14: even when the leader exits by itself, the group is killed
        fake.assert_cleaned_up(&why);
    });
}

#[test]
fn fetch_ignores_notifications_and_surfaces_invalid_limits_as_invalid_data() {
    // Parse failures of the limits payload surface as InvalidData (failure list #3 end to end).
    let mut too_many = serde_json::Map::new();
    for i in 0..65 {
        too_many.insert(format!("b{i:02}"), json!({"primary": {"usedPercent": 1}}));
    }
    let cases: Vec<(&str, Value)> = vec![
        (
            "negative usedPercent",
            json!({"rateLimits": {"limitId": "codex", "primary": {"usedPercent": -1}}}),
        ),
        ("65 buckets", json!({"rateLimitsByLimitId": Value::Object(too_many)})),
        ("no buckets at all", json!({})),
        (
            "reset past year 9999",
            json!({"rateLimits": {"limitId": "codex", "primary": {"usedPercent": 1, "resetsAt": 253402300800i64}}}),
        ),
    ];
    par(cases, |(why, limits)| {
        let fake = Fake::new(json!({"noise": true, "spawn_child": true, "results": {"account/rateLimits/read": [limits]}}));
        let result = fake.client(LONG).fetch();
        assert_eq!(err_of(result, why), CodexError::InvalidData, "{why}");
        fake.assert_cleaned_up(why);
    });
}

#[test]
fn fetch_reports_unavailable_when_the_executable_cannot_start() {
    let tmp = tempfile::tempdir().unwrap();
    let t = tmp.path();

    let missing = t.join("no-such-codex");

    let not_exec = t.join("not-exec");
    make_file(&not_exec, false);

    let a_dir = t.join("a-dir");
    fs::create_dir_all(&a_dir).unwrap();

    let bad_shebang = t.join("bad-shebang");
    fs::write(&bad_shebang, "#!/nonexistent/interpreter\n").unwrap();
    fs::set_permissions(&bad_shebang, fs::Permissions::from_mode(0o755)).unwrap();
    thread::sleep(Duration::from_millis(15));

    for (why, exe) in [
        ("missing executable", missing),
        ("file without the execute bit", not_exec),
        ("directory", a_dir),
        ("interpreter that does not exist", bad_shebang),
    ] {
        let client = CodexClient { executable: exe, timeout: Duration::from_secs(10) };
        let started = Instant::now();
        assert_eq!(err_of(client.fetch(), why), CodexError::Unavailable, "{why}");
        assert!(started.elapsed() < Duration::from_secs(5), "{why}: must fail fast");
    }
}

#[test]
fn fetch_times_out_and_kills_the_process_group() {
    // failure list #14: the whole exchange shares one deadline, and the whole process
    // group is killed on exit. "hang" never replies; SIGTERM is ignored in the stubborn
    // cases so only the SIGKILL escalation (0.5 s later) can end them.
    struct Case {
        why: &'static str,
        cfg: Value,
        stubborn: bool,
    }
    let cases = vec![
        Case {
            why: "hang before the initialize reply",
            cfg: json!({"spawn_child": true, "hooks": [instead("initialize", json!({"action": "hang"}))]}),
            stubborn: false,
        },
        Case {
            why: "hang before the account reply",
            cfg: json!({"spawn_child": true, "hooks": [instead("account/read", json!({"action": "hang"}))]}),
            stubborn: false,
        },
        Case {
            why: "hang before the limits reply",
            cfg: json!({"spawn_child": true, "hooks": [instead("account/rateLimits/read", json!({"action": "hang"}))]}),
            stubborn: false,
        },
        Case {
            why: "half a line, then silence",
            cfg: json!({"spawn_child": true, "hooks": [instead("initialize", json!({"action": "partial", "text": "{\"id\":1,\"res"}))]}),
            stubborn: false,
        },
        Case {
            why: "notifications keep arriving but the replies never do",
            cfg: json!({"spawn_child": true, "hooks": [
                hook("account/read", 1, "before", json!({
                    "action": "send", "msgs": [{"method": "thread/started", "params": {}}]
                })),
                instead("account/read", json!({"action": "hang"}))
            ]}),
            stubborn: false,
        },
        Case {
            why: "hang that ignores SIGTERM",
            cfg: json!({"spawn_child": true, "ignore_sigterm": true, "hooks": [instead("account/read", json!({"action": "hang"}))]}),
            stubborn: true,
        },
    ];
    par(cases, |case| {
        let fake = Fake::new(case.cfg.clone());
        let started = Instant::now();
        let result = fake.client(1.0).fetch();
        let elapsed = started.elapsed();
        assert_eq!(err_of(result, case.why), CodexError::Timeout, "{}", case.why);
        let limit = if case.stubborn { Duration::from_secs(5) } else { Duration::from_secs(3) };
        assert!(elapsed < limit, "{}: fetch took {elapsed:?} with a 1 s timeout", case.why);
        assert!(elapsed >= Duration::from_millis(900), "{}: returned after only {elapsed:?}", case.why);
        fake.assert_cleaned_up(case.why);
    });
}

#[test]
fn fetch_rejects_output_over_one_mebibyte() {
    // failure list #23: Codex output > 1 MiB -> InvalidData
    // spec: "Output" is read as the total bytes read from the child's stdout.
    let cases: Vec<(&str, Value)> = vec![
        (
            "one 2 MiB line",
            json!({"spawn_child": true, "hooks": [hook("initialize", 1, "before", json!({"action": "blob", "bytes": 2 * MIB}))]}),
        ),
        (
            "2 MiB without a newline, then silence",
            json!({"spawn_child": true, "hooks": [hook("initialize", 1, "before", json!({"action": "blob", "bytes": 2 * MIB, "newline": false, "then": "hang"}))]}),
        ),
        (
            "an oversized line in the middle of the exchange",
            json!({"spawn_child": true, "hooks": [hook("account/rateLimits/read", 1, "before", json!({"action": "blob", "bytes": 3 * MIB}))]}),
        ),
        (
            "many small notifications adding up to more than 1 MiB",
            json!({"spawn_child": true, "hooks": [hook("initialize", 1, "before", json!({"action": "flood", "lines": 25000, "line_bytes": 100}))]}),
        ),
    ];
    par(cases, |(why, cfg)| {
        let fake = Fake::new(cfg);
        let result = fake.client(LONG).fetch();
        assert_eq!(err_of(result, why), CodexError::InvalidData, "{why}");
        fake.assert_cleaned_up(why);
    });
}
