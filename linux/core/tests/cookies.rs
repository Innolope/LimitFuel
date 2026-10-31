// Table-driven cases are tuples on purpose.
// Fake executables, symlinks and permission bits are Unix-only; Windows has its own tests.
#![cfg(unix)]
#![allow(clippy::type_complexity)]

//! Acceptance tests for `limitfuel_core::cookies`, written from SPEC.md only.
//!
//! Chrome cookie databases are built with rusqlite inside temp dirs, values are
//! encrypted exactly as the spec says Chrome does (v10/v11, AES-128-CBC, fixed IV,
//! optional SHA-256(host) prefix for db_version >= 24), and the keyring is a fake
//! `KeyProvider` that records every call.

use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant};

use aes::Aes128;
use cbc::cipher::block_padding::{NoPadding, Pkcs7};
use cbc::cipher::{BlockModeEncrypt, KeyIvInit};
use limitfuel_core::cookies::{
    browsers, decrypt_value, derive_key, discover, validate_header, ChromeSession, CookieError,
    KeyProvider,
};
use pbkdf2::pbkdf2_hmac;
use rusqlite::{params, Connection};
use serde_json::json;
use sha1::Sha1;
use sha2::{Digest, Sha256};

const NOW: f64 = 1_800_000_000.0;
const KEYRING_PW: &[u8] = b"test-keyring-password";
const SK: &str = "sk-ant-sid01-AbC_123-xyz";

fn chrome_us(unix_seconds: i64) -> i64 {
    (unix_seconds + 11_644_473_600) * 1_000_000
}

const NOW_CHROME: i64 = (1_800_000_000 + 11_644_473_600) * 1_000_000;

fn future_chrome() -> i64 {
    chrome_us(1_800_000_000 + 30 * 86_400)
}

// ---------------------------------------------------------------------------
// Encryption helpers (the test-side model of what Chrome does)
// ---------------------------------------------------------------------------

fn key_for(password: &[u8]) -> [u8; 16] {
    let mut key = [0u8; 16];
    pbkdf2_hmac::<Sha1>(password, b"saltysalt", 1, &mut key);
    key
}

fn cbc_pkcs7(key: [u8; 16], plain: &[u8]) -> Vec<u8> {
    cbc::Encryptor::<Aes128>::new_from_slices(&key, &[0x20u8; 16])
        .expect("key and iv sizes")
        .encrypt_padded_vec::<Pkcs7>(plain)
}

fn cbc_raw(key: [u8; 16], plain: &[u8]) -> Vec<u8> {
    assert_eq!(plain.len() % 16, 0);
    cbc::Encryptor::<Aes128>::new_from_slices(&key, &[0x20u8; 16])
        .expect("key and iv sizes")
        .encrypt_padded_vec::<NoPadding>(plain)
}

fn host_hash(host: &str) -> Vec<u8> {
    let d = Sha256::digest(host.as_bytes());
    let b: &[u8] = d.as_ref();
    b.to_vec()
}

fn with_hash(host: &str, value: &[u8], db_version: i64) -> Vec<u8> {
    if db_version >= 24 {
        let mut v = host_hash(host);
        v.extend_from_slice(value);
        v
    } else {
        value.to_vec()
    }
}

fn prefixed(prefix: &[u8], body: Vec<u8>) -> Vec<u8> {
    let mut v = prefix.to_vec();
    v.extend(body);
    v
}

fn enc_v10(value: &str, host: &str, db_version: i64) -> Vec<u8> {
    prefixed(b"v10", cbc_pkcs7(key_for(b"peanuts"), &with_hash(host, value.as_bytes(), db_version)))
}

