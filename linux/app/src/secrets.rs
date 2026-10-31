//! The Secret Service (Windows: DPAPI and Credential Manager): the browser's cookie
//! key, and a pasted Claude cookie. Only an explicit user action may unlock a
//! collection; background reads never prompt.

use limitfuel_core::cookies::{self, Browser, CookieError, CookieScheme, KeyProvider};

pub struct BrowserKeys {
    #[cfg(not(windows))]
    application: &'static str,
    /// Windows keeps the key in the browser's `Local State`, protected with DPAPI.
    #[cfg(windows)]
    root: std::path::PathBuf,
}

impl BrowserKeys {
    pub fn for_browser(browser: &Browser) -> Self {
        Self {
            #[cfg(not(windows))]
            application: browser.keyring_application,
            #[cfg(windows)]
            root: browser.root.clone(),
        }
    }
}

pub const SCHEME: CookieScheme = if cfg!(windows) { CookieScheme::Windows } else { CookieScheme::Linux };

/// The Chromium-family browsers this platform reads, wherever they are installed.
pub fn browsers() -> Vec<Browser> {
    if cfg!(windows) {
        dirs::data_local_dir().map(|dir| cookies::windows_browsers(&dir)).unwrap_or_default()
    } else {
        dirs::config_dir().map(|dir| cookies::browsers(&dir)).unwrap_or_default()
    }
}

#[cfg(target_os = "linux")]
mod imp {
    use super::*;
    use secret_service::EncryptionType;
    use secret_service::blocking::{Item, SecretService};
    use std::collections::HashMap;

    const COOKIE_LABEL: &str = "LimitFuel Claude session";

    fn connect() -> Option<SecretService<'static>> {
        SecretService::connect(EncryptionType::Dh).ok()
    }

    fn read(item: &Item<'_>, allow_interaction: bool) -> Option<Vec<u8>> {
        if item.is_locked().ok()? {
            if !allow_interaction {
                return None;
            }
            item.unlock().ok()?;
        }
        item.get_secret().ok()
    }

    fn find(service: &SecretService<'_>, attributes: HashMap<&str, &str>, allow_interaction: bool) -> Option<Vec<u8>> {
        let found = service.search_items(attributes).ok()?;
        found
            .unlocked
            .iter()
            .chain(found.locked.iter())
            .find_map(|item| read(item, allow_interaction))
            .filter(|secret| !secret.is_empty())
    }

    impl KeyProvider for BrowserKeys {
        fn password(&self, allow_interaction: bool) -> Result<Vec<u8>, CookieError> {
            let service = connect().ok_or(CookieError::Keyring)?;
            find(&service, HashMap::from([("application", self.application)]), allow_interaction)
                .ok_or(CookieError::Keyring)
        }
    }

    pub fn available() -> bool {
        connect().is_some()
    }

    fn cookie_attributes() -> HashMap<&'static str, &'static str> {
        HashMap::from([("application", "limitfuel"), ("kind", "claude-cookie")])
    }

    pub fn load_cookie(allow_interaction: bool) -> Option<String> {
        let service = connect()?;
        find(&service, cookie_attributes(), allow_interaction).and_then(|s| String::from_utf8(s).ok())
    }

    /// Called from a Settings action, so unlocking (a prompt) is allowed.
    pub fn store_cookie(header: &str) -> bool {
        let Some(service) = connect() else { return false };
        let Ok(collection) = service.get_default_collection() else { return false };
        if collection.is_locked().unwrap_or(true) && collection.unlock().is_err() {
            return false;
        }
        collection
            .create_item(COOKIE_LABEL, cookie_attributes(), header.as_bytes(), true, "text/plain")
            .is_ok()
    }

    pub fn delete_cookie() {
        let Some(service) = connect() else { return };
        if let Ok(found) = service.search_items(cookie_attributes()) {
            for item in found.unlocked.iter().chain(found.locked.iter()) {
                let _ = item.delete();
            }
        }
    }
}

#[cfg(windows)]
mod imp {
    use super::*;
    use limitfuel_core::credential;
    use windows_sys::Win32::Security::Credentials::{
        CRED_PERSIST_LOCAL_MACHINE, CRED_TYPE_GENERIC, CREDENTIALW, CredDeleteW, CredFree, CredReadW, CredWriteW,
    };

    const TARGET: &str = "LimitFuel/claude-cookie";

