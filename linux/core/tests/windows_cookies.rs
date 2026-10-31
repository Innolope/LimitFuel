//! Acceptance tests written from SPEC.md only; production bodies were not inspected.
//!
//! Plan / What can go wrong: W1-W3 reject unsupported encryption, corrupt input
//! and missing keys; W7 bounds locked-database failure without copying secrets;
//! W14 exercises DPAPI failure. Lazy keys, profiles and auxiliary failures are
//! tested with disposable SQLite/GCM fixtures, never a real browser or keyring.
//! Idempotency: one key request per discovery; auth: only claude.ai rows qualify;
//! partial failure: bad auxiliary rows are dropped, session failures propagate.
//! No retry/load traffic is appropriate for local parsers; WAL and exclusive locks
//! exercise storage concurrency. Migration: the Linux CBC entry point stays Linux.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use base64::{engine::general_purpose::STANDARD, Engine};
use limitfuel_core::cookies::{
    decrypt_value_windows, discover, discover_with, local_state_key, windows_browsers,
    ChromeSession, CookieError, CookieScheme, KeyProvider,
};
use limitfuel_core::diagnostics::{DiagnosticCode, DiagnosticProvider, ReportPolicy};
use rusqlite::{params, Connection};
use serde_json::json;
use sha2::{Digest, Sha256};

const NOW: f64 = 1_800_000_000.0;
const KEY: [u8; 32] = [0x41; 32];
const HOST: &str = ".claude.ai";
const SK: &str = "sk-ant-disposable-test";

fn encrypt_plain(plain: &[u8]) -> Vec<u8> {
    // Fixed nonce is safe for these disposable fixtures only; no production data.
    let nonce = [0x23; 12];
    let cipher = Aes256Gcm::new_from_slice(&KEY).unwrap();
    let mut blob = b"v10".to_vec();
    blob.extend_from_slice(&nonce);
    blob.extend(cipher.encrypt(&Nonce::from(nonce), plain).unwrap());
    blob
}

fn encrypted(value: &[u8], host: &str, version: i64) -> Vec<u8> {
    let mut plain = Vec::new();
    if version >= 24 { plain.extend_from_slice(&Sha256::digest(host.as_bytes())); }
    plain.extend_from_slice(value);
    encrypt_plain(&plain)
}

fn err<T>(result: Result<T, CookieError>) -> CookieError {
    match result { Ok(_) => panic!("expected cookie error"), Err(e) => e }
}

#[test]
fn gcm_decrypts_versions_23_24_and_future_host_hash_versions() {
    for version in [23, 24, 25] {
        for (host, value) in [(HOST, SK), ("claude.ai", "héllo 🦀"), (HOST, "")] {
            let mut calls = 0;
            let result = decrypt_value_windows(&encrypted(value.as_bytes(), host, version), host, version, &mut || {
                calls += 1;
                Ok(KEY.to_vec())
            });
            assert_eq!(result, Ok(value.into()), "version {version}, host {host}");
            assert_eq!(calls, 1);
        }
    }
    // Pin both exact size boundaries independently of discovery's header rules.
    let largest = vec![b'a'; 32768 - 31];
    let blob = encrypt_plain(&largest);
    assert_eq!(blob.len(), 32768);
    assert_eq!(decrypt_value_windows(&blob, HOST, 23, &mut || Ok(KEY.to_vec())), Ok(String::from_utf8(largest).unwrap()));
}

#[test]
fn app_bound_never_requests_a_key_even_for_a_prefix_only_value() {
    for blob in [b"v20".to_vec(), [b"v20".as_slice(), &[1; 100]].concat()] {
        assert_eq!(decrypt_value_windows(&blob, HOST, 24, &mut || panic!("v20 must not request a key")), Err(CookieError::AppBound));
    }
}