fn enc_v11(value: &str, host: &str, db_version: i64) -> Vec<u8> {
    prefixed(b"v11", cbc_pkcs7(key_for(KEYRING_PW), &with_hash(host, value.as_bytes(), db_version)))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Local stand-in for the cookie error variants, so results can be built and compared freely.
#[derive(Clone, Copy, Debug)]
enum E {
    Unavailable,
    Database,
    Keyring,
    Encryption,
    InvalidCookie,
    Profile,
}

fn ce(e: E) -> CookieError {
    match e {
        E::Unavailable => CookieError::Unavailable,
        E::Database => CookieError::Database,
        E::Keyring => CookieError::Keyring,
        E::Encryption => CookieError::Encryption,
        E::InvalidCookie => CookieError::InvalidCookie,
        E::Profile => CookieError::Profile,
    }
}

// `ChromeSession` has no documented Debug, so errors are extracted without printing the Ok side.
fn cerr<T>(r: Result<T, CookieError>, why: &str) -> CookieError {
    match r {
        Ok(_) => panic!("{why}: expected an error, got Ok"),
        Err(e) => e,
    }
}

/// Compares an error result with the wanted variant without panicking, so that
/// table-driven tests can report every failing case at once.
fn expect_error(why: &str, r: Result<Vec<ChromeSession>, CookieError>, want: CookieError) -> Option<String> {
    match r {
        Ok(sessions) => {
            let headers: Vec<String> = sessions.iter().map(|s| s.cookie_header.chars().take(60).collect()).collect();
            Some(format!("{why}: expected Err({want:?}), got Ok({headers:?})"))
        }
        Err(e) if e == want => None,
        Err(e) => Some(format!("{why}: expected Err({want:?}), got Err({e:?})")),
    }
}

fn report(failures: Vec<Option<String>>) {
    let failures: Vec<String> = failures.into_iter().flatten().collect();
    assert!(failures.is_empty(), "{} case(s) failed:\n{}", failures.len(), failures.join("\n"));
}

// ---------------------------------------------------------------------------
// derive_key / decrypt_value
// ---------------------------------------------------------------------------

#[test]
fn derive_key_is_pbkdf2_hmac_sha1_saltysalt_one_iteration() {
    // Reference values computed independently with Python's hashlib.pbkdf2_hmac.
    assert_eq!(hex(&derive_key(b"peanuts")), "fd621fe5a2b402539dfa147ca9272778");
    assert_eq!(hex(&derive_key(b"")), "d0d0ec9c7d77d43ac54187fa4818d17f");
    assert_eq!(hex(&derive_key(KEYRING_PW)), "665eaef957722dd21f172689c9e1ee21");
    assert_eq!(derive_key(KEYRING_PW), key_for(KEYRING_PW));
    assert_ne!(derive_key(b"peanuts"), derive_key(b"peanut"));
}

type PasswordReply = Result<Vec<u8>, E>;

/// Runs `decrypt_value` and reports how often the v11 password was requested.
fn decrypt(encrypted: &[u8], host: &str, version: i64, reply: PasswordReply) -> (Result<String, CookieError>, usize) {
    let mut calls = 0usize;
    let result = {
        let mut provider = || {
            calls += 1;
            match &reply {
                Ok(p) => Ok(p.clone()),
                Err(e) => Err(ce(*e)),
            }
        };
        decrypt_value(encrypted, host, version, &mut provider)
    };
    (result, calls)
}

fn pw_ok() -> PasswordReply {
    Ok(KEYRING_PW.to_vec())
}

#[test]
fn decrypt_value_decrypts_v10_and_v11_and_strips_the_host_hash() {
    const H: &str = ".claude.ai";
    let table: Vec<(&str, Vec<u8>, &str, i64, &str, usize)> = vec![
        ("v10, db 23", enc_v10("sk-ant-abc", H, 23), H, 23, "sk-ant-abc", 0),
        ("v10, db 1", enc_v10("old", H, 1), H, 1, "old", 0),
        ("v10, db 24 strips the host hash", enc_v10("sk-ant-abc", H, 24), H, 24, "sk-ant-abc", 0),
        ("v10, db 25 strips the host hash", enc_v10("sk-ant-abc", H, 25), H, 25, "sk-ant-abc", 0),
        ("v10, db 100 strips the host hash", enc_v10("x", H, 100), H, 100, "x", 0),
        ("v10, non-ascii utf-8", enc_v10("héllo wörld ✓", H, 23), H, 23, "héllo wörld ✓", 0),
        ("v11, db 23", enc_v11("sk-ant-abc", H, 23), H, 23, "sk-ant-abc", 1),
        ("v11, db 24 strips the host hash", enc_v11("sk-ant-abc", H, 24), H, 24, "sk-ant-abc", 1),
        ("v10 with the bare host hash", enc_v10("v", "claude.ai", 24), "claude.ai", 24, "v", 0),
    ];
    for (why, blob, host, version, want, want_calls) in &table {
        let (result, calls) = decrypt(blob, host, *version, pw_ok());
        assert_eq!(result, Ok(want.to_string()), "{why}");
        assert_eq!(calls, *want_calls, "{why}: password requests (v11 only, lazily)");
    }
}

#[test]
fn decrypt_value_rejects_malformed_values_as_encryption_errors() {
    const H: &str = ".claude.ai";
    let k10 = key_for(b"peanuts");
    let good16 = vec![7u8; 16];

    let mut cases: Vec<(&str, Vec<u8>, i64)> = vec![
        ("empty value", vec![], 23),
        ("one byte", b"v".to_vec(), 23),
        ("prefix only: v1", b"v1".to_vec(), 23),
        ("v10 with no ciphertext", b"v10".to_vec(), 23),
        ("unknown prefix v12", prefixed(b"v12", good16.clone()), 23),
        ("unknown prefix v09", prefixed(b"v09", good16.clone()), 23),
        ("upper-case prefix V10", prefixed(b"V10", good16.clone()), 23),
        ("no prefix at all", good16.clone(), 23),
        ("plaintext looking value", b"just-a-plain-cookie-value".to_vec(), 23),
        ("ciphertext of 15 bytes", prefixed(b"v10", vec![1u8; 15]), 23),
        ("ciphertext of 17 bytes", prefixed(b"v10", vec![1u8; 17]), 23),
        ("ciphertext of 31 bytes", prefixed(b"v10", vec![1u8; 31]), 23),
        // padding errors, built with NoPadding so they are deterministic
        ("pad byte above block size", prefixed(b"v10", cbc_raw(k10, b"abcdefghijklmnop")), 23),
        ("pad byte 0", prefixed(b"v10", cbc_raw(k10, b"abcdefghijklmno\x00")), 23),
        ("pad byte 17", prefixed(b"v10", cbc_raw(k10, b"abcdefghijklmno\x11")), 23),
        ("inconsistent padding bytes", prefixed(b"v10", cbc_raw(k10, b"0123456789ab\x01\x02\x03\x04")), 23),
        // encrypted under the wrong key
        ("v10 encrypted with the keyring key", prefixed(b"v10", cbc_pkcs7(key_for(KEYRING_PW), b"hello world value")), 23),
        // utf-8
        ("not utf-8", prefixed(b"v10", cbc_pkcs7(k10, &[0xff, 0xfe, 0x41])), 23),
        ("not utf-8 after the hash", prefixed(b"v10", cbc_pkcs7(k10, &with_hash(H, &[0xff, 0xfe], 24))), 24),
        // host hash handling for db_version >= 24
        ("db 24 value without the hash", enc_v10("value-without-hash", H, 23), 24),
        ("db 24 plaintext shorter than the hash", prefixed(b"v10", cbc_pkcs7(k10, b"abc")), 24),
        ("db 24 hash of another host", enc_v10("value", ".other.example", 24), 24),
        (
            "db 24 truncated hash",
            prefixed(b"v10", cbc_pkcs7(k10, &host_hash(H)[..31])),
            24,
        ),
        ("db 23 value that still carries a hash", enc_v10("value", H, 24), 23),
        // size
        ("ciphertext over 32 KiB", prefixed(b"v10", vec![0u8; 1 << 20]), 23),
    ];
    // failure list #23: cookie values > 32 KiB are rejected (3 prefix bytes + 32768 ciphertext bytes)
    cases.push(("plaintext of 32752 bytes (value of 32771 bytes)", enc_v10(&"a".repeat(32752), H, 23), 23));
    cases.push(("db 24 plaintext that pushes the value over 32 KiB", enc_v10(&"a".repeat(32720), H, 24), 24));

    for (why, blob, version) in &cases {
        let (result, calls) = decrypt(blob, H, *version, pw_ok());
        assert_eq!(result, Err(CookieError::Encryption), "{why}");
        if !blob.starts_with(b"v11") {
            assert_eq!(calls, 0, "{why}: only v11 values may request the keyring password");
        }
    }

    // The host used for the hash is the one passed in.
    let blob = enc_v10("value", ".claude.ai", 24);
    assert_eq!(decrypt(&blob, ".claude.ai", 24, pw_ok()).0, Ok("value".to_string()));
    assert_eq!(decrypt(&blob, "claude.ai", 24, pw_ok()).0, Err(CookieError::Encryption));
}

#[test]
fn decrypt_value_accepts_values_up_to_32_kib() {
    // failure list #23 (boundary): 3 + 32752 = 32755 bytes is the largest value that fits.
    let plain = "a".repeat(32751);
    let blob = enc_v10(&plain, ".claude.ai", 23);
    assert_eq!(blob.len(), 32755);
    assert_eq!(decrypt(&blob, ".claude.ai", 23, pw_ok()).0, Ok(plain));
}

#[test]
fn decrypt_value_v11_uses_the_keyring_password_lazily_and_passes_failures_through() {
    // failure list #21: keyring locked or denied -> error passes through unchanged
    let blob = enc_v11("secret", ".claude.ai", 24);
    for e in [E::Keyring, E::Unavailable, E::Database, E::Encryption, E::InvalidCookie, E::Profile] {
        let (result, calls) = decrypt(&blob, ".claude.ai", 24, Err(e));
        assert_eq!(result, Err(ce(e)), "keyring error {e:?} must be returned unchanged");
        assert_eq!(calls, 1, "{e:?}: the password is requested exactly once");
    }

    // A wrong password decrypts to garbage: Encryption.
    let (result, calls) = decrypt(&blob, ".claude.ai", 24, Ok(b"wrong-password".to_vec()));
    assert_eq!(result, Err(CookieError::Encryption));
    assert_eq!(calls, 1);

    // v10 never asks, even with a provider that would fail.
    let v10 = enc_v10("plain", ".claude.ai", 24);
    let (result, calls) = decrypt(&v10, ".claude.ai", 24, Err(E::Keyring));
    assert_eq!(result, Ok("plain".to_string()));
    assert_eq!(calls, 0);
}

// ---------------------------------------------------------------------------
// validate_header
// ---------------------------------------------------------------------------

#[test]
fn validate_header_accepts_well_formed_headers() {
    let long_value = format!("sessionKey={}", "x".repeat(16384 - "sessionKey=".len()));
    assert_eq!(long_value.len(), 16384);
    let mut many: Vec<String> = (0..127).map(|i| format!("k{i}=v{i}")).collect();
    many.push("sessionKey=abc".to_string());
    let many = many.join("; ");

    let table: Vec<(&str, String)> = vec![
        ("just a session key", "sessionKey=abc".into()),
        ("typical value", "sessionKey=sk-ant-sid01-AbC_123~.-xyz".into()),
        ("base64 padding in the value", "sessionKey=abc==".into()),
        ("two pairs", "a=1; sessionKey=x".into()),
        ("pairs are trimmed", "a=1;sessionKey=x".into()),
        ("extra whitespace around pairs", "a=1;   sessionKey=x  ".into()),
        ("token punctuation in names", "a.b-c_d!#$%&'*+^`|~=1; sessionKey=x".into()),
        ("value with equals signs", "a=b=c; sessionKey=x".into()),
        ("empty value for another cookie", "a=; sessionKey=x".into()),
        ("exactly 16384 bytes", long_value),
        ("exactly 128 pairs", many),
    ];
    for (why, header) in &table {
        assert!(validate_header(header), "{why}: {:?} should be valid", &header[..header.len().min(60)]);
    }
}

#[test]
fn validate_header_rejects_injection_and_malformed_headers() {
    // failure list #4: pasted cookie with ';' injection, spaces, quotes, duplicate
    // names or no sessionKey -> rejected before any request.
    let too_long = format!("sessionKey={}", "x".repeat(16385 - "sessionKey=".len()));
    assert_eq!(too_long.len(), 16385);
    let mut too_many: Vec<String> = (0..128).map(|i| format!("k{i}=v{i}")).collect();
    too_many.push("sessionKey=abc".to_string());
    let too_many = too_many.join("; ");

    let table: Vec<(&str, String)> = vec![
        ("empty", "".into()),
        ("only whitespace", "   ".into()),
        ("no sessionKey", "a=1; b=2".into()),
        ("sessionKey with an empty value", "sessionKey=".into()),
        ("sessionKey with an empty value among others", "a=1; sessionKey=".into()),
        ("name differs in case", "sessionkey=abc".into()),
        ("duplicate names", "sessionKey=a; sessionKey=b".into()),
        ("duplicate names with the same value", "sessionKey=a; sessionKey=a".into()),
        ("duplicate other names", "a=1; a=2; sessionKey=x".into()),
        ("space inside the value", "sessionKey=a b".into()),
        ("double quote in the value", "sessionKey=\"abc\"".into()),
        ("comma in the value", "sessionKey=a,b".into()),
        ("backslash in the value", "sessionKey=a\\b".into()),
        ("semicolon injection of a bare token", "sessionKey=a; evil".into()),
        ("semicolon injection of another cookie with a space", "sessionKey=a; x=1 ; y = 2".into()),
        ("empty pair", "sessionKey=a;;b=1".into()),
        ("pair without equals sign", "sessionKey".into()),
        ("empty name", "=value; sessionKey=a".into()),
        ("name with a space", "session Key=a".into()),
        ("name with parentheses", "session(Key)=a; sessionKey=b".into()),
        ("name with a colon", "a:b=1; sessionKey=x".into()),
        ("name with a slash", "a/b=1; sessionKey=x".into()),
        ("CRLF injection", "sessionKey=a\r\nX-Evil: 1".into()),
        ("newline", "sessionKey=a\nb=c".into()),
        ("tab", "sessionKey=a\tb".into()),
        ("NUL", "sessionKey=a\0b".into()),
        ("DEL", "sessionKey=a\u{7f}".into()),
        ("non-ascii value", "sessionKey=é".into()),
        ("non-ascii name", "séssionKey=a".into()),
        ("17 000 bytes", format!("sessionKey={}", "x".repeat(17_000))),
        ("16385 bytes", too_long),
        ("129 pairs", too_many),
    ];
    for (why, header) in &table {
        assert!(!validate_header(header), "{why}: {:?} must be rejected", &header[..header.len().min(60)]);
    }
}

// ---------------------------------------------------------------------------
// browsers
// ---------------------------------------------------------------------------

#[test]
fn browsers_lists_chrome_chromium_and_brave_under_the_config_dir() {
    let config = Path::new("/home/test/.config");
    let list = browsers(config);
    assert_eq!(list.len(), 3);

    assert_eq!(list[0].name, "Google Chrome");
    assert_eq!(list[0].root, config.join("google-chrome"));
    assert_eq!(list[0].keyring_application, "chrome");

    assert_eq!(list[1].name, "Chromium");
    assert_eq!(list[1].root, config.join("chromium"));
    assert_eq!(list[1].keyring_application, "chromium");

    // spec: the display name of the third entry is "Brave" (only the prefix is asserted).
    assert!(list[2].name.starts_with("Brave"), "name was {:?}", list[2].name);
    assert_eq!(list[2].root, config.join("BraveSoftware/Brave-Browser"));
    assert_eq!(list[2].keyring_application, "brave");

    // Rooted at whatever config_dir is given.
    let other = browsers(Path::new("/x"));
    assert_eq!(other[0].root, Path::new("/x/google-chrome"));
}

// ---------------------------------------------------------------------------
// Chrome fixtures
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct Row {
    host: String,
    name: String,
    enc: Vec<u8>,
    path: String,
    expires: i64,
    tfsk: String,
}

fn row(host: &str, name: &str, enc: Vec<u8>) -> Row {
    Row { host: host.into(), name: name.into(), enc, path: "/".into(), expires: 0, tfsk: String::new() }
}

impl Row {
    fn path(mut self, p: &str) -> Row {
        self.path = p.into();
        self
    }
    fn expires(mut self, e: i64) -> Row {
        self.expires = e;
        self
    }
    fn tfsk(mut self, t: &str) -> Row {
        self.tfsk = t.into();
        self
    }
}

/// A valid sessionKey row encrypted for `version`.
fn sk_row(version: i64) -> Row {
    row(".claude.ai", "sessionKey", enc_v10(SK, ".claude.ai", version))
}

/// An auxiliary cookie on `.claude.ai`, path `/`, encrypted v10.
fn aux(name: &str, value: &str, version: i64) -> Row {
    row(".claude.ai", name, enc_v10(value, ".claude.ai", version))
}

#[derive(Clone)]
struct Db {
    version: Option<String>,
    meta_table: bool,
    cookies_table: bool,
    with_tfsk: bool,
    rows: Vec<Row>,
}

fn db(version: i64, rows: Vec<Row>) -> Db {
    Db {
        version: Some(version.to_string()),
        meta_table: true,
        cookies_table: true,
        with_tfsk: true,
        rows,
    }
}

impl Db {
    fn populate(&self, conn: &Connection) {
        if self.meta_table {
            conn.execute("CREATE TABLE meta(key TEXT, value TEXT)", []).unwrap();
            if let Some(v) = &self.version {
                conn.execute("INSERT INTO meta(key, value) VALUES('version', ?1)", params![v]).unwrap();
            }
        }
        if self.cookies_table {
            if self.with_tfsk {
                conn.execute(
                    "CREATE TABLE cookies(host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, path TEXT, expires_utc INTEGER, top_frame_site_key TEXT)",
                    [],
                )
                .unwrap();
            } else {
                conn.execute(
                    "CREATE TABLE cookies(host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, path TEXT, expires_utc INTEGER)",
                    [],
                )
                .unwrap();
            }
            for r in &self.rows {
                self.insert(conn, r);
            }
        }
    }

    fn insert(&self, conn: &Connection, r: &Row) {
        if self.with_tfsk {
            conn.execute(
                "INSERT INTO cookies(host_key, name, value, encrypted_value, path, expires_utc, top_frame_site_key) VALUES(?1, ?2, '', ?3, ?4, ?5, ?6)",
                params![r.host, r.name, r.enc, r.path, r.expires, r.tfsk],
            )
            .unwrap();
        } else {
            conn.execute(
                "INSERT INTO cookies(host_key, name, value, encrypted_value, path, expires_utc) VALUES(?1, ?2, '', ?3, ?4, ?5)",
                params![r.host, r.name, r.enc, r.path, r.expires],
            )
            .unwrap();
        }
    }
}

fn write_db(path: &Path, spec: &Db) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let conn = Connection::open(path).unwrap();
    spec.populate(&conn);
}

