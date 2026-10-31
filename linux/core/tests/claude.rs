// Table-driven cases are tuples on purpose.
#![allow(clippy::type_complexity)]

//! Acceptance tests for `limitfuel_core::claude`, written from SPEC.md only.
//!
//! `fetch` is exercised against a throw-away HTTP server on 127.0.0.1 that records
//! every request and can stall, reset, redirect, fail or send oversized bodies.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use limitfuel_core::claude::{
    org_id_from_cookie, parse_bootstrap, parse_iso8601, parse_usage, ClaudeClient, ClaudeError,
};
use limitfuel_core::display::{Provider, WindowOption};

const ORG: &str = "123e4567-e89b-12d3-a456-426614174000";
const BOOTSTRAP_PATH: &str = "/api/bootstrap";
const MIB: usize = 1024 * 1024;

fn usage_path(org: &str) -> String {
    format!("/api/organizations/{org}/usage")
}

fn bootstrap_body(org: &str) -> String {
    format!(r#"{{"account":{{"lastActiveOrgId":"{org}"}}}}"#)
}

const USAGE_OK: &str = r#"{"five_hour":{"utilization":42.5,"resets_at":"2025-01-01T05:00:00.123456+00:00"},"seven_day":{"utilization":10,"resets_at":"2025-01-05T00:00:00+00:00"}}"#;

fn close(a: f64, b: f64) -> bool {
    (a - b).abs() < 1e-6
}

fn pad_to(json: &str, total: usize) -> Vec<u8> {
    assert!(json.len() <= total);
    let mut v = json.as_bytes().to_vec();
    v.resize(total, b' ');
    v
}

// ---------------------------------------------------------------------------
// Pure parsers
// ---------------------------------------------------------------------------

#[test]
fn org_id_from_cookie_returns_lowercased_uuid_only() {
    let upper = "123E4567-E89B-12D3-A456-426614174000";
    let table: Vec<(String, Option<&str>)> = vec![
        (format!("lastActiveOrg={ORG}"), Some(ORG)),
        (format!("sessionKey=abc; lastActiveOrg={ORG}"), Some(ORG)),
        (format!("lastActiveOrg={ORG}; sessionKey=abc"), Some(ORG)),
        (format!("sessionKey=abc;lastActiveOrg={ORG};x=y"), Some(ORG)),
        (format!("  sessionKey=abc ;   lastActiveOrg={ORG}   "), Some(ORG)),
        (format!("lastActiveOrg={upper}"), Some(ORG)),
        ("lastActiveOrg=123E4567-e89b-12D3-a456-426614174000".to_string(), Some(ORG)),
        // not a UUID -> None
        ("lastActiveOrg=not-a-uuid".to_string(), None),
        ("lastActiveOrg=".to_string(), None),
        ("lastActiveOrg=123e4567-e89b-12d3-a456-42661417400".to_string(), None), // 11 in last group
        ("lastActiveOrg=123e4567-e89b-12d3-a456-4266141740000".to_string(), None), // 13 in last group
        ("lastActiveOrg=123e4567-e89b-12d3-a456-42661417400g".to_string(), None), // non-hex
        ("lastActiveOrg=123e4567e89b12d3a456426614174000".to_string(), None),     // no dashes
        (format!("lastActiveOrg={ORG}x"), None),
        (format!("lastActiveOrg=x{ORG}"), None),
        (format!("lastActiveOrg=\"{ORG}\""), None),
        (format!("lastActiveOrg={ORG} extra"), None),
        ("lastActiveOrg=1234567-e89b-12d3-a456-426614174000".to_string(), None), // 7 in first group
        // absent or differently named
        ("sessionKey=abc".to_string(), None),
        (String::new(), None),
        (format!("xlastActiveOrg={ORG}"), None),
        (format!("lastActiveOrgX={ORG}"), None),
        (format!("lastactiveorg={ORG}"), None),
        (format!("other={ORG}"), None),
    ];
    for (header, want) in &table {
        assert_eq!(
            org_id_from_cookie(header).as_deref(),
            *want,
            "header: {header:?}"
        );
    }
}

#[test]
fn parse_bootstrap_requires_a_uuid_org_id() {
    // Valid
    assert_eq!(parse_bootstrap(bootstrap_body(ORG).as_bytes()), Ok(ORG.to_string()));
    assert_eq!(
        parse_bootstrap(
            br#"{"other":1,"account":{"x":true,"lastActiveOrgId":"123e4567-e89b-12d3-a456-426614174000"}}"#
        ),
        Ok(ORG.to_string())
    );

    // Everything else is Protocol: invalid JSON, wrong shape, non-UUID.
    let bad: Vec<(&str, Vec<u8>)> = vec![
        ("empty body", b"".to_vec()),
        ("not json", b"<html>nope</html>".to_vec()),
        ("truncated json", br#"{"account":{"lastActiveOrgId":"#.to_vec()),
        ("array", b"[]".to_vec()),
        ("string", br#""x""#.to_vec()),
        ("null", b"null".to_vec()),
        ("empty object", b"{}".to_vec()),
        ("account is not an object", br#"{"account":"x"}"#.to_vec()),
        ("account is null", br#"{"account":null}"#.to_vec()),
        ("no org id", br#"{"account":{}}"#.to_vec()),
        ("org id null", br#"{"account":{"lastActiveOrgId":null}}"#.to_vec()),
        ("org id number", br#"{"account":{"lastActiveOrgId":12345}}"#.to_vec()),
        ("org id not a uuid", br#"{"account":{"lastActiveOrgId":"org_123"}}"#.to_vec()),
        ("org id empty", br#"{"account":{"lastActiveOrgId":""}}"#.to_vec()),
        (
            "org id has extra characters",
            br#"{"account":{"lastActiveOrgId":"123e4567-e89b-12d3-a456-426614174000/../x"}}"#.to_vec(),
        ),
        (
            "org id in the wrong place",
            br#"{"lastActiveOrgId":"123e4567-e89b-12d3-a456-426614174000"}"#.to_vec(),
        ),
        ("invalid utf-8", vec![0xff, 0xfe, 0x7b]),
    ];
    for (why, body) in &bad {
        assert_eq!(parse_bootstrap(body), Err(ClaudeError::Protocol), "{why}");
    }
}

fn expect_window(
    w: &WindowOption,
    id: &str,
    label: &str,
    percent: f64,
    duration: i64,
    preferred: bool,
    resets_at: Option<f64>,
) {
    assert_eq!(w.id, id);
    assert_eq!(w.provider, Provider::Claude, "{id}");
    assert_eq!(w.label, label, "{id}");
    assert!(close(w.percent, percent), "{id}: percent {} != {percent}", w.percent);
    assert_eq!(w.duration_minutes, Some(duration), "{id}");
    assert_eq!(w.is_preferred_bucket, preferred, "{id}");
    match (w.resets_at, resets_at) {
        (Some(got), Some(want)) => assert!(close(got, want), "{id}: resets_at {got} != {want}"),
        (None, None) => {}
        (got, want) => panic!("{id}: resets_at {got:?} != {want:?}"),
    }
}

fn ids(options: &[WindowOption]) -> Vec<&str> {
    options.iter().map(|o| o.id.as_str()).collect()
}

#[test]
fn parse_usage_builds_all_windows_in_order() {
    let body = br#"{
        "five_hour": {"utilization": 42.5, "resets_at": "2025-01-01T05:00:00.123456+00:00"},
        "seven_day": {"utilization": 10, "resets_at": "2025-01-05T00:00:00+00:00"},
        "seven_day_sonnet": {"utilization": 3.5, "resets_at": null},
        "limits": [
            {"scope": {"model": {"display_name": "Other"}}, "percent": 99, "resets_at": "2025-01-01T12:00:00Z"},
            {"scope": {"model": {"display_name": "Fable"}}, "percent": 33, "resets_at": "2025-01-01T12:00:00Z"},
            {"scope": {"model": {"display_name": "Fable"}}, "percent": 77, "resets_at": "2025-01-06T00:00:00Z"}
        ],
        "unknown_field": {"x": 1}
    }"#;
    let windows = parse_usage(body).expect("valid usage document");
    assert_eq!(
        ids(&windows),
        vec![
            "claude:five_hour",
            "claude:seven_day",
            "claude:seven_day_sonnet",
            "claude:seven_day_fable"
        ]
    );
    expect_window(&windows[0], "claude:five_hour", "Session · 5h", 42.5, 300, true, Some(1735707600.123456));
    expect_window(&windows[1], "claude:seven_day", "Weekly · 7d", 10.0, 10080, true, Some(1736035200.0));
    expect_window(&windows[2], "claude:seven_day_sonnet", "Sonnet · 7d", 3.5, 10080, false, None);
    // the FIRST limits[] entry whose display name is "Fable" is used
    expect_window(&windows[3], "claude:seven_day_fable", "Fable · 7d", 33.0, 10080, false, Some(1735732800.0));
}

#[test]
fn parse_usage_minimal_document_and_percent_boundaries() {
    let w = parse_usage(br#"{"five_hour":{"utilization":42.5,"resets_at":"2025-01-01T00:00:00Z"}}"#).unwrap();
    assert_eq!(ids(&w), vec!["claude:five_hour"]);
    expect_window(&w[0], "claude:five_hour", "Session · 5h", 42.5, 300, true, Some(1735689600.0));

    for (json, percent) in [
        (r#"{"five_hour":{"utilization":0}}"#, 0.0),
        (r#"{"five_hour":{"utilization":0.0}}"#, 0.0),
        (r#"{"five_hour":{"utilization":100}}"#, 100.0),
        (r#"{"five_hour":{"utilization":100.0}}"#, 100.0),
        (r#"{"five_hour":{"utilization":37}}"#, 37.0),
    ] {
        let w = parse_usage(json.as_bytes()).unwrap_or_else(|e| panic!("{json}: {e:?}"));
        assert_eq!(w.len(), 1, "{json}");
        assert!(close(w[0].percent, percent), "{json}");
        assert_eq!(w[0].resets_at, None, "{json}: no resets_at");
    }

    // Boundary percentages also work for the optional windows.
    let w = parse_usage(
        br#"{"five_hour":{"utilization":1},"seven_day":{"utilization":0},"seven_day_sonnet":{"utilization":100}}"#,
    )
    .unwrap();
    assert_eq!(ids(&w), vec!["claude:five_hour", "claude:seven_day", "claude:seven_day_sonnet"]);
}

#[test]
fn parse_usage_rejects_invalid_session_window() {
    // failure list #1: usage JSON missing five_hour, or utilization as
    // string/bool/NaN/150 -> InvalidData, no crash.
    let bad: Vec<(&str, Vec<u8>)> = vec![
        ("empty body", b"".to_vec()),
        ("not json", b"<html>502</html>".to_vec()),
        ("truncated json", br#"{"five_hour":{"utilization":4"#.to_vec()),
        ("invalid utf-8", vec![0xff, 0xfe, 0xfd]),
        ("top-level array", b"[]".to_vec()),
        ("top-level number", b"42".to_vec()),
        ("top-level string", br#""five_hour""#.to_vec()),
        ("top-level null", b"null".to_vec()),
        ("top-level bool", b"true".to_vec()),
        ("empty object", b"{}".to_vec()),
        ("five_hour missing, others present", br#"{"seven_day":{"utilization":10}}"#.to_vec()),
        ("five_hour null", br#"{"five_hour":null}"#.to_vec()),
        ("five_hour string", br#"{"five_hour":"42"}"#.to_vec()),
        ("five_hour array", br#"{"five_hour":[42]}"#.to_vec()),
        ("five_hour empty object", br#"{"five_hour":{}}"#.to_vec()),
        ("utilization missing", br#"{"five_hour":{"resets_at":"2025-01-01T00:00:00Z"}}"#.to_vec()),
        ("utilization null", br#"{"five_hour":{"utilization":null}}"#.to_vec()),
        ("utilization string", br#"{"five_hour":{"utilization":"42"}}"#.to_vec()),
        ("utilization numeric string", br#"{"five_hour":{"utilization":"4.5e1"}}"#.to_vec()),
        ("utilization true", br#"{"five_hour":{"utilization":true}}"#.to_vec()),
        ("utilization false", br#"{"five_hour":{"utilization":false}}"#.to_vec()),
        ("utilization array", br#"{"five_hour":{"utilization":[1]}}"#.to_vec()),
        ("utilization object", br#"{"five_hour":{"utilization":{"v":1}}}"#.to_vec()),
        ("utilization NaN literal", br#"{"five_hour":{"utilization":NaN}}"#.to_vec()),
        ("utilization 150", br#"{"five_hour":{"utilization":150}}"#.to_vec()),
        ("utilization 100.01", br#"{"five_hour":{"utilization":100.01}}"#.to_vec()),
        ("utilization -1", br#"{"five_hour":{"utilization":-1}}"#.to_vec()),
        ("utilization -0.01", br#"{"five_hour":{"utilization":-0.01}}"#.to_vec()),
        ("utilization 1e999", br#"{"five_hour":{"utilization":1e999}}"#.to_vec()),
        ("utilization -1e999", br#"{"five_hour":{"utilization":-1e999}}"#.to_vec()),
    ];
    for (why, body) in &bad {
        assert_eq!(parse_usage(body), Err(ClaudeError::InvalidData), "{why}");
    }
}

#[test]
fn parse_usage_skips_malformed_optional_windows() {
    // failure list #2: optional Claude windows malformed -> skipped; session still shown.
    let five = r#""five_hour":{"utilization":20,"resets_at":"2025-01-01T00:00:00Z"}"#;
    let cases: Vec<(&str, String, Vec<&str>)> = vec![
        ("seven_day utilization string", format!(r#"{{{five},"seven_day":{{"utilization":"50"}}}}"#), vec!["claude:five_hour"]),
        ("seven_day utilization true", format!(r#"{{{five},"seven_day":{{"utilization":true}}}}"#), vec!["claude:five_hour"]),
        ("seven_day utilization 100.5", format!(r#"{{{five},"seven_day":{{"utilization":100.5}}}}"#), vec!["claude:five_hour"]),
        ("seven_day utilization 150", format!(r#"{{{five},"seven_day":{{"utilization":150}}}}"#), vec!["claude:five_hour"]),
        ("seven_day utilization -1", format!(r#"{{{five},"seven_day":{{"utilization":-1}}}}"#), vec!["claude:five_hour"]),
        ("seven_day utilization null", format!(r#"{{{five},"seven_day":{{"utilization":null}}}}"#), vec!["claude:five_hour"]),
        ("seven_day empty object", format!(r#"{{{five},"seven_day":{{}}}}"#), vec!["claude:five_hour"]),
        ("seven_day null", format!(r#"{{{five},"seven_day":null}}"#), vec!["claude:five_hour"]),
        ("seven_day string", format!(r#"{{{five},"seven_day":"oops"}}"#), vec!["claude:five_hour"]),
        ("seven_day array", format!(r#"{{{five},"seven_day":[1,2]}}"#), vec!["claude:five_hour"]),
        ("sonnet utilization string", format!(r#"{{{five},"seven_day_sonnet":{{"utilization":"1"}}}}"#), vec!["claude:five_hour"]),
        ("sonnet utilization 101", format!(r#"{{{five},"seven_day_sonnet":{{"utilization":101}}}}"#), vec!["claude:five_hour"]),
        ("sonnet null", format!(r#"{{{five},"seven_day_sonnet":null}}"#), vec!["claude:five_hour"]),
        (
            "seven_day invalid, sonnet valid",
            format!(r#"{{{five},"seven_day":{{"utilization":"x"}},"seven_day_sonnet":{{"utilization":5}}}}"#),
            vec!["claude:five_hour", "claude:seven_day_sonnet"],
        ),
        (
            "seven_day valid, sonnet invalid",
            format!(r#"{{{five},"seven_day":{{"utilization":5}},"seven_day_sonnet":{{"utilization":false}}}}"#),
            vec!["claude:five_hour", "claude:seven_day"],
        ),
        ("limits is a string", format!(r#"{{{five},"limits":"Fable"}}"#), vec!["claude:five_hour"]),
        ("limits is null", format!(r#"{{{five},"limits":null}}"#), vec!["claude:five_hour"]),
        ("limits is an object", format!(r#"{{{five},"limits":{{"percent":5}}}}"#), vec!["claude:five_hour"]),
        ("limits is empty", format!(r#"{{{five},"limits":[]}}"#), vec!["claude:five_hour"]),
        (
            "limits entries of the wrong type",
            format!(r#"{{{five},"limits":[1,"x",null,[],{{}}]}}"#),
            vec!["claude:five_hour"],
        ),
        (
            "limits entry without scope",
            format!(r#"{{{five},"limits":[{{"percent":10}}]}}"#),
            vec!["claude:five_hour"],
        ),
        (
            "scope.model is null",
            format!(r#"{{{five},"limits":[{{"scope":{{"model":null}},"percent":10}}]}}"#),
            vec!["claude:five_hour"],
        ),
        (
            "display_name is a number",
            format!(r#"{{{five},"limits":[{{"scope":{{"model":{{"display_name":7}}}},"percent":10}}]}}"#),
            vec!["claude:five_hour"],
        ),
        (
            // spec: display_name must be exactly "Fable".
            "display_name is lowercase",
            format!(r#"{{{five},"limits":[{{"scope":{{"model":{{"display_name":"fable"}}}},"percent":10}}]}}"#),
            vec!["claude:five_hour"],
        ),
        (
            "Fable percent is a string",
            format!(r#"{{{five},"limits":[{{"scope":{{"model":{{"display_name":"Fable"}}}},"percent":"10"}}]}}"#),
            vec!["claude:five_hour"],
        ),
        (
            "Fable percent is out of range",
            format!(r#"{{{five},"limits":[{{"scope":{{"model":{{"display_name":"Fable"}}}},"percent":150}}]}}"#),
            vec!["claude:five_hour"],
        ),
        (
            "Fable percent is negative",
            format!(r#"{{{five},"limits":[{{"scope":{{"model":{{"display_name":"Fable"}}}},"percent":-3}}]}}"#),
            vec!["claude:five_hour"],
        ),
        (
            "Fable percent is missing",
            format!(r#"{{{five},"limits":[{{"scope":{{"model":{{"display_name":"Fable"}}}}}}]}}"#),
            vec!["claude:five_hour"],
        ),
        (
            "everything optional is broken at once",
            format!(
                r#"{{{five},"seven_day":"x","seven_day_sonnet":[],"limits":{{"a":1}}}}"#
            ),
            vec!["claude:five_hour"],
        ),
    ];
    for (why, body, want_ids) in &cases {
        let windows = parse_usage(body.as_bytes()).unwrap_or_else(|e| panic!("{why}: {e:?}"));
        assert_eq!(ids(&windows), *want_ids, "{why}");
        // the session window is intact
        expect_window(&windows[0], "claude:five_hour", "Session · 5h", 20.0, 300, true, Some(1735689600.0));
    }

    // A valid Fable entry that is not first in limits[] still produces the window.
    let body = format!(
        r#"{{{five},"limits":[{{"scope":{{"model":{{"display_name":"Opus"}}}},"percent":1}},{{"scope":{{"model":{{"display_name":"Fable"}}}},"percent":64.5,"resets_at":"2025-01-02T00:00:00Z"}}]}}"#
    );
    let windows = parse_usage(body.as_bytes()).unwrap();
    assert_eq!(ids(&windows), vec!["claude:five_hour", "claude:seven_day_fable"]);
    expect_window(&windows[1], "claude:seven_day_fable", "Fable · 7d", 64.5, 10080, false, Some(1735776000.0));
}

#[test]
fn parse_usage_resets_at_is_lenient_about_fractions_and_garbage() {
    let table: Vec<(&str, Option<f64>)> = vec![
        (r#""2025-01-01T00:00:00Z""#, Some(1735689600.0)),
        (r#""2025-01-01T00:00:00.5Z""#, Some(1735689600.5)),
        (r#""2025-01-01T00:00:00.123456Z""#, Some(1735689600.123456)),
        (r#""2025-01-01T00:00:00+00:00""#, Some(1735689600.0)),
        (r#""2025-01-01T00:00:00.250000+00:00""#, Some(1735689600.25)),
        (r#""not a date""#, None),
        (r#""""#, None),
        (r#""2025-13-45T99:00:00Z""#, None),
        (r#"null"#, None),
        (r#"12345"#, None),
        (r#"true"#, None),
    ];
    for (raw, want) in table {
        let body = format!(r#"{{"five_hour":{{"utilization":20,"resets_at":{raw}}}}}"#);
        let windows = parse_usage(body.as_bytes()).unwrap_or_else(|e| panic!("{raw}: {e:?}"));
        assert_eq!(windows.len(), 1, "{raw}: unparseable resets_at must not drop the window");
        match (windows[0].resets_at, want) {
            (Some(g), Some(w)) => assert!(close(g, w), "{raw}: {g} != {w}"),
            (None, None) => {}
            (g, w) => panic!("{raw}: got {g:?}, want {w:?}"),
        }
    }
}

#[test]
fn parse_iso8601_handles_fractions_zones_and_garbage() {
    let ok: Vec<(&str, f64)> = vec![
        ("1970-01-01T00:00:00Z", 0.0),
        ("1969-12-31T23:59:59Z", -1.0),
        ("2025-01-01T00:00:00Z", 1735689600.0),
        ("2024-02-29T12:00:00Z", 1709208000.0),
        ("2025-01-01T00:00:00.5Z", 1735689600.5),
        ("2025-01-01T00:00:00.123456Z", 1735689600.123456),
        ("2025-01-01T00:00:00.999Z", 1735689600.999),
        ("2025-01-01T00:00:00+00:00", 1735689600.0),
        ("2025-01-01T00:00:00.250+00:00", 1735689600.25),
        // spec: ISO 8601 offsets are honoured (the API sends "+00:00"; other offsets denote the same instant).
        ("2025-01-01T00:00:00+02:00", 1735682400.0),
        ("9999-12-31T23:59:59Z", 253402300799.0),
    ];
    for (text, want) in ok {
        let got = parse_iso8601(text).unwrap_or_else(|| panic!("{text} should parse"));
        assert!(close(got, want), "{text}: {got} != {want}");
    }
    let bad = [
        "",
        "garbage",
        "2025",
        "2025-13-01T00:00:00Z",
        "2025-02-30T00:00:00Z",
        "2023-02-29T00:00:00Z",
        "2025-01-01T25:00:00Z",
        "2025-01-01T00:61:00Z",
        "2025-01-01 00:00:00Z extra",
        "Z",
        "T00:00:00Z",
        "20250101T000000Z garbage",
    ];
    for text in bad {
        assert_eq!(parse_iso8601(text), None, "{text:?} must not parse");
    }
}

// ---------------------------------------------------------------------------
// Fake HTTP server
// ---------------------------------------------------------------------------

#[derive(Clone)]
enum Behavior {
    /// Normal response with Content-Length.
    Respond,
    /// Body delimited by closing the connection (no Content-Length).
    NoContentLength,
    /// Read the request, then say nothing for a long time.
    StallBeforeResponse,
    /// Send the headers and a few body bytes, then go quiet.
    StallMidBody,
    /// Read the request, then close with a TCP RST.
    Reset,
}

#[derive(Clone)]
struct Route {
    status: u16,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
    behavior: Behavior,
}

impl Route {
    fn new(status: u16, body: impl Into<Vec<u8>>) -> Route {
        Route { status, headers: Vec::new(), body: body.into(), behavior: Behavior::Respond }
    }
    fn header(mut self, name: &str, value: &str) -> Route {
        self.headers.push((name.to_string(), value.to_string()));
        self
    }
    fn behavior(mut self, behavior: Behavior) -> Route {
        self.behavior = behavior;
        self
    }
}

#[derive(Clone, Debug)]
struct Seen {
    method: String,
    path: String,
    headers: Vec<(String, String)>,
}

impl Seen {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
    }
}

struct TestServer {
    addr: SocketAddr,
    seen: Arc<Mutex<Vec<Seen>>>,
}

impl TestServer {
    fn start(routes: Vec<(String, Route)>) -> TestServer {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().unwrap();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let routes = Arc::new(routes);
        let seen_for_thread = seen.clone();
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { continue };
                let routes = routes.clone();
                let seen = seen_for_thread.clone();
                thread::spawn(move || handle(stream, &routes, &seen));
            }
        });
        TestServer { addr, seen }
    }

    fn url(&self) -> String {
        format!("http://{}", self.addr)
    }

    fn client(&self) -> ClaudeClient {
        ClaudeClient::new(&self.url(), Duration::from_secs(10))
    }

    fn requests(&self) -> Vec<Seen> {
        self.seen.lock().unwrap().clone()
    }

    fn paths(&self) -> Vec<String> {
        self.requests().into_iter().map(|r| r.path).collect()
    }

    fn count(&self, path: &str) -> usize {
        self.paths().iter().filter(|p| p.as_str() == path).count()
    }
}

fn reason(status: u16) -> &'static str {
    match status {
        200 => "OK",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        303 => "See Other",
        307 => "Temporary Redirect",
        308 => "Permanent Redirect",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        _ => "Status",
    }
}

fn handle(mut stream: TcpStream, routes: &[(String, Route)], seen: &Mutex<Vec<Seen>>) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    while !buf.windows(4).any(|w| w == b"\r\n\r\n") {
        match stream.read(&mut chunk) {
            Ok(0) | Err(_) => return,
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
        }
        if buf.len() > 64 * 1024 {
            return;
        }
    }
    let head = String::from_utf8_lossy(&buf).to_string();
    let mut lines = head.split("\r\n");
    let request_line = lines.next().unwrap_or("");
    let mut parts = request_line.split(' ');
    let method = parts.next().unwrap_or("").to_string();
    let path = parts.next().unwrap_or("").to_string();
    let mut headers = Vec::new();
    for line in lines {
        if line.is_empty() {
            break;
        }
        if let Some((k, v)) = line.split_once(':') {
            headers.push((k.trim().to_ascii_lowercase(), v.trim().to_string()));
        }
    }
    seen.lock().unwrap().push(Seen { method, path: path.clone(), headers });

    let route = routes
        .iter()
        .find(|(p, _)| *p == path)
        .map(|(_, r)| r.clone())
        .unwrap_or_else(|| Route::new(404, "{}"));

    let mut head = format!("HTTP/1.1 {} {}\r\nContent-Type: application/json\r\nConnection: close\r\n", route.status, reason(route.status));
    for (k, v) in &route.headers {
        head.push_str(&format!("{k}: {v}\r\n"));
    }
    match route.behavior {
        Behavior::Respond => {
            head.push_str(&format!("Content-Length: {}\r\n\r\n", route.body.len()));
            let _ = stream.write_all(head.as_bytes());
            let _ = stream.write_all(&route.body);
            let _ = stream.flush();
        }
        Behavior::NoContentLength => {
            head.push_str("\r\n");
            let _ = stream.write_all(head.as_bytes());
            let _ = stream.write_all(&route.body);
            let _ = stream.flush();
        }
        Behavior::StallBeforeResponse => {
            thread::sleep(Duration::from_secs(5));
        }
        Behavior::StallMidBody => {
            head.push_str("Content-Length: 4096\r\n\r\n");
            let _ = stream.write_all(head.as_bytes());
            let _ = stream.write_all(b"{\"five_hour\":");
            let _ = stream.flush();
            thread::sleep(Duration::from_secs(5));
        }
        Behavior::Reset => reset(stream),
    }
}

/// Closes with RST instead of FIN: SO_LINGER on, with a zero timeout.
#[cfg(unix)]
fn reset(stream: TcpStream) {
    use std::os::fd::AsRawFd;
    let linger = libc::linger { l_onoff: 1, l_linger: 0 };
    unsafe {
        libc::setsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_LINGER,
            &linger as *const libc::linger as *const libc::c_void,
            std::mem::size_of::<libc::linger>() as libc::socklen_t,
        );
    }
    drop(stream);
}

#[cfg(windows)]
fn reset(stream: TcpStream) {
    use std::os::windows::io::AsRawSocket;
    use windows_sys::Win32::Networking::WinSock::{LINGER, SO_LINGER, SOL_SOCKET, setsockopt};
    let linger = LINGER { l_onoff: 1, l_linger: 0 };
    let size = std::mem::size_of::<LINGER>() as i32;
    unsafe { setsockopt(stream.as_raw_socket() as usize, SOL_SOCKET, SO_LINGER, (&raw const linger).cast(), size) };
    drop(stream);
}

fn routes_ok(org: &str) -> Vec<(String, Route)> {
    vec![
        (BOOTSTRAP_PATH.to_string(), Route::new(200, bootstrap_body(org))),
        (usage_path(org), Route::new(200, USAGE_OK)),
    ]
}

fn cookie_no_org() -> String {
    "sessionKey=sk-ant-sid01-abc; routingHint=zz".to_string()
}

fn cookie_with_org(org: &str) -> String {
    format!("sessionKey=sk-ant-sid01-abc; lastActiveOrg={org}; routingHint=zz")
}

// ---------------------------------------------------------------------------
// fetch
// ---------------------------------------------------------------------------

#[test]
fn fetch_bootstraps_then_reads_usage_and_sends_required_headers() {
    let server = TestServer::start(routes_ok(ORG));
    let cookie = cookie_no_org();
    let windows = server.client().fetch(&cookie).expect("fetch succeeds");

    // The result is exactly what parse_usage makes of the usage body.
    assert_eq!(Ok(windows), parse_usage(USAGE_OK.as_bytes()));

    let requests = server.requests();
    let paths: Vec<&str> = requests.iter().map(|r| r.path.as_str()).collect();
    let usage = usage_path(ORG);
    assert_eq!(paths, vec![BOOTSTRAP_PATH, usage.as_str()], "bootstrap first, then usage for that org");
    for r in &requests {
        assert_eq!(r.method, "GET", "{}", r.path);
        assert_eq!(r.header("cookie"), Some(cookie.as_str()), "cookie header on {}", r.path);
        assert_eq!(r.header("accept"), Some("*/*"), "accept header on {}", r.path);
        let ua = r.header("user-agent").unwrap_or_else(|| panic!("no User-Agent on {}", r.path));
        assert!(
            ua.contains("Mozilla/5.0") && ua.contains("Chrome/"),
            "User-Agent must look like desktop Chrome, got {ua:?}"
        );
        assert!(!ua.contains("Mobile"), "desktop UA expected, got {ua:?}");
    }
}

#[test]
fn fetch_with_org_in_cookie_skips_bootstrap() {
    let server = TestServer::start(routes_ok(ORG));
    let cookie = cookie_with_org(ORG);
    let windows = server.client().fetch(&cookie).expect("fetch succeeds");
    assert_eq!(windows.len(), 2);
    assert_eq!(server.paths(), vec![usage_path(ORG)], "no /api/bootstrap request");
    let r = &server.requests()[0];
    assert_eq!(r.header("cookie"), Some(cookie.as_str()));
    assert_eq!(r.header("accept"), Some("*/*"));
    assert!(r.header("user-agent").unwrap_or("").contains("Chrome/"));

    // An upper-case org id in the cookie is lowercased in the URL.
    let server = TestServer::start(routes_ok(ORG));
    let upper = ORG.to_uppercase();
    server.client().fetch(&cookie_with_org(&upper)).expect("fetch succeeds");
    assert_eq!(server.paths(), vec![usage_path(ORG)]);

    // A lastActiveOrg that is not a UUID does not count: bootstrap runs.
    let server = TestServer::start(routes_ok(ORG));
    server
        .client()
        .fetch("sessionKey=abc; lastActiveOrg=not-a-uuid")
        .expect("fetch succeeds");
    assert_eq!(server.paths(), vec![BOOTSTRAP_PATH.to_string(), usage_path(ORG)]);
}

#[derive(Clone, Copy, Debug)]
enum Target {
    /// Cookie without an org: the status is served by /api/bootstrap.
    Bootstrap,
    /// Cookie with an org: the status is served by the usage endpoint.
    Usage,
    /// Cookie without an org, bootstrap succeeds, usage fails.
    UsageAfterBootstrap,
}

#[test]
fn fetch_maps_http_statuses_without_retrying() {
    // failure list #20: 401/403 -> SignIn.
    // failure list #16: no retry loop; one request per endpoint per fetch.
    let statuses: &[(u16, ClaudeError)] = &[
        (401, ClaudeError::SignIn),
        (403, ClaudeError::SignIn),
        (301, ClaudeError::Protocol),
        (302, ClaudeError::Protocol),
        (303, ClaudeError::Protocol),
        (307, ClaudeError::Protocol),
        (308, ClaudeError::Protocol),
        (204, ClaudeError::Protocol),
        (404, ClaudeError::Protocol),
        (429, ClaudeError::Protocol),
        (500, ClaudeError::Protocol),
        (503, ClaudeError::Protocol),
    ];
    for target in [Target::Bootstrap, Target::Usage, Target::UsageAfterBootstrap] {
        for (status, want) in statuses {
            let failing = |body: &str| {
                Route::new(*status, body.to_string())
                    .header("Location", "/api/elsewhere")
            };
            let mut routes = vec![("/api/elsewhere".to_string(), Route::new(200, USAGE_OK))];
            let (cookie, failing_path) = match target {
                Target::Bootstrap => {
                    routes.push((BOOTSTRAP_PATH.to_string(), failing("")));
                    routes.push((usage_path(ORG), Route::new(200, USAGE_OK)));
                    (cookie_no_org(), BOOTSTRAP_PATH.to_string())
                }
                Target::Usage => {
                    routes.push((usage_path(ORG), failing("")));
                    (cookie_with_org(ORG), usage_path(ORG))
                }
                Target::UsageAfterBootstrap => {
                    routes.push((BOOTSTRAP_PATH.to_string(), Route::new(200, bootstrap_body(ORG))));
                    routes.push((usage_path(ORG), failing("")));
                    (cookie_no_org(), usage_path(ORG))
                }
            };
            let server = TestServer::start(routes);
            let result = server.client().fetch(&cookie);
            assert_eq!(result, Err(*want), "{target:?} with HTTP {status}");
            assert_eq!(server.count(&failing_path), 1, "{target:?} HTTP {status}: exactly one attempt");
            assert_eq!(
                server.count("/api/elsewhere"),
                0,
                "{target:?} HTTP {status}: redirects must not be followed"
            );
            if matches!(target, Target::Bootstrap) {
                assert_eq!(server.count(&usage_path(ORG)), 0, "no usage request after a failed bootstrap");
            }
        }
    }
}

#[test]
fn fetch_maps_invalid_bodies() {
    // (bootstrap body, usage body, cookie has org, expected)
    struct Case {
        why: &'static str,
        bootstrap: String,
        usage: String,
        with_org: bool,
        want: ClaudeError,
    }
    let cases = vec![
        Case { why: "bootstrap is not json", bootstrap: "<html>".into(), usage: USAGE_OK.into(), with_org: false, want: ClaudeError::Protocol },
        Case { why: "bootstrap lacks the org", bootstrap: "{}".into(), usage: USAGE_OK.into(), with_org: false, want: ClaudeError::Protocol },
        Case { why: "bootstrap org is not a uuid", bootstrap: bootstrap_body("org_1"), usage: USAGE_OK.into(), with_org: false, want: ClaudeError::Protocol },
        Case { why: "usage is not json", bootstrap: bootstrap_body(ORG), usage: "<html>".into(), with_org: false, want: ClaudeError::InvalidData },
        // failure list #1 end to end
        Case { why: "usage without five_hour", bootstrap: bootstrap_body(ORG), usage: "{}".into(), with_org: false, want: ClaudeError::InvalidData },
        Case { why: "usage with utilization 150", bootstrap: bootstrap_body(ORG), usage: r#"{"five_hour":{"utilization":150}}"#.into(), with_org: true, want: ClaudeError::InvalidData },
        Case { why: "usage is an array", bootstrap: bootstrap_body(ORG), usage: "[]".into(), with_org: true, want: ClaudeError::InvalidData },
    ];
    for case in cases {
        let server = TestServer::start(vec![
            (BOOTSTRAP_PATH.to_string(), Route::new(200, case.bootstrap.clone())),
            (usage_path(ORG), Route::new(200, case.usage.clone())),
        ]);
        let cookie = if case.with_org { cookie_with_org(ORG) } else { cookie_no_org() };
        assert_eq!(server.client().fetch(&cookie), Err(case.want), "{}", case.why);
    }
}

#[test]
fn fetch_does_not_follow_redirects_even_to_a_good_page() {
    // spec: "follows no redirects"; a 3xx is Protocol.
    let server = TestServer::start(vec![
        (usage_path(ORG), Route::new(302, "").header("Location", "/api/elsewhere")),
        ("/api/elsewhere".to_string(), Route::new(200, USAGE_OK)),
    ]);
    assert_eq!(server.client().fetch(&cookie_with_org(ORG)), Err(ClaudeError::Protocol));
    assert_eq!(server.paths(), vec![usage_path(ORG)]);
}

#[test]
fn fetch_times_out_when_the_server_stalls() {
    // failure list #13: claude.ai hangs -> Timeout (the app maps it to "keep values, mark stale").
    let cases: Vec<(&str, Vec<(String, Route)>, String)> = vec![
        (
            "stall before the usage response",
            vec![(usage_path(ORG), Route::new(200, USAGE_OK).behavior(Behavior::StallBeforeResponse))],
            cookie_with_org(ORG),
        ),
        (
            "stall before the bootstrap response",
            vec![(BOOTSTRAP_PATH.to_string(), Route::new(200, bootstrap_body(ORG)).behavior(Behavior::StallBeforeResponse))],
            cookie_no_org(),
        ),
        (
            "stall in the middle of the usage body",
            vec![(usage_path(ORG), Route::new(200, USAGE_OK).behavior(Behavior::StallMidBody))],
            cookie_with_org(ORG),
        ),
        (
            "stall in the middle of the bootstrap body",
            vec![(BOOTSTRAP_PATH.to_string(), Route::new(200, bootstrap_body(ORG)).behavior(Behavior::StallMidBody))],
            cookie_no_org(),
        ),
    ];
    for (why, routes, cookie) in cases {
        let server = TestServer::start(routes);
        let client = ClaudeClient::new(&server.url(), Duration::from_millis(300));
        let started = Instant::now();
        let result = client.fetch(&cookie);
        let elapsed = started.elapsed();
        assert_eq!(result, Err(ClaudeError::Timeout), "{why}");
        // The fake server stalls for 5 s; the client's own 300 ms budget must fire first.
        assert!(elapsed < Duration::from_secs(4), "{why}: took {elapsed:?}, the client timeout did not apply");
    }
}

#[test]
fn fetch_reports_offline_for_refused_and_reset_connections() {
    // Nothing listens on this port any more.
    let dead_port = {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.local_addr().unwrap().port()
    };
    let dead = ClaudeClient::new(&format!("http://127.0.0.1:{dead_port}"), Duration::from_secs(5));
    assert_eq!(dead.fetch(&cookie_no_org()), Err(ClaudeError::Offline), "refused (bootstrap)");
    assert_eq!(dead.fetch(&cookie_with_org(ORG)), Err(ClaudeError::Offline), "refused (usage)");

    // spec: "reset connections -> Offline": the server accepts, reads the request and RSTs.
    let server = TestServer::start(vec![
        (BOOTSTRAP_PATH.to_string(), Route::new(200, "").behavior(Behavior::Reset)),
        (usage_path(ORG), Route::new(200, "").behavior(Behavior::Reset)),
    ]);
    assert_eq!(server.client().fetch(&cookie_no_org()), Err(ClaudeError::Offline), "reset (bootstrap)");
    assert_eq!(server.client().fetch(&cookie_with_org(ORG)), Err(ClaudeError::Offline), "reset (usage)");
}

#[test]
fn fetch_rejects_bodies_over_one_mebibyte() {
    // failure list #23: response bodies > 1 MiB are rejected as InvalidData.
    struct Case {
        why: &'static str,
        on_bootstrap: bool,
        body_len: usize,
        no_content_length: bool,
        ok: bool,
    }
    let cases = [
        Case { why: "usage exactly 1 MiB is accepted", on_bootstrap: false, body_len: MIB, no_content_length: false, ok: true },
        Case { why: "usage 1 MiB + 1", on_bootstrap: false, body_len: MIB + 1, no_content_length: false, ok: false },
        Case { why: "usage 2 MiB", on_bootstrap: false, body_len: 2 * MIB, no_content_length: false, ok: false },
        Case { why: "usage 2 MiB without Content-Length", on_bootstrap: false, body_len: 2 * MIB, no_content_length: true, ok: false },
        Case { why: "bootstrap 1 MiB + 1", on_bootstrap: true, body_len: MIB + 1, no_content_length: false, ok: false },
        Case { why: "bootstrap 2 MiB without Content-Length", on_bootstrap: true, body_len: 2 * MIB, no_content_length: true, ok: false },
    ];
    let mut failures: Vec<String> = Vec::new();
    for case in cases {
        let behavior = if case.no_content_length { Behavior::NoContentLength } else { Behavior::Respond };
        let (routes, cookie) = if case.on_bootstrap {
            (
                vec![
                    (BOOTSTRAP_PATH.to_string(), Route::new(200, pad_to(&bootstrap_body(ORG), case.body_len)).behavior(behavior)),
                    (usage_path(ORG), Route::new(200, USAGE_OK)),
                ],
                cookie_no_org(),
            )
        } else {
            (
                vec![(usage_path(ORG), Route::new(200, pad_to(USAGE_OK, case.body_len)).behavior(behavior))],
                cookie_with_org(ORG),
            )
        };
        let server = TestServer::start(routes);
        let result = server.client().fetch(&cookie);
        if case.ok {
            if result.is_err() {
                failures.push(format!("{}: expected Ok, got {result:?}", case.why));
            }
        } else if result != Err(ClaudeError::InvalidData) {
            failures.push(format!("{}: expected Err(InvalidData), got {result:?}", case.why));
        }
    }
    assert!(failures.is_empty(), "{} case(s) failed:\n{}", failures.len(), failures.join("\n"));
}