#[test]
fn gcm_rejects_bad_lengths_tags_keys_hashes_utf8_and_prefixes() {
    let mut bad_tag = encrypted(SK.as_bytes(), HOST, 24);
    *bad_tag.last_mut().unwrap() ^= 1;
    let mut cases = vec![
        ("bad tag", bad_tag, 24),
        ("missing hash", encrypted(b"short", HOST, 23), 24),
        ("missing hash but long plaintext", encrypted(&[b'x'; 64], HOST, 23), 24),
        ("other host hash", encrypted(b"value", "other.example", 24), 24),
        ("non UTF-8", encrypted(&[0xff, 0xfe], HOST, 23), 23),
        ("non UTF-8 after hash", encrypted(&[0xff, 0xfe], HOST, 24), 24),
        ("Linux v11", b"v11some-encrypted-value".to_vec(), 23),
        ("raw DPAPI", vec![1, 0, 0, 0, 0xd0, 0x8c, 0x9d, 0xdf], 23),
        ("oversized v10", [b"v10".as_slice(), &vec![0; 32766]].concat(), 23),
        // Literal rule: the size limit applies to the WHOLE value, before prefixes.
        ("oversized v20", [b"v20".as_slice(), &vec![0; 32766]].concat(), 23),
    ];
    for length in 0..31 {
        let mut blob = vec![0; length];
        if length >= 3 { blob[..3].copy_from_slice(b"v10"); }
        cases.push(("under 31 bytes", blob, 23));
    }
    for (why, blob, version) in cases {
        assert_eq!(decrypt_value_windows(&blob, HOST, version, &mut || Ok(KEY.to_vec())), Err(CookieError::Encryption), "{why}, size {}", blob.len());
    }
    let good = encrypted(SK.as_bytes(), HOST, 24);
    for size in [0, 16, 31, 33] {
        assert_eq!(decrypt_value_windows(&good, HOST, 24, &mut || Ok(vec![0x41; size])), Err(CookieError::Encryption), "key size {size}");
    }
    assert_eq!(decrypt_value_windows(&good, HOST, 24, &mut || Ok(vec![0x42; 32])), Err(CookieError::Encryption), "wrong 32-byte key");
}

#[test]
fn gcm_key_errors_pass_through_unchanged() {
    let blob = encrypted(SK.as_bytes(), HOST, 24);
    for error in [CookieError::Keyring, CookieError::Unavailable] {
        assert_eq!(decrypt_value_windows(&blob, HOST, 24, &mut || Err(error)), Err(error));
    }
}

fn state(blob_with_prefix: &[u8]) -> Vec<u8> {
    serde_json::to_vec(&json!({"os_crypt": {"encrypted_key": STANDARD.encode(blob_with_prefix)}})).unwrap()
}

#[test]
fn local_state_extracts_only_nonempty_dpapi_blobs_with_standard_base64() {
    for blob in [vec![0], vec![0xfb, 0xff, 0xfe, 0x00], (0..=255).collect()] {
        assert_eq!(local_state_key(&state(&[b"DPAPI".as_slice(), &blob].concat())), Ok(blob));
    }
    let mut boundary = state(b"DPAPIx");
    boundary.resize(4 * 1024 * 1024, b' ');
    assert_eq!(local_state_key(&boundary), Ok(b"x".to_vec()), "exactly 4 MiB is allowed");
}