struct Chrome {
    tmp: tempfile::TempDir,
}

impl Chrome {
    fn new() -> Chrome {
        let tmp = tempfile::tempdir().unwrap();
        fs::create_dir_all(tmp.path().join("root")).unwrap();
        Chrome { tmp }
    }
    fn root(&self) -> PathBuf {
        self.tmp.path().join("root")
    }
    fn outside(&self) -> PathBuf {
        self.tmp.path().join("outside")
    }
    fn network_db(&self, id: &str) -> PathBuf {
        self.root().join(id).join("Network").join("Cookies")
    }
    fn legacy_db(&self, id: &str) -> PathBuf {
        self.root().join(id).join("Cookies")
    }
    /// Creates `<root>/<id>/Network/Cookies`.
    fn add(&self, id: &str, spec: &Db) -> PathBuf {
        let p = self.network_db(id);
        write_db(&p, spec);
        p
    }
    /// Creates `<root>/<id>/Cookies` (the pre-Network layout).
    fn add_legacy(&self, id: &str, spec: &Db) -> PathBuf {
        let p = self.legacy_db(id);
        write_db(&p, spec);
        p
    }
    fn local_state(&self, contents: &[u8]) {
        fs::write(self.root().join("Local State"), contents).unwrap();
    }
}

struct FakeKeys {
    reply: Result<Vec<u8>, E>,
    calls: Mutex<Vec<bool>>,
}

impl FakeKeys {
    fn ok() -> FakeKeys {
        FakeKeys { reply: Ok(KEYRING_PW.to_vec()), calls: Mutex::new(Vec::new()) }
    }
    fn failing(e: E) -> FakeKeys {
        FakeKeys { reply: Err(e), calls: Mutex::new(Vec::new()) }
    }
    fn calls(&self) -> Vec<bool> {
        self.calls.lock().unwrap().clone()
    }
}

impl KeyProvider for FakeKeys {
    fn password(&self, allow_interaction: bool) -> Result<Vec<u8>, CookieError> {
        self.calls.lock().unwrap().push(allow_interaction);
        match &self.reply {
            Ok(p) => Ok(p.clone()),
            Err(e) => Err(ce(*e)),
        }
    }
}

type Found = Vec<(String, String, String)>; // (profile id, profile name, cookie header)

fn found(r: Result<Vec<ChromeSession>, CookieError>) -> Found {
    r.expect("discover should succeed")
        .into_iter()
        .map(|s| (s.profile.id, s.profile.name, s.cookie_header))
        .collect()
}

fn run(chrome: &Chrome, profile: Option<&str>, keys: &FakeKeys) -> Result<Vec<ChromeSession>, CookieError> {
    discover(&chrome.root(), profile, false, NOW, keys)
}

// ---------------------------------------------------------------------------
// discover: root and profile enumeration
// ---------------------------------------------------------------------------