    impl KeyProvider for BrowserKeys {
        /// DPAPI never prompts, so background reads behave like explicit ones.
        fn password(&self, _allow_interaction: bool) -> Result<Vec<u8>, CookieError> {
            let path = self.root.join("Local State");
            let small = path.metadata().is_ok_and(|m| m.len() <= 4 * 1024 * 1024);
            let data = small.then(|| std::fs::read(&path).ok()).flatten().ok_or(CookieError::Keyring)?;
            cookies::dpapi_unprotect(&cookies::local_state_key(&data)?)
        }
    }

    fn wide(text: &str) -> Vec<u16> {
        text.encode_utf16().chain(Some(0)).collect()
    }

    fn write(target: &str, blob: &[u8]) -> bool {
        let (mut target, mut user) = (wide(target), wide("LimitFuel"));
        let credential = CREDENTIALW {
            Type: CRED_TYPE_GENERIC,
            TargetName: target.as_mut_ptr(),
            CredentialBlobSize: blob.len() as u32,
            CredentialBlob: blob.as_ptr().cast_mut(),
            // This computer only: a session cookie should not roam with the profile.
            Persist: CRED_PERSIST_LOCAL_MACHINE,
            UserName: user.as_mut_ptr(),
            // SAFETY: the remaining fields are plain integers and null pointers.
            ..unsafe { std::mem::zeroed() }
        };
        // SAFETY: every pointer in `credential` outlives the call, which only reads them.
        unsafe { CredWriteW(&credential, 0) != 0 }
    }

    fn read(target: &str) -> Option<Vec<u8>> {
        let target = wide(target);
        let mut credential: *mut CREDENTIALW = std::ptr::null_mut();
        // SAFETY: on success Windows allocates `credential`, released with CredFree.
        unsafe {
            if CredReadW(target.as_ptr(), CRED_TYPE_GENERIC, 0, &mut credential) == 0 || credential.is_null() {
                return None;
            }
            let blob = &*credential;
            let data = (!blob.CredentialBlob.is_null())
                .then(|| std::slice::from_raw_parts(blob.CredentialBlob, blob.CredentialBlobSize as usize).to_vec());
            CredFree(credential.cast());
            data
        }
    }

    fn delete(target: &str) {
        let target = wide(target);
        // SAFETY: a valid, terminated target name; a missing credential is not an error here.
        unsafe { CredDeleteW(target.as_ptr(), CRED_TYPE_GENERIC, 0) };
    }

    fn chunk_target(index: usize) -> String {
        format!("{TARGET}/{index}")
    }

    pub fn available() -> bool {
        true
    }

    /// Credential Manager never prompts, so `allow_interaction` changes nothing.
    pub fn load_cookie(_allow_interaction: bool) -> Option<String> {
        let manifest = read(TARGET)?;
        let count = std::str::from_utf8(&manifest).ok()?.split(':').nth(2)?.parse::<usize>().ok()?;
        if !(1..=credential::MAX_CHUNKS).contains(&count) {
            return None;
        }
        let chunks: Option<Vec<Vec<u8>>> = (1..=count).map(|index| read(&chunk_target(index))).collect();
        String::from_utf8(credential::join(&manifest, &chunks?)?).ok()
    }

    /// The manifest is written last, so an interrupted save never loads as a cookie.
    pub fn store_cookie(header: &str) -> bool {
        let Some((manifest, chunks)) = credential::split(header.as_bytes()) else { return false };
        delete_cookie();
        let stored = chunks.iter().enumerate().all(|(index, chunk)| write(&chunk_target(index + 1), chunk))
            && write(TARGET, &manifest);
        if !stored {
            delete_cookie();
        }
        stored
    }

    pub fn delete_cookie() {
        delete(TARGET);
        for index in 1..=credential::MAX_CHUNKS {
            delete(&chunk_target(index));
        }
    }
}

#[cfg(not(any(target_os = "linux", windows)))]
mod imp {
    use super::*;

    impl KeyProvider for BrowserKeys {
        fn password(&self, _allow_interaction: bool) -> Result<Vec<u8>, CookieError> {
            let _ = self.application; // Only the Linux keyring looks this up.
            Err(CookieError::Keyring)
        }
    }

    pub fn available() -> bool {
        false
    }
    pub fn load_cookie(_allow_interaction: bool) -> Option<String> {
        None
    }
    pub fn store_cookie(_header: &str) -> bool {
        false
    }
    pub fn delete_cookie() {}
}

pub use imp::{available, delete_cookie, load_cookie, store_cookie};