#[test]
fn local_state_rejects_missing_malformed_unpadded_and_oversized_input() {
    let padded = STANDARD.encode(b"DPAPIxx");
    assert!(padded.ends_with('='));
    for (why, input) in [
        ("missing file contents", vec![]),
        ("non JSON", b"not-json".to_vec()),
        ("missing os_crypt", b"{}".to_vec()),
        ("missing encrypted_key", br#"{"os_crypt":{}}"#.to_vec()),
        ("non string", br#"{"os_crypt":{"encrypted_key":42}}"#.to_vec()),
        ("invalid base64", br#"{"os_crypt":{"encrypted_key":"%%%="}}"#.to_vec()),
        ("unpadded base64", serde_json::to_vec(&json!({"os_crypt":{"encrypted_key":padded.trim_end_matches('=')}})).unwrap()),
        ("no prefix", state(b"not-DPAPI-blob")),
        ("wrong case prefix", state(b"dpapix")),
        ("prefix only", state(b"DPAPI")),
        ("over 4 MiB", vec![b' '; 4 * 1024 * 1024 + 1]),
    ] {
        assert_eq!(local_state_key(&input), Err(CookieError::Keyring), "{why}");
    }
}

#[test]
fn browser_names_roots_order_and_keyring_applications_match_windows_spec() {
    let tmp = tempfile::tempdir().unwrap();
    let actual = windows_browsers(tmp.path());
    let expected = [
        ("Google Chrome", vec!["Google", "Chrome", "User Data"], "chrome"),
        ("Microsoft Edge", vec!["Microsoft", "Edge", "User Data"], "edge"),
        ("Brave", vec!["BraveSoftware", "Brave-Browser", "User Data"], "brave"),
        ("Chromium", vec!["Chromium", "User Data"], "chromium"),
    ];
    assert_eq!(actual.len(), expected.len());
    for (browser, (name, parts, application)) in actual.iter().zip(expected) {
        let root = parts.iter().fold(tmp.path().to_path_buf(), |p, part| p.join(part));
        assert_eq!(browser.name, name);
        assert_eq!(browser.root, root);
        assert_eq!(browser.keyring_application, application);
    }
}

struct FakeKeys { fail: bool, calls: Mutex<Vec<bool>> }

impl FakeKeys {
    fn new(fail: bool) -> Self { Self { fail, calls: Mutex::new(Vec::new()) } }
    fn calls(&self) -> Vec<bool> { self.calls.lock().unwrap().clone() }
}

impl KeyProvider for FakeKeys {
    fn password(&self, allow_interaction: bool) -> Result<Vec<u8>, CookieError> {
        self.calls.lock().unwrap().push(allow_interaction);
        if self.fail { Err(CookieError::Keyring) } else { Ok(KEY.to_vec()) }
    }
}

fn database(root: &Path, profile: &str, version: i64, rows: &[(&str, Vec<u8>)]) -> PathBuf {
    let path = root.join(profile).join("Network").join("Cookies");
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let db = Connection::open(&path).unwrap();
    db.execute_batch("CREATE TABLE meta(key TEXT, value TEXT);
        CREATE TABLE cookies(host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB,
        path TEXT, expires_utc INTEGER, top_frame_site_key TEXT);").unwrap();
    db.execute("INSERT INTO meta VALUES('version', ?1)", [version.to_string()]).unwrap();
    for (name, value) in rows {
        db.execute("INSERT INTO cookies VALUES(?1, ?2, '', ?3, '/', 0, '')", params![HOST, name, value]).unwrap();
    }
    path
}

fn run(root: &Path, profile: Option<&str>, interactive: bool, keys: &dyn KeyProvider) -> Result<Vec<ChromeSession>, CookieError> {
    discover_with(CookieScheme::Windows, root, profile, interactive, NOW, keys)
}

#[test]
fn discovery_gcm_success_names_profiles_and_requests_key_once() {
    for interactive in [false, true] {
        let tmp = tempfile::tempdir().unwrap();
        for (id, version) in [("Default", 23), ("Profile 1", 24), ("Profile 2", 25)] {
            database(tmp.path(), id, version, &[("sessionKey", encrypted(SK.as_bytes(), HOST, version)), ("aaa", encrypted(b"aux", HOST, version))]);
        }
        fs::write(tmp.path().join("Local State"), br#"{"profile":{"info_cache":{"Default":{"name":"Personal"}}}}"#).unwrap();
        let keys = FakeKeys::new(false);
        let sessions = run(tmp.path(), None, interactive, &keys).expect("GCM discovery succeeds");
        assert_eq!(sessions.iter().map(|s| s.profile.id.as_str()).collect::<Vec<_>>(), ["Default", "Profile 1", "Profile 2"]);
        assert_eq!(sessions[0].profile.name, "Personal");
        for s in sessions { assert_eq!(s.cookie_header, format!("aaa=aux; sessionKey={SK}")); }
        assert_eq!(keys.calls(), vec![interactive], "key cached across all profiles");
    }
}

#[test]
fn discovery_app_bound_session_fails_without_key_but_auxiliary_is_dropped() {
    for auxiliary in [false, true] {
        let tmp = tempfile::tempdir().unwrap();
        let keys = FakeKeys::new(false);
        let rows = if auxiliary {
            vec![("sessionKey", encrypted(SK.as_bytes(), HOST, 24)), ("aaa", b"v20app-bound".to_vec())]
        } else { vec![("sessionKey", b"v20app-bound".to_vec())] };
        database(tmp.path(), "Default", 24, &rows);
        let result = run(tmp.path(), Some("Default"), false, &keys);
        if auxiliary {
            let sessions = result.expect("auxiliary AppBound is dropped");
            assert_eq!(sessions.len(), 1);
            assert_eq!(sessions[0].cookie_header, format!("sessionKey={SK}"));
            assert_eq!(keys.calls(), vec![false]);
        } else {
            assert_eq!(err(result), CookieError::AppBound);
            assert!(keys.calls().is_empty());
        }
    }
}

#[test]
fn discovery_propagates_key_error_and_ignores_profiles_without_a_session() {
    let tmp = tempfile::tempdir().unwrap();
    database(tmp.path(), "Default", 24, &[("aaa", encrypted(b"aux", HOST, 24))]);
    let keys = FakeKeys::new(true);
    assert!(run(tmp.path(), None, false, &keys).unwrap().is_empty());
    assert!(keys.calls().is_empty());
    database(tmp.path(), "Profile 1", 24, &[("sessionKey", encrypted(SK.as_bytes(), HOST, 24))]);
    assert_eq!(err(run(tmp.path(), Some("Profile 1"), false, &keys)), CookieError::Keyring);
    assert_eq!(keys.calls(), vec![false]);
}

#[test]
fn discovery_bad_session_fails_but_bad_auxiliary_is_dropped() {
    let mut bad_tag = encrypted(b"bad", HOST, 24);
    *bad_tag.last_mut().unwrap() ^= 1;
    for (why, blob, expected) in [
        ("bad GCM tag", bad_tag, CookieError::Encryption),
        ("short ciphertext", b"v10short".to_vec(), CookieError::Encryption),
        ("wrong host", encrypted(b"bad", "other.example", 24), CookieError::Encryption),
        ("oversized encrypted cookie", vec![0; 32769], CookieError::InvalidCookie),
        ("invalid header value", encrypted(b"has space", HOST, 24), CookieError::InvalidCookie),
    ] {
        for auxiliary in [false, true] {
            let tmp = tempfile::tempdir().unwrap();
            let rows = if auxiliary {
                vec![("sessionKey", encrypted(SK.as_bytes(), HOST, 24)), ("aaa", blob.clone())]
            } else { vec![("sessionKey", blob.clone())] };
            database(tmp.path(), "Default", 24, &rows);
            let keys = FakeKeys::new(false);
            let result = run(tmp.path(), Some("Default"), false, &keys);
            if auxiliary {
                let sessions = result.expect("a failing auxiliary cookie is dropped");
                assert_eq!(sessions.len(), 1, "{why}");
                assert_eq!(sessions[0].cookie_header, format!("sessionKey={SK}"), "{why}");
            } else {
                assert_eq!(err(result), expected, "{why}");
            }
        }
    }
}

#[test]
fn linux_discovery_does_not_accept_a_windows_gcm_database() {
    let tmp = tempfile::tempdir().unwrap();
    database(tmp.path(), "Default", 24, &[("sessionKey", encrypted(SK.as_bytes(), HOST, 24))]);
    let keys = FakeKeys::new(false);
    let result = discover(tmp.path(), Some("Default"), false, NOW, &keys);
    match result { Err(_) => {}, Ok(sessions) => assert!(sessions.is_empty(), "Linux must not decrypt GCM") }
    assert!(keys.calls().is_empty(), "Linux v10 never requests a password");
}

#[test]
fn discovery_exclusive_lock_is_bounded_database_error_without_secret_copy() {
    let tmp = tempfile::tempdir().unwrap();
    let path = database(tmp.path(), "Default", 24, &[("sessionKey", encrypted(SK.as_bytes(), HOST, 24))]);
    let original = fs::read(&path).unwrap();
    let lock = Connection::open(&path).unwrap();
    lock.execute_batch("PRAGMA journal_mode=DELETE; BEGIN EXCLUSIVE;").unwrap();
    let keys = FakeKeys::new(false);
    let start = Instant::now();
    let result = run(tmp.path(), Some("Default"), false, &keys);
    assert_eq!(err(result), CookieError::Database);
    // The spec says bounded, without a numeric SQLite budget; allow 5 s + margin.
    assert!(start.elapsed() < Duration::from_secs(8));
    assert!(keys.calls().is_empty());
    lock.execute_batch("ROLLBACK;").unwrap();
    assert_eq!(fs::read(&path).unwrap(), original, "read-only discovery must not alter the DB");
    let names: Vec<_> = fs::read_dir(path.parent().unwrap()).unwrap().map(|e| e.unwrap().file_name()).collect();
    assert_eq!(names, vec![std::ffi::OsString::from("Cookies")], "no secret DB copy left behind");
}

#[test]
fn discovery_reads_committed_wal_while_a_writer_has_pending_rows() {
    let tmp = tempfile::tempdir().unwrap();
    let path = database(tmp.path(), "Default", 24, &[("sessionKey", encrypted(SK.as_bytes(), HOST, 24))]);
    let writer = Connection::open(&path).unwrap();
    writer.execute_batch("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;").unwrap();
    writer.execute("INSERT INTO cookies VALUES(?1, 'aaa', '', ?2, '/', 0, '')", params![HOST, encrypted(b"committed", HOST, 24)]).unwrap();
    writer.execute_batch("BEGIN IMMEDIATE;").unwrap();
    writer.execute("UPDATE cookies SET encrypted_value=?1 WHERE name='aaa'", [encrypted(b"pending", HOST, 24)]).unwrap();
    let keys = FakeKeys::new(false);
    let sessions = run(tmp.path(), Some("Default"), false, &keys).unwrap();
    assert_eq!(sessions[0].cookie_header, format!("aaa=committed; sessionKey={SK}"));
    writer.execute_batch("ROLLBACK;").unwrap();
}

#[test]
fn app_bound_guidance_says_to_paste_a_cookie() {
    let message = CookieError::AppBound.message();
    assert!(!message.is_empty());
    assert!(message.to_lowercase().contains("paste"));
}

#[test]
fn app_bound_diagnostics_never_report_an_expected_auth_limitation() {
    let code: Option<DiagnosticCode> = CookieError::AppBound.into();
    assert_eq!(code, Some(DiagnosticCode::Unavailable));
    let mut policy = ReportPolicy::new();
    for online in [false, true] {
        for i in 0..100 {
            assert!(!policy.record_failure(DiagnosticProvider::Claude, code.unwrap(), f64::from(i) * 3600.0, online));
        }
        policy.record_recovery(DiagnosticProvider::Claude);
    }
}

#[cfg(windows)]
mod windows {
    use super::*;
    use limitfuel_core::cookies::{dpapi_protect, dpapi_unprotect};

    #[test]
    fn dpapi_round_trip_and_failure_are_current_user_noninteractive() {
        for data in [b"disposable DPAPI fixture".to_vec(), KEY.to_vec(), (0..=255).collect()] {
            let protected = dpapi_protect(&data).unwrap();
            assert!(!protected.is_empty());
            assert_ne!(protected, data);
            assert_eq!(dpapi_unprotect(&protected), Ok(data));
        }
        for blob in [vec![], b"not-a-DPAPI-blob".to_vec(), vec![1, 0, 0, 0, 0xd0, 0x8c, 0x9d, 0xdf]] {
            assert_eq!(dpapi_unprotect(&blob), Err(CookieError::Keyring));
        }
        let code: Option<DiagnosticCode> = CookieError::Keyring.into();
        assert_eq!(code, Some(DiagnosticCode::SignIn));
        let mut policy = ReportPolicy::new();
        for i in 0..100 {
            assert!(!policy.record_failure(DiagnosticProvider::Claude, code.unwrap(), f64::from(i) * 3600.0, true));
        }
    }

    #[test]
    fn discovery_uses_a_real_dpapi_local_state_key() {
        struct DpapiKeys { state: PathBuf, calls: Mutex<Vec<bool>> }
        impl KeyProvider for DpapiKeys {
            fn password(&self, interactive: bool) -> Result<Vec<u8>, CookieError> {
                self.calls.lock().unwrap().push(interactive);
                let bytes = fs::read(&self.state).map_err(|_| CookieError::Keyring)?;
                dpapi_unprotect(&local_state_key(&bytes)?)
            }
        }
        let tmp = tempfile::tempdir().unwrap();
        let protected = dpapi_protect(&KEY).unwrap();
        let state_path = tmp.path().join("Local State");
        fs::write(&state_path, state(&[b"DPAPI".as_slice(), &protected].concat())).unwrap();
        database(tmp.path(), "Default", 24, &[("sessionKey", encrypted(SK.as_bytes(), HOST, 24))]);
        let keys = DpapiKeys { state: state_path, calls: Mutex::new(Vec::new()) };
        let sessions = run(tmp.path(), Some("Default"), false, &keys).unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].cookie_header, format!("sessionKey={SK}"));
        assert_eq!(*keys.calls.lock().unwrap(), vec![false]);
    }

    #[test]
    fn locked_database_errors_tell_windows_users_to_close_the_browser_or_paste() {
        let message = CookieError::Database.message().to_lowercase();
        assert!(message.contains("close") && message.contains("browser") && message.contains("paste"));
    }
}