#[test]
fn discover_missing_root_is_empty_and_unreadable_root_is_unavailable() {
    let tmp = tempfile::tempdir().unwrap();
    let keys = FakeKeys::ok();

    let missing = tmp.path().join("does-not-exist");
    assert_eq!(found(discover(&missing, None, false, NOW, &keys)), Found::new());
    // spec: a missing root is Ok(vec![]) while a missing requested profile is Profile; with both
    // at once either answer is accepted.
    match discover(&missing, Some("Default"), false, NOW, &keys) {
        Ok(sessions) => assert!(sessions.is_empty()),
        Err(e) => assert_eq!(e, CookieError::Profile),
    }

    // An existing, empty root is also just empty.
    let empty = tmp.path().join("empty");
    fs::create_dir_all(&empty).unwrap();
    assert_eq!(found(discover(&empty, None, false, NOW, &keys)), Found::new());

    // Unreadable root -> Unavailable (skipped when running as root, which ignores modes).
    if unsafe { libc::geteuid() } != 0 {
        struct Restore(PathBuf);
        impl Drop for Restore {
            fn drop(&mut self) {
                let _ = fs::set_permissions(&self.0, fs::Permissions::from_mode(0o755));
            }
        }
        let locked = tmp.path().join("locked");
        fs::create_dir_all(locked.join("Default")).unwrap();
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).unwrap();
        let _restore = Restore(locked.clone());
        let result = discover(&locked, None, false, NOW, &keys);
        assert_eq!(cerr(result, "unreadable root"), CookieError::Unavailable);
    }
    assert!(keys.calls().is_empty(), "the keyring is never asked when nothing was found");
}

#[test]
fn discover_lists_default_and_numbered_profiles_sorted_with_names() {
    let chrome = Chrome::new();
    let good = |v: &str| db(24, vec![row(".claude.ai", "sessionKey", enc_v10(v, ".claude.ai", 24))]);
    chrome.add("Profile 3", &good("sk-three"));
    chrome.add("Default", &good("sk-default"));
    chrome.add("Profile 2", &good("sk-two"));
    chrome.add("Profile 1", &good("sk-one"));

    // Things that are not profiles must be ignored, even with valid cookie databases.
    for decoy in ["Profile", "Profile x", "Profile 1a", "profile 1", "Guest Profile", "System Profile", "Profile ", "Crashpad", "default"] {
        // spec: only `Default` and `Profile <digits>` directories count.
        if chrome.root().join(decoy).exists() {
            continue; // a case-insensitive file system already has it
        }
        chrome.add(decoy, &good("sk-decoy"));
    }
    // A profile without a cookie database is skipped.
    fs::create_dir_all(chrome.root().join("Profile 9").join("Network")).unwrap();

    chrome.local_state(
        serde_json::to_string(&json!({"profile": {"info_cache": {
            "Default": {"name": "Work"},
            "Profile 1": {"name": "Personal"},
            "Profile 3": {"name": 42},
            "Profile 9": {"name": "Ghost"}
        }}}))
        .unwrap()
        .as_bytes(),
    );

    let keys = FakeKeys::ok();
    let got = found(run(&chrome, None, &keys));
    let want: Found = vec![
        ("Default".into(), "Work".into(), "sessionKey=sk-default".into()),
        ("Profile 1".into(), "Personal".into(), "sessionKey=sk-one".into()),
        // no entry in Local State: the id is the name
        ("Profile 2".into(), "Profile 2".into(), "sessionKey=sk-two".into()),
        // spec: a non-string name falls back to the id
        ("Profile 3".into(), "Profile 3".into(), "sessionKey=sk-three".into()),
    ];
    assert_eq!(got, want);
    assert!(keys.calls().is_empty(), "v10 values never need the keyring");
}

#[test]
fn discover_ignores_regular_files_named_like_profiles() {
    // spec: profiles are `Default` and `Profile <digits>` *directories*; a stray file is not one
    // and must not break the scan of the real profiles.
    let chrome = Chrome::new();
    chrome.add("Default", &db(24, vec![sk_row(24)]));
    chrome.add("Profile 1", &db(24, vec![sk_row(24)]));
    fs::write(chrome.root().join("Profile 4"), b"not a directory").unwrap();
    fs::write(chrome.root().join("Profile 7"), b"").unwrap();
    let got = found(run(&chrome, None, &FakeKeys::ok()));
    let ids: Vec<&str> = got.iter().map(|g| g.0.as_str()).collect();
    assert_eq!(ids, vec!["Default", "Profile 1"]);
}

