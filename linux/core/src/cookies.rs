//! Reads only claude.ai's cookies from a Chromium-family browser profile on Linux.
//! No browser scripting, no writes, no copies of the cookie database.

use aes::Aes128;
use cbc::cipher::{BlockModeDecrypt, KeyIvInit, block_padding::Pkcs7};
use rusqlite::{Connection, OpenFlags, params};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::time::Duration;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CookieError {
    Unavailable,
    Database,
    /// The Secret Service is locked, absent or refused; background reads never prompt.
    Keyring,
    Encryption,
    InvalidCookie,
    Profile,
}

impl CookieError {
    pub fn message(self) -> &'static str {
        match self {
            CookieError::Unavailable => "Browser profiles are unavailable. Open Claude in your browser and sign in, then detect again.",
            CookieError::Database => "The browser's cookie storage could not be read completely. Quit the browser and detect again, or paste a cookie.",
            CookieError::Keyring => "The keyring is locked or access was denied. Click Detect Browser Session to unlock it, or paste a cookie.",
            CookieError::Encryption => "Browser cookies use an unsupported or damaged encryption format. Sign in again, or paste a cookie.",
            CookieError::InvalidCookie => "The browser returned an invalid, ambiguous or oversized session cookie. Sign in again, or paste a cookie.",
            CookieError::Profile => "The selected browser profile is unavailable. Detect again to choose a profile.",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChromeProfile {
    pub id: String,
    pub name: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChromeSession {
    pub profile: ChromeProfile,
    pub cookie_header: String,
}

pub trait KeyProvider {
    fn password(&self, allow_interaction: bool) -> Result<Vec<u8>, CookieError>;
}

const MAX_ENCRYPTED: usize = 32_768;
const MAX_PLAIN: usize = 16_384;
const MAX_ROWS: usize = 128;
const CHROME_EPOCH_OFFSET: f64 = 11_644_473_600.0;

pub fn derive_key(password: &[u8]) -> [u8; 16] {
    let mut key = [0u8; 16];
    pbkdf2::pbkdf2_hmac::<sha1::Sha1>(password, b"saltysalt", 1, &mut key);
    key
}

pub fn decrypt_value(
    encrypted: &[u8],
    host: &str,
    db_version: i64,
    v11_password: &mut dyn FnMut() -> Result<Vec<u8>, CookieError>,
) -> Result<String, CookieError> {
    if encrypted.len() > MAX_ENCRYPTED || encrypted.len() <= 3 {
        return Err(CookieError::Encryption);
    }
    let (prefix, cipher) = encrypted.split_at(3);
    if cipher.len() % 16 != 0 {
        return Err(CookieError::Encryption);
    }
    let key = match prefix {
        b"v10" => derive_key(b"peanuts"),
        b"v11" => derive_key(&v11_password()?),
        _ => return Err(CookieError::Encryption),
    };
    let decryptor = cbc::Decryptor::<Aes128>::new(&key.into(), &[b' '; 16].into());
    let mut plain =
        decryptor.decrypt_padded_vec::<Pkcs7>(cipher).map_err(|_| CookieError::Encryption)?;
    if db_version >= 24 {
        let digest = Sha256::digest(host.as_bytes());
        if plain.len() < digest.len() || plain[..digest.len()] != digest[..] {
            return Err(CookieError::Encryption);
        }
        plain.drain(..digest.len());
    }
    String::from_utf8(plain).map_err(|_| CookieError::Encryption)
}

const SEPARATORS: &[u8] = b"()<>@,;:\\\"/[]?={} ";

fn valid_pair(name: &str, value: &str) -> bool {
    !name.is_empty()
        && name.bytes().all(|b| b > 32 && b < 127 && !SEPARATORS.contains(&b))
        && value.bytes().all(|b| b > 32 && b < 127 && !matches!(b, b'"' | b',' | b';' | b'\\'))
}

pub fn validate_header(header: &str) -> bool {
    if header.is_empty() || header.len() > MAX_PLAIN || !header.bytes().all(|b| (32..127).contains(&b)) {
        return false;
    }
    let parts: Vec<&str> = header.split(';').collect();
    if parts.len() > MAX_ROWS {
        return false;
    }
    let mut names = std::collections::HashSet::new();
    let mut has_session = false;
    for part in parts {
        let Some((name, value)) = part.trim().split_once('=') else { return false };
        if !valid_pair(name, value) || !names.insert(name) {
            return false;
        }
        if name == "sessionKey" {
            has_session = !value.is_empty();
        }
    }
    has_session
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Browser {
    pub name: &'static str,
    pub root: PathBuf,
    pub keyring_application: &'static str,
}

pub fn browsers(config_dir: &Path) -> Vec<Browser> {
    vec![
        Browser { name: "Google Chrome", root: config_dir.join("google-chrome"), keyring_application: "chrome" },
        Browser { name: "Chromium", root: config_dir.join("chromium"), keyring_application: "chromium" },
        Browser {
            name: "Brave",
            root: config_dir.join("BraveSoftware/Brave-Browser"),
            keyring_application: "brave",
        },
    ]
}

fn valid_profile_id(id: &str) -> bool {
    id == "Default"
        || id.strip_prefix("Profile ").is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
}

fn profile_names(root: &Path) -> BTreeMap<String, String> {
    let path = root.join("Local State");
    let small = path.metadata().is_ok_and(|m| m.len() <= 4 * 1024 * 1024);
    let json: Option<Value> =
        small.then(|| std::fs::read(&path).ok()).flatten().and_then(|data| serde_json::from_slice(&data).ok());
    json.as_ref()
        .and_then(|j| j.pointer("/profile/info_cache"))
        .and_then(Value::as_object)
        .map(|cache| {
            cache
                .iter()
                .filter_map(|(id, info)| {
                    info.get("name").and_then(Value::as_str).map(|n| (id.clone(), n.chars().take(100).collect()))
                })
                .collect()
        })
        .unwrap_or_default()
}

pub fn discover(
    root: &Path,
    profile_id: Option<&str>,
    allow_interaction: bool,
    now: f64,
    keys: &dyn KeyProvider,
) -> Result<Vec<ChromeSession>, CookieError> {
    let directories: Vec<PathBuf> = match profile_id {
        Some(id) if !valid_profile_id(id) => return Err(CookieError::Profile),
        Some(id) => vec![root.join(id)],
        None => {
            let entries = match std::fs::read_dir(root) {
                Ok(entries) => entries,
                Err(error) if error.kind() == ErrorKind::NotFound => return Ok(vec![]),
                Err(_) => return Err(CookieError::Unavailable),
            };
            let mut ids: Vec<String> = entries
                .filter_map(|e| e.ok())
                .filter_map(|e| e.file_name().into_string().ok())
                .filter(|name| valid_profile_id(name))
                .collect();
            ids.sort();
            ids.into_iter().map(|id| root.join(id)).collect()
        }
    };
    let names = profile_names(root);
    let canonical_root = root.canonicalize().map_err(|_| match profile_id {
        Some(_) => CookieError::Profile,
        None => CookieError::Unavailable,
    })?;
    let mut password: Option<Result<Vec<u8>, CookieError>> = None;
    let mut sessions = Vec::new();
    for directory in directories {
        let resolved =
            directory.canonicalize().ok().filter(|c| c.parent() == Some(canonical_root.as_path()) && c.is_dir());
        let Some(canonical) = resolved else {
            if profile_id.is_some() {
                return Err(CookieError::Profile);
            }
            continue; // Not a profile: a stray file, or a link that leaves the browser root.
        };
        let Some(database) =
            [directory.join("Network/Cookies"), directory.join("Cookies")].into_iter().find(|p| p.exists())
        else {
            if profile_id.is_some() {
                return Err(CookieError::Profile);
            }
            continue; // A new profile may not have a cookie database yet.
        };
        let contained = database.canonicalize().ok().filter(|d| d.starts_with(&canonical) && *d != canonical);
        let Some(canonical_database) = contained else {
            if profile_id.is_some() {
                return Err(CookieError::Profile);
            }
            continue;
        };
        let mut fetch_password = || -> Result<Vec<u8>, CookieError> {
            password.get_or_insert_with(|| keys.password(allow_interaction)).clone()
        };
        if let Some(cookie_header) = read(&canonical_database, now, &mut fetch_password)? {
            let id = directory.file_name().and_then(|n| n.to_str()).unwrap_or_default().to_string();
            let name = names.get(&id).cloned().unwrap_or_else(|| id.clone());
            sessions.push(ChromeSession { profile: ChromeProfile { id, name }, cookie_header });
        }
    }
    Ok(sessions)
}

fn read(
    path: &Path,
    now: f64,
    password: &mut dyn FnMut() -> Result<Vec<u8>, CookieError>,
) -> Result<Option<String>, CookieError> {
    let flags = OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let mut connection = Connection::open_with_flags(path, flags).map_err(|_| CookieError::Database)?;
    connection.busy_timeout(Duration::from_millis(250)).map_err(|_| CookieError::Database)?;
    // One read transaction sees WAL commits consistently without copying the secret file.
    let transaction = connection.transaction().map_err(|_| CookieError::Database)?;
    let version: i64 = transaction
        .query_row("SELECT value FROM meta WHERE key='version'", [], |row| row.get::<_, String>(0))
        .ok()
        .and_then(|v| v.trim().parse().ok())
        .filter(|v| *v > 0)
        .ok_or(CookieError::Database)?;
    // Older browsers did not store partition keys.
    let has_partition_key = {
        let mut statement = transaction.prepare("PRAGMA table_info(cookies)").map_err(|_| CookieError::Database)?;
        let columns: Result<Vec<String>, _> = statement.query_map([], |row| row.get::<_, String>(1)).and_then(|rows| rows.collect());
        columns.map_err(|_| CookieError::Database)?.iter().any(|c| c == "top_frame_site_key")
    };
    let partition = if has_partition_key { "AND top_frame_site_key=''" } else { "" };
    let eligible = format!(
        "host_key IN ('claude.ai','.claude.ai') AND path IN ('/','/api','/api/') \
         AND (expires_utc=0 OR expires_utc>?1) {partition}"
    );
    let chrome_now = (now + CHROME_EPOCH_OFFSET) * 1_000_000.0;
    // Never ask the keyring for a profile that has no eligible session.
    let has_session: Option<i64> = transaction
        .query_row(&format!("SELECT 1 FROM cookies WHERE name='sessionKey' AND {eligible} LIMIT 1"), params![chrome_now], |row| row.get(0))
        .map(Some)
        .or_else(|e| if e == rusqlite::Error::QueryReturnedNoRows { Ok(None) } else { Err(e) })
        .map_err(|_| CookieError::Database)?;
    if has_session.is_none() {
        return Ok(None);
    }
    let mut statement = transaction
        .prepare(&format!(
            "SELECT host_key,name,value,encrypted_value FROM cookies WHERE {eligible} \
             ORDER BY CASE WHEN name='sessionKey' THEN 0 ELSE 1 END, length(path) DESC, \
             length(host_key) ASC, name ASC LIMIT {}",
            MAX_ROWS + 1
        ))
        .map_err(|_| CookieError::Database)?;
    let mut rows = statement.query(params![chrome_now]).map_err(|_| CookieError::Database)?;
    let mut values: BTreeMap<String, String> = BTreeMap::new();
    let mut count = 0;
    while let Some(row) = rows.next().map_err(|_| CookieError::Database)? {
        count += 1;
        let host: Option<String> = row.get(0).ok();
        let name: Option<String> = row.get(1).ok();
        let (Some(host), Some(name)) = (host, name) else { return Err(CookieError::InvalidCookie) };
        if count > MAX_ROWS || name.len() > 1024 || !valid_pair(&name, "") {
            return Err(CookieError::InvalidCookie);
        }
        let value = cookie_value(row, &host, version, password);
        let value = match value {
            Ok(value) if valid_pair(&name, &value) && (name != "sessionKey" || !value.is_empty()) => Ok(value),
            Ok(_) => Err(CookieError::InvalidCookie),
            Err(error) => Err(error),
        };
        match value {
            Ok(value) => {
                if name == "sessionKey" && values.get(&name).is_some_and(|old| *old != value) {
                    return Err(CookieError::InvalidCookie);
                }
                values.entry(name).or_insert(value);
            }
            // JSON, quoted and newer-format auxiliary cookies are common and simply
            // left out; a failing session cookie fails the profile visibly.
            Err(error) if name == "sessionKey" => return Err(error),
            Err(_) => {}
        }
    }
    if !values.contains_key("sessionKey") {
        return Ok(None);
    }
    let header = values.iter().map(|(name, value)| format!("{name}={value}")).collect::<Vec<_>>().join("; ");
    if !validate_header(&header) {
        return Err(CookieError::InvalidCookie);
    }
    Ok(Some(header))
}

fn cookie_value(
    row: &rusqlite::Row<'_>,
    host: &str,
    version: i64,
    password: &mut dyn FnMut() -> Result<Vec<u8>, CookieError>,
) -> Result<String, CookieError> {
    let encrypted: Option<Vec<u8>> = row.get(3).ok();
    if let Some(encrypted) = encrypted.filter(|e| !e.is_empty()) {
        if encrypted.len() > MAX_ENCRYPTED {
            return Err(CookieError::InvalidCookie);
        }
        return decrypt_value(&encrypted, host, version, password);
    }
    let plain: Option<String> = row.get(2).ok();
    match plain {
        Some(text) if text.len() <= MAX_PLAIN => Ok(text),
        _ => Err(CookieError::InvalidCookie),
    }
}