#[test]
fn discover_falls_back_to_profile_ids_when_local_state_is_unusable() {
    // failure list #5: Local State huge or invalid JSON -> profile ids used as names.
    let named = |name: &str| {
        serde_json::to_string(&json!({"profile": {"info_cache": {"Default": {"name": name}}}})).unwrap()
    };
    let padded = |total: usize| {
        let mut s = named("Work").into_bytes();
        s.resize(total, b' ');
        s
    };
    let four_mib = 4 * 1024 * 1024;
    let name150 = "n".repeat(150);
    let name150_wide = "é".repeat(150);

    // (why, Local State bytes or None for no file, expected name of Default)
    let cases: Vec<(&str, Option<Vec<u8>>, String)> = vec![
        ("readable names are used", Some(named("Work").into_bytes()), "Work".into()),
        ("no Local State file", None, "Default".into()),
        ("empty file", Some(vec![]), "Default".into()),
        ("invalid json", Some(b"{not json".to_vec()), "Default".into()),
        ("truncated json", Some(br#"{"profile":{"info_cache":{"Default":{"name":"Wo"#.to_vec()), "Default".into()),
        ("binary garbage", Some(vec![0xff, 0xfe, 0x00, 0x01]), "Default".into()),
        ("top-level array", Some(b"[]".to_vec()), "Default".into()),
        ("empty object", Some(b"{}".to_vec()), "Default".into()),
        ("profile is a string", Some(br#"{"profile":"x"}"#.to_vec()), "Default".into()),
        ("info_cache is an array", Some(br#"{"profile":{"info_cache":[]}}"#.to_vec()), "Default".into()),
        ("entry is a string", Some(br#"{"profile":{"info_cache":{"Default":"Work"}}}"#.to_vec()), "Default".into()),
        ("name is null", Some(br#"{"profile":{"info_cache":{"Default":{"name":null}}}}"#.to_vec()), "Default".into()),
        ("valid but 4 MiB + 1 bytes", Some(padded(four_mib + 1)), "Default".into()),
        ("valid and 16 MiB", Some(padded(4 * four_mib)), "Default".into()),
        ("valid and exactly 4 MiB", Some(padded(four_mib)), "Work".into()),
        ("name of 100 chars is kept", Some(named(&"a".repeat(100)).into_bytes()), "a".repeat(100)),
        ("name of 150 chars is cut to 100", Some(named(&name150).into_bytes()), "n".repeat(100)),
        ("multi-byte name is cut to 100 chars", Some(named(&name150_wide).into_bytes()), "é".repeat(100)),
    ];
    for (why, local_state, want) in cases {
        let chrome = Chrome::new();
        chrome.add("Default", &db(24, vec![sk_row(24)]));
        if let Some(bytes) = &local_state {
            chrome.local_state(bytes);
        }
        let got = found(run(&chrome, None, &FakeKeys::ok()));
        assert_eq!(got.len(), 1, "{why}");
        assert_eq!(got[0].0, "Default", "{why}");
        assert_eq!(got[0].1, want, "{why}: profile name");
    }
}

fn chrome_with_symlinked_profile() -> Chrome {
    let chrome = Chrome::new();
    chrome.add("Default", &db(24, vec![sk_row(24)]));
    // The real data of "Profile 1" lives outside the root, with a perfectly valid database.
    let outside_profile = chrome.outside().join("stolen-profile");
    write_db(&outside_profile.join("Network").join("Cookies"), &db(24, vec![sk_row(24)]));
    symlink(&outside_profile, chrome.root().join("Profile 1")).unwrap();
    chrome
}

#[test]
fn discover_rejects_a_requested_profile_that_is_a_symlink_outside_the_root() {
    // failure list #6: a profile directory that is a symlink outside the browser root -> Profile.
    let chrome = chrome_with_symlinked_profile();
    let keys = FakeKeys::ok();
    let result = run(&chrome, Some("Profile 1"), &keys);
    assert_eq!(cerr(result, "requested symlinked profile"), CookieError::Profile);
    assert!(keys.calls().is_empty());

    // The legitimate profile still works when requested.
    assert_eq!(found(run(&chrome, Some("Default"), &keys)).len(), 1);
}

#[test]
fn discover_scan_does_not_list_profile_directories_that_resolve_outside_the_root() {
    // failure list #6, scan mode. spec: profiles are directories "that resolve inside root", so
    // a symlink pointing outside is not listed; the other profiles are still returned.
    let chrome = chrome_with_symlinked_profile();
    let got = found(run(&chrome, None, &FakeKeys::ok()));
    let ids: Vec<&str> = got.iter().map(|g| g.0.as_str()).collect();
    assert_eq!(ids, vec!["Default"], "the symlinked profile must not be scanned");
}

#[test]
fn discover_rejects_invalid_or_missing_requested_profiles() {
    let chrome = Chrome::new();
    chrome.add("Default", &db(24, vec![sk_row(24)]));
    chrome.add("Profile 1", &db(24, vec![sk_row(24)]));
    // A profile directory without any cookie database.
    fs::create_dir_all(chrome.root().join("Profile 2").join("Network")).unwrap();
    // A profile whose database has no sessionKey.
    chrome.add("Profile 3", &db(24, vec![aux("other", "1", 24)]));
    // Traversal bait: a valid profile one level above the root.
    write_db(&chrome.tmp.path().join("Default").join("Network").join("Cookies"), &db(24, vec![sk_row(24)]));
    write_db(&chrome.outside().join("Cookies"), &db(24, vec![sk_row(24)]));

    let keys = FakeKeys::ok();
    let absolute_default = chrome.root().join("Default").to_string_lossy().to_string();
    let bad_ids: Vec<(&str, String)> = vec![
        ("missing profile", "Profile 7".into()),
        ("profile directory without a database", "Profile 2".into()),
        ("empty id", "".into()),
        ("bare 'Profile'", "Profile".into()),
        ("non-numeric profile", "Profile x".into()),
        ("lower-case default", "default".into()),
        ("trailing slash", "Default/".into()),
        ("path traversal to a sibling of the root", "../Default".into()),
        ("path traversal through the root", "Default/../Default".into()),
        ("parent directory", "..".into()),
        ("current directory", ".".into()),
        ("absolute path of a real profile", absolute_default),
        ("absolute system path", "/etc".into()),
        ("profile with a sub path", "Profile 1/Network".into()),
        ("profile id with trailing space", "Profile 1 ".into()),
        ("guest profile", "Guest Profile".into()),
        ("outside directory name", "outside".into()),
    ];
    for (why, id) in &bad_ids {
        let result = run(&chrome, Some(id), &keys);
        assert_eq!(cerr(result, why), CookieError::Profile, "{why}: id {id:?}");
    }
    assert!(keys.calls().is_empty());

    // A valid requested profile returns only that profile.
    let got = found(run(&chrome, Some("Profile 1"), &keys));
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].0, "Profile 1");

    // A requested profile with a database but no sessionKey is skipped, not an error.
    assert_eq!(found(run(&chrome, Some("Profile 3"), &keys)), Found::new());
}

// ---------------------------------------------------------------------------
// discover: database layout and validation
// ---------------------------------------------------------------------------

#[test]
fn discover_prefers_network_cookies_and_falls_back_to_the_legacy_location() {
    let keys = FakeKeys::ok();

    let chrome = Chrome::new();
    chrome.add_legacy("Default", &db(24, vec![row(".claude.ai", "sessionKey", enc_v10("legacy", ".claude.ai", 24))]));
    let got = found(run(&chrome, None, &keys));
    assert_eq!(got[0].2, "sessionKey=legacy", "legacy <profile>/Cookies is used when Network/Cookies is absent");

    chrome.add("Default", &db(24, vec![row(".claude.ai", "sessionKey", enc_v10("network", ".claude.ai", 24))]));
    let got = found(run(&chrome, None, &keys));
    assert_eq!(got[0].2, "sessionKey=network", "Network/Cookies wins when both exist");

    // Mixed layouts across profiles.
    chrome.add_legacy("Profile 1", &db(23, vec![row(".claude.ai", "sessionKey", enc_v10("p1", ".claude.ai", 23))]));
    let got = found(run(&chrome, None, &keys));
    let headers: Vec<&str> = got.iter().map(|g| g.2.as_str()).collect();
    assert_eq!(headers, vec!["sessionKey=network", "sessionKey=p1"]);
}

#[test]
fn discover_requires_a_positive_integer_database_version() {
    // `meta.version` must be a positive integer, else Database.
    let keys = FakeKeys::ok();
    let bad_versions: Vec<(&str, Option<&str>)> = vec![
        ("zero", Some("0")),
        ("negative", Some("-1")),
        ("text", Some("abc")),
        ("empty", Some("")),
        ("fractional", Some("24.5")),
        ("no version row", None),
    ];
    for (why, version) in bad_versions {
        let chrome = Chrome::new();
        let mut spec = db(24, vec![sk_row(24)]);
        spec.version = version.map(str::to_string);
        chrome.add("Default", &spec);
        let result = run(&chrome, Some("Default"), &keys);
        assert_eq!(cerr(result, why), CookieError::Database, "{why}");
    }

    // Structural damage is a Database error too.
    let mut no_meta = db(24, vec![sk_row(24)]);
    no_meta.meta_table = false;
    let mut no_cookies = db(24, vec![]);
    no_cookies.cookies_table = false;
    for (why, spec) in [("missing meta table", no_meta), ("missing cookies table", no_cookies)] {
        let chrome = Chrome::new();
        chrome.add("Default", &spec);
        let result = run(&chrome, Some("Default"), &keys);
        assert_eq!(cerr(result, why), CookieError::Database, "{why}");
    }

    // Not an SQLite file at all, and an empty file (an empty database has no tables).
    for (why, bytes) in [
        ("garbage file", b"this is definitely not an sqlite database, just text".repeat(20)),
        ("zero-byte file", Vec::new()),
    ] {
        let chrome = Chrome::new();
        fs::create_dir_all(chrome.root().join("Default").join("Network")).unwrap();
        fs::write(chrome.network_db("Default"), bytes).unwrap();
        let result = run(&chrome, Some("Default"), &keys);
        assert_eq!(cerr(result, why), CookieError::Database, "{why}");
    }

    // Valid versions on both sides of the host-hash switch at 24 all work.
    for version in [1i64, 23, 24, 25, 100] {
        let chrome = Chrome::new();
        chrome.add("Default", &db(version, vec![sk_row(version), aux("extra", "v", version)]));
        let got = found(run(&chrome, Some("Default"), &keys));
        assert_eq!(got.len(), 1, "db version {version}");
        assert_eq!(got[0].2, format!("extra=v; sessionKey={SK}"), "db version {version}");
    }

    // A database written for version 24 but declaring 23 cannot be decrypted.
    let chrome = Chrome::new();
    chrome.add("Default", &db(23, vec![sk_row(24)]));
    let result = run(&chrome, Some("Default"), &keys);
    assert_eq!(cerr(result, "hash prefix under db 23"), CookieError::Encryption);
}

struct Filter {
    name: &'static str,
    host: &'static str,
    path: &'static str,
    expires: i64,
    tfsk: &'static str,
    included: bool,
}

fn filter_table() -> Vec<Filter> {
    let f = |name, host, path, expires, tfsk, included| Filter { name, host, path, expires, tfsk, included };
    let future = future_chrome();
    vec![
        f("in_dot", ".claude.ai", "/", 0, "", true),
        f("in_bare", "claude.ai", "/", 0, "", true),
        f("in_api", ".claude.ai", "/api", 0, "", true),
        f("in_api_slash", ".claude.ai", "/api/", 0, "", true),
        f("in_future", ".claude.ai", "/", future, "", true),
        f("in_one_microsecond", ".claude.ai", "/", NOW_CHROME + 1, "", true),
        f("out_www", "www.claude.ai", "/", 0, "", false),
        f("out_api_subdomain", "api.claude.ai", "/", 0, "", false),
        f("out_anthropic", ".anthropic.com", "/", 0, "", false),
        f("out_evil_suffix", "evilclaude.ai", "/", 0, "", false),
        f("out_evil_dot_suffix", ".evilclaude.ai", "/", 0, "", false),
        f("out_evil_prefix", "claude.ai.evil.com", "/", 0, "", false),
        f("out_empty_host", "", "/", 0, "", false),
        f("out_path_other", ".claude.ai", "/other", 0, "", false),
        f("out_path_deep", ".claude.ai", "/api/v1", 0, "", false),
        f("out_path_empty", ".claude.ai", "", 0, "", false),
        f("out_path_upper", ".claude.ai", "/API", 0, "", false),
        f("out_expired", ".claude.ai", "/", NOW_CHROME - 1_000_000, "", false),
        f("out_expires_exactly_now", ".claude.ai", "/", NOW_CHROME, "", false),
        f("out_expired_long_ago", ".claude.ai", "/", 1, "", false),
        f("out_partitioned", ".claude.ai", "/", 0, "https://other.example", false),
    ]
}

fn filter_rows(version: i64, include_partitioned: bool) -> (Vec<Row>, String) {
    let mut rows = vec![sk_row(version)];
    let mut pairs: BTreeMap<String, String> = BTreeMap::new();
    pairs.insert("sessionKey".into(), SK.into());
    for f in filter_table() {
        if f.name == "out_partitioned" && !include_partitioned {
            continue;
        }
        let value = format!("val_{}", f.name);
        rows.push(row(f.host, f.name, enc_v10(&value, f.host, version)).path(f.path).expires(f.expires).tfsk(f.tfsk));
        if f.included {
            pairs.insert(f.name.to_string(), value);
        }
    }
    let header = pairs.iter().map(|(k, v)| format!("{k}={v}")).collect::<Vec<_>>().join("; ");
    (rows, header)
}

#[test]
fn discover_keeps_only_claude_cookies_on_allowed_paths_that_have_not_expired() {
    let keys = FakeKeys::ok();
    for version in [23i64, 24] {
        // With the top_frame_site_key column: partitioned cookies are excluded.
        let (rows, want) = filter_rows(version, true);
        let chrome = Chrome::new();
        chrome.add("Default", &db(version, rows));
        let got = found(run(&chrome, None, &keys));
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].2, want, "db {version} with top_frame_site_key");

        // Chrome without that column: every row is considered, the other filters still apply.
        let (rows, want) = filter_rows(version, false);
        let chrome = Chrome::new();
        let mut spec = db(version, rows);
        spec.with_tfsk = false;
        chrome.add("Default", &spec);
        let got = found(run(&chrome, None, &keys));
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].2, want, "db {version} without top_frame_site_key");
    }
}

#[test]
fn discover_first_value_per_name_wins_in_documented_order_and_header_is_sorted() {
    // rows ordered sessionKey first, then longest path, shortest host, name
    let mut rows = vec![
        // inserted least-preferred first, so "first inserted" would be wrong
        row(".claude.ai", "dupA", enc_v10("root", ".claude.ai", 24)),
        row(".claude.ai", "dupA", enc_v10("api", ".claude.ai", 24)).path("/api"),
        row(".claude.ai", "dupA", enc_v10("api_slash", ".claude.ai", 24)).path("/api/"),
        row(".claude.ai", "dupB", enc_v10("long", ".claude.ai", 24)),
        row("claude.ai", "dupB", enc_v10("short", "claude.ai", 24)),
        row("claude.ai", "dupC", enc_v10("h9", "claude.ai", 24)),
        row(".claude.ai", "dupC", enc_v10("p4", ".claude.ai", 24)).path("/api"),
        // the same sessionKey value on several hosts and paths is fine
        row("claude.ai", "sessionKey", enc_v10(SK, "claude.ai", 24)).path("/api"),
        sk_row(24),
        aux("lastActiveOrg", "123e4567-e89b-12d3-a456-426614174000", 24),
        aux("cf_clearance", "v3", 24),
        aux("activitySessionId", "v2", 24),
        aux("__cf_bm", "v1", 24),
    ];
    rows.reverse();
    let chrome = Chrome::new();
    chrome.add("Default", &db(24, rows));
    let got = found(run(&chrome, None, &FakeKeys::ok()));
    assert_eq!(got.len(), 1);
    assert_eq!(
        got[0].2,
        format!(
            "__cf_bm=v1; activitySessionId=v2; cf_clearance=v3; dupA=api_slash; dupB=short; dupC=p4; lastActiveOrg=123e4567-e89b-12d3-a456-426614174000; sessionKey={SK}"
        )
    );
}

// ---------------------------------------------------------------------------
// discover: failures inside a profile
// ---------------------------------------------------------------------------

/// Encrypted blobs that `decrypt_value` must reject, for a cookie on `host` in a db of `version`.
fn bad_blobs(host: &str, version: i64) -> Vec<(&'static str, Vec<u8>)> {
    let k10 = key_for(b"peanuts");
    let mut v = vec![
        ("unknown prefix", prefixed(b"v99", vec![5u8; 32])),
        ("bad padding", prefixed(b"v10", cbc_raw(k10, b"abcdefghijklmnop"))),
        ("ciphertext not a multiple of 16", prefixed(b"v10", vec![5u8; 17])),
        ("not utf-8", prefixed(b"v10", cbc_pkcs7(k10, &with_hash(host, &[0xff, 0xfe, 0x41], version)))),
        // failure list #23: cookie values > 32 KiB
        ("value over 32 KiB", enc_v10(&"a".repeat(40_000), host, version)),
    ];
    if version >= 24 {
        v.push(("no host hash", enc_v10("value", host, 23)));
        v.push(("hash of another host", enc_v10("value", ".other.example", version)));
    }
    v
}

#[test]
fn discover_drops_undecryptable_auxiliary_cookies_but_fails_the_profile_for_session_key() {
    // failure list #18: one auxiliary cookie undecryptable -> dropped; sessionKey failure fails the profile.
    // failure list #23: cookie values > 32 KiB are among the failing kinds.
    let keys = FakeKeys::ok();
    let mut failures = Vec::new();
    for version in [23i64, 24] {
        let mut rows = vec![sk_row(version), aux("good", "1", version)];
        for (i, (_, blob)) in bad_blobs(".claude.ai", version).into_iter().enumerate() {
            rows.push(row(".claude.ai", &format!("bad{i}"), blob));
        }
        let chrome = Chrome::new();
        chrome.add("Default", &db(version, rows));
        let got = found(run(&chrome, Some("Default"), &keys));
        assert_eq!(got.len(), 1, "db {version}");
        assert_eq!(got[0].2, format!("good=1; sessionKey={SK}"), "db {version}: failing auxiliary cookies are dropped");

        for (why, blob) in bad_blobs(".claude.ai", version) {
            let chrome = Chrome::new();
            chrome.add("Default", &db(version, vec![row(".claude.ai", "sessionKey", blob), aux("good", "1", version)]));
            let result = run(&chrome, Some("Default"), &keys);
            // spec: "a failing sessionKey fails the profile with its error" -> the decrypt_value error,
            // except an encrypted value over 32768 bytes, which the reader rejects as InvalidCookie
            // before decrypting (spec decision, matching macOS's "oversized session cookie").
            let expected =
                if why == "value over 32 KiB" { CookieError::InvalidCookie } else { CookieError::Encryption };
            failures.push(expect_error(&format!("db {version}: sessionKey with {why}"), result, expected));
        }
    }
    assert!(keys.calls().is_empty(), "none of the above involves v11");
    report(failures);
}

#[test]
fn discover_fails_the_profile_on_conflicting_session_keys() {
    let keys = FakeKeys::ok();

    // Two different sessionKey values (e.g. on two hosts) cannot be resolved.
    // spec: the error variant is not named; only "fails the profile" is asserted.
    let chrome = Chrome::new();
    chrome.add(
        "Default",
        &db(
            24,
            vec![
                row(".claude.ai", "sessionKey", enc_v10("first-value", ".claude.ai", 24)),
                row("claude.ai", "sessionKey", enc_v10("second-value", "claude.ai", 24)),
            ],
        ),
    );
    let result = run(&chrome, Some("Default"), &keys);
    let _ = cerr(result, "two different sessionKey values");

    // Same value twice is not a conflict.
    let chrome = Chrome::new();
    chrome.add(
        "Default",
        &db(
            24,
            vec![
                row(".claude.ai", "sessionKey", enc_v10("same-value", ".claude.ai", 24)),
                row("claude.ai", "sessionKey", enc_v10("same-value", "claude.ai", 24)).path("/api"),
            ],
        ),
    );
    let got = found(run(&chrome, Some("Default"), &keys));
    assert_eq!(got[0].2, "sessionKey=same-value");
}

#[test]
fn discover_rejects_headers_that_fail_validation_as_invalid_cookie() {
    let keys = FakeKeys::ok();
    let long = "a".repeat(17_000);
    let cases: Vec<(&str, Vec<Row>)> = vec![
        ("auxiliary name with a space", vec![sk_row(24), aux("bad name", "1", 24)]),
        ("auxiliary name with parentheses", vec![sk_row(24), aux("a(b)", "1", 24)]),
        ("semicolon in the sessionKey", vec![row(".claude.ai", "sessionKey", enc_v10("abc;def", ".claude.ai", 24))]),
        ("space in the sessionKey", vec![row(".claude.ai", "sessionKey", enc_v10("abc def", ".claude.ai", 24))]),
        // spec: validate_header demands a non-empty sessionKey, so an empty one is InvalidCookie.
        ("empty sessionKey", vec![row(".claude.ai", "sessionKey", enc_v10("", ".claude.ai", 24))]),
        ("header longer than 16384 bytes", vec![row(".claude.ai", "sessionKey", enc_v10(&long, ".claude.ai", 24))]),
    ];
    let mut failures = Vec::new();
    for (why, rows) in cases {
        let chrome = Chrome::new();
        chrome.add("Default", &db(24, rows));
        failures.push(expect_error(why, run(&chrome, Some("Default"), &keys), CookieError::InvalidCookie));
    }
    report(failures);
}

#[test]
fn discover_drops_auxiliary_cookies_with_invalid_values() {
    // spec decision (SPEC.md, discover): an auxiliary cookie whose value validate_header would
    // reject is dropped like an undecryptable one. JSON, quoted and Unicode auxiliary cookies are
    // common on claude.ai and must not cost the user their session (macOS does the same).
    let keys = FakeKeys::ok();
    let cases: Vec<(&str, Vec<Row>)> = vec![
        ("space in an auxiliary value", vec![sk_row(24), aux("x", "a b", 24)]),
        ("comma in an auxiliary value", vec![sk_row(24), aux("x", "a,b", 24)]),
        ("quote in an auxiliary value", vec![sk_row(24), aux("x", "a\"b", 24)]),
        ("backslash in an auxiliary value", vec![sk_row(24), aux("x", "a\\b", 24)]),
        ("non-ascii auxiliary value", vec![sk_row(24), aux("x", "é", 24)]),
        ("semicolon in an auxiliary value", vec![sk_row(24), aux("x", "a;b", 24)]),
    ];
    for (why, rows) in cases {
        let chrome = Chrome::new();
        chrome.add("Default", &db(24, rows));
        let got = found(run(&chrome, Some("Default"), &keys));
        assert_eq!(got.len(), 1, "{why}");
        assert_eq!(got[0].2, format!("sessionKey={SK}"), "{why}: the invalid auxiliary cookie is dropped");
    }
}

#[test]
fn discover_never_smuggles_extra_cookies_into_the_header() {
    // failure list #4 applied to detected cookies. validate_header splits on ';' and on the first
    // '=', so a value containing ';' followed by name=value-shaped text, or a name containing '=',
    // would turn into a *different* valid-looking header once joined. Whatever the outcome
    // (error, or the offending cookie dropped), the extra pair must never reach the header.
    let keys = FakeKeys::ok();
    let cases: Vec<(&str, Vec<Row>, &str)> = vec![
        ("semicolon in an auxiliary value", vec![sk_row(24), aux("x", "a;b=c", 24)], "b=c"),
        ("semicolon in the sessionKey value", vec![row(".claude.ai", "sessionKey", enc_v10("abc;extra=1", ".claude.ai", 24))], "extra=1"),
        ("equals sign in an auxiliary name", vec![sk_row(24), aux("a=b", "1", 24)], "a=b=1"),
    ];
    for (why, rows, forbidden) in cases {
        let chrome = Chrome::new();
        chrome.add("Default", &db(24, rows));
        if let Ok(sessions) = run(&chrome, Some("Default"), &keys) {
            for s in &sessions {
                assert!(!s.cookie_header.contains(forbidden), "{why}: header {:?} contains {forbidden:?}", s.cookie_header);
                assert!(validate_header(&s.cookie_header), "{why}: header must be valid");
            }
        }
    }
}

#[test]
fn discover_never_returns_more_than_128_cookies() {
    // failure list #23: > 128 cookie rows -> rejected.
    // spec: "At most 128 rows" is ambiguous between truncating and failing; both are
    // accepted, an unbounded header is not.
    let mut rows = vec![sk_row(23)];
    for i in 0..200 {
        rows.push(aux(&format!("c{i:03}"), "v", 23));
    }
    let chrome = Chrome::new();
    chrome.add("Default", &db(23, rows));
    match run(&chrome, Some("Default"), &FakeKeys::ok()) {
        Err(_) => {}
        Ok(sessions) => {
            assert_eq!(sessions.len(), 1);
            let header = &sessions[0].cookie_header;
            let pairs = header.split("; ").count();
            assert!(pairs <= 128, "header has {pairs} pairs");
            assert!(header.contains(&format!("sessionKey={SK}")), "sessionKey is ordered first, so it survives the cap");
            assert!(validate_header(header));
        }
    }

    // Exactly 128 matching rows are all kept.
    let mut rows = vec![sk_row(23)];
    for i in 0..127 {
        rows.push(aux(&format!("c{i:03}"), "v", 23));
    }
    let chrome = Chrome::new();
    chrome.add("Default", &db(23, rows));
    let got = found(run(&chrome, Some("Default"), &FakeKeys::ok()));
    assert_eq!(got[0].2.split("; ").count(), 128);
}

// ---------------------------------------------------------------------------
// discover: keyring behaviour
// ---------------------------------------------------------------------------

#[test]
fn discover_asks_the_keyring_lazily_and_at_most_once_per_call() {
    // failure list #15: background reads never prompt; the password is requested at most once.

    // v10 only: never asked.
    let chrome = Chrome::new();
    chrome.add("Default", &db(24, vec![sk_row(24), aux("a", "1", 24)]));
    let keys = FakeKeys::ok();
    found(discover(&chrome.root(), None, false, NOW, &keys));
    assert!(keys.calls().is_empty(), "no v11 value, no keyring request");

    // v11 sessionKey plus several v11 auxiliary cookies: exactly one request, flag forwarded.
    let chrome = Chrome::new();
    chrome.add(
        "Default",
        &db(
            24,
            vec![
                row(".claude.ai", "sessionKey", enc_v11(SK, ".claude.ai", 24)),
                row(".claude.ai", "a", enc_v11("1", ".claude.ai", 24)),
                row(".claude.ai", "b", enc_v11("2", ".claude.ai", 24)),
                row(".claude.ai", "c", enc_v11("3", ".claude.ai", 24)),
            ],
        ),
    );
    for allow in [false, true] {
        let keys = FakeKeys::ok();
        let got = found(discover(&chrome.root(), None, allow, NOW, &keys));
        assert_eq!(got[0].2, format!("a=1; b=2; c=3; sessionKey={SK}"));
        assert_eq!(keys.calls(), vec![allow], "one request, with allow_interaction = {allow}");
    }

    // v10 sessionKey with v11 auxiliary cookies: still one request, auxiliary cookies decrypted.
    let chrome = Chrome::new();
    chrome.add(
        "Default",
        &db(24, vec![sk_row(24), row(".claude.ai", "a", enc_v11("1", ".claude.ai", 24)), row(".claude.ai", "b", enc_v11("2", ".claude.ai", 24))]),
    );
    let keys = FakeKeys::ok();
    let got = found(discover(&chrome.root(), None, false, NOW, &keys));
    assert_eq!(got[0].2, format!("a=1; b=2; sessionKey={SK}"));
    assert_eq!(keys.calls().len(), 1);

    // Several profiles that all need v11: one request for the whole discover call.
    let chrome = Chrome::new();
    for id in ["Default", "Profile 1", "Profile 2"] {
        let value = format!("sk-{}", id.replace(' ', "-"));
        chrome.add(id, &db(24, vec![row(".claude.ai", "sessionKey", enc_v11(&value, ".claude.ai", 24))]));
    }
    let keys = FakeKeys::ok();
    let got = found(discover(&chrome.root(), None, true, NOW, &keys));
    let headers: Vec<&str> = got.iter().map(|g| g.2.as_str()).collect();
    assert_eq!(headers, vec!["sessionKey=sk-Default", "sessionKey=sk-Profile-1", "sessionKey=sk-Profile-2"]);
    assert_eq!(keys.calls().len(), 1, "the keyring password is cached for the whole call");
}

#[test]
fn discover_never_asks_the_keyring_for_a_profile_without_an_eligible_session_key() {
    // failure list #15: a profile without an eligible sessionKey is skipped without prompting,
    // even though it holds v11 auxiliary cookies.
    let v11_aux = || vec![row(".claude.ai", "a", enc_v11("1", ".claude.ai", 24)), row(".claude.ai", "b", enc_v11("2", ".claude.ai", 24))];
    let with = |mut extra: Vec<Row>| {
        let mut rows = v11_aux();
        rows.append(&mut extra);
        rows
    };
    let cases: Vec<(&str, Vec<Row>)> = vec![
        ("no sessionKey row", with(vec![])),
        ("expired sessionKey", with(vec![row(".claude.ai", "sessionKey", enc_v11(SK, ".claude.ai", 24)).expires(NOW_CHROME - 1)])),
        ("sessionKey on another host", with(vec![row("www.claude.ai", "sessionKey", enc_v11(SK, "www.claude.ai", 24))])),
        ("sessionKey on another path", with(vec![row(".claude.ai", "sessionKey", enc_v11(SK, ".claude.ai", 24)).path("/other")])),
        (
            "partitioned sessionKey",
            with(vec![row(".claude.ai", "sessionKey", enc_v11(SK, ".claude.ai", 24)).tfsk("https://other.example")]),
        ),
    ];
    for (why, rows) in cases {
        let chrome = Chrome::new();
        chrome.add("Default", &db(24, rows));
        for requested in [None, Some("Default")] {
            let keys = FakeKeys::ok();
            let got = found(discover(&chrome.root(), requested, true, NOW, &keys));
            assert_eq!(got, Found::new(), "{why} ({requested:?}): profile is skipped");
            assert!(keys.calls().is_empty(), "{why} ({requested:?}): the keyring must not be asked");
        }
    }

    // Mixed: the profile without a session is skipped silently, the other one asks once.
    let chrome = Chrome::new();
    chrome.add("Default", &db(24, v11_aux()));
    chrome.add("Profile 1", &db(24, vec![row(".claude.ai", "sessionKey", enc_v11(SK, ".claude.ai", 24))]));
    let keys = FakeKeys::ok();
    let got = found(discover(&chrome.root(), None, false, NOW, &keys));
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].0, "Profile 1");
    assert_eq!(keys.calls(), vec![false]);
}

#[test]
fn discover_passes_keyring_failures_through_and_drops_auxiliary_cookies() {
    // failure list #21: keyring locked or denied -> Keyring error (never reported).
    let chrome = Chrome::new();
    chrome.add("Default", &db(24, vec![row(".claude.ai", "sessionKey", enc_v11(SK, ".claude.ai", 24))]));
    for e in [E::Keyring, E::Unavailable] {
        let keys = FakeKeys::failing(e);
        let result = discover(&chrome.root(), Some("Default"), false, NOW, &keys);
        assert_eq!(cerr(result, "v11 sessionKey with a failing keyring"), ce(e), "{e:?} passes through unchanged");
        assert_eq!(keys.calls(), vec![false], "{e:?}: exactly one request");
    }

    // A wrong keyring password cannot decrypt a v11 sessionKey.
    let keys = FakeKeys { reply: Ok(b"another password".to_vec()), calls: Mutex::new(Vec::new()) };
    let result = discover(&chrome.root(), Some("Default"), false, NOW, &keys);
    assert_eq!(cerr(result, "wrong keyring password"), CookieError::Encryption);

    // failure list #18 + #21: a v10 sessionKey survives a failing keyring; the v11 auxiliary cookies are dropped.
    let chrome = Chrome::new();
    chrome.add(
        "Default",
        &db(
            24,
            vec![
                sk_row(24),
                row(".claude.ai", "a", enc_v11("1", ".claude.ai", 24)),
                row(".claude.ai", "b", enc_v11("2", ".claude.ai", 24)),
                aux("kept", "yes", 24),
            ],
        ),
    );
    let keys = FakeKeys::failing(E::Keyring);
    let got = found(discover(&chrome.root(), Some("Default"), false, NOW, &keys));
    assert_eq!(got[0].2, format!("kept=yes; sessionKey={SK}"));
    assert!(keys.calls().len() <= 1, "at most one request even when it fails; got {:?}", keys.calls());
}

// ---------------------------------------------------------------------------
// discover: reading a live Chrome database safely
// ---------------------------------------------------------------------------

fn snapshot_tree(root: &Path) -> BTreeMap<PathBuf, Vec<u8>> {
    fn walk(dir: &Path, out: &mut BTreeMap<PathBuf, Vec<u8>>) {
        for entry in fs::read_dir(dir).unwrap() {
            let entry = entry.unwrap();
            let path = entry.path();
            if path.is_dir() {
                walk(&path, out);
            } else {
                out.insert(path.clone(), fs::read(&path).unwrap());
            }
        }
    }
    let mut out = BTreeMap::new();
    walk(root, &mut out);
    out
}

#[test]
fn discover_leaves_the_profile_directory_byte_for_byte_untouched() {
    // failure list #9: read-only open, no copy of the secret file, nothing written next to it.
    let chrome = Chrome::new();
    chrome.add("Default", &db(24, vec![sk_row(24), aux("a", "1", 24)]));
    chrome.add_legacy("Profile 1", &db(23, vec![sk_row(23)]));
    chrome.local_state(br#"{"profile":{"info_cache":{"Default":{"name":"Work"}}}}"#);

    let before = snapshot_tree(&chrome.root());
    let keys = FakeKeys::ok();
    let got = found(run(&chrome, None, &keys));
    assert_eq!(got.len(), 2);
    let after = snapshot_tree(&chrome.root());
    assert_eq!(
        before.keys().collect::<Vec<_>>(),
        after.keys().collect::<Vec<_>>(),
        "no journal, WAL, shm or copied file may appear in the browser profile"
    );
    assert!(before == after, "no file may change");

    // Nothing is left in the temp dir beside the root either (a copy of the database would show up here).
    let siblings: Vec<_> = fs::read_dir(chrome.tmp.path()).unwrap().map(|e| e.unwrap().file_name()).collect();
    assert_eq!(siblings.len(), 1, "unexpected entries next to the root: {siblings:?}");
}

#[test]
fn discover_reads_rows_that_only_exist_in_the_wal_of_a_live_database() {
    // failure list #9: Chrome writing the cookie DB (WAL) while we read.
    let chrome = Chrome::new();
    let path = chrome.network_db("Default");
    fs::create_dir_all(path.parent().unwrap()).unwrap();

    // "Chrome": a writer connection that stays open, in WAL mode, never checkpointing.
    let writer = Connection::open(&path).unwrap();
    writer.execute_batch("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;").unwrap();
    let spec = db(24, vec![sk_row(24), aux("in_wal", "1", 24)]);
    spec.populate(&writer);
    let wal = PathBuf::from(format!("{}-wal", path.display()));
    assert!(fs::metadata(&wal).map(|m| m.len() > 0).unwrap_or(false), "the rows must live in the WAL");

    let main_before = fs::read(&path).unwrap();
    let wal_before = fs::read(&wal).unwrap();
    let keys = FakeKeys::ok();
    let got = found(run(&chrome, Some("Default"), &keys));
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].2, format!("in_wal=1; sessionKey={SK}"), "committed WAL content must be visible");
    assert_eq!(fs::read(&path).unwrap(), main_before, "main database file untouched");
    assert_eq!(fs::read(&wal).unwrap(), wal_before, "WAL file untouched");

    // More commits while the reader exists in the past: the next read sees them.
    spec.insert(&writer, &aux("later", "2", 24));
    let got = found(run(&chrome, Some("Default"), &keys));
    assert_eq!(got[0].2, format!("in_wal=1; later=2; sessionKey={SK}"));

    // No stray copies next to the database.
    let names: Vec<String> = fs::read_dir(path.parent().unwrap())
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().to_string())
        .collect();
    for n in &names {
        assert!(n == "Cookies" || n == "Cookies-wal" || n == "Cookies-shm", "unexpected file {n}");
    }
}

#[test]
fn discover_waits_out_a_short_write_lock_instead_of_failing() {
    // failure list #9: busy timeout. Rollback-journal mode: an EXCLUSIVE writer blocks readers.
    let chrome = Chrome::new();
    let path = chrome.add("Default", &db(24, vec![sk_row(24)]));
    let spec = db(24, vec![]);

    let (locked_tx, locked_rx) = std::sync::mpsc::channel();
    let writer_path = path.clone();
    let writer = thread::spawn(move || {
        let conn = Connection::open(&writer_path).unwrap();
        conn.execute_batch("BEGIN EXCLUSIVE").unwrap();
        spec.insert(&conn, &aux("late", "1", 24));
        locked_tx.send(()).unwrap();
        thread::sleep(Duration::from_millis(100));
        conn.execute_batch("COMMIT").unwrap();
    });
    locked_rx.recv().unwrap();

    let started = Instant::now();
    let result = run(&chrome, Some("Default"), &FakeKeys::ok());
    let waited = started.elapsed();
    writer.join().unwrap();
    let got = found(result);
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].2, format!("late=1; sessionKey={SK}"), "the read must happen after the writer committed");
    assert!(waited >= Duration::from_millis(30), "the lock was held for 100 ms but discover returned after {waited:?}");
}
