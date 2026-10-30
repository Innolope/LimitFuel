//! The Secret Service: the browser's cookie key, and a pasted Claude cookie.
//! Only an explicit user action may unlock a collection; background reads never prompt.

use limitfuel_core::cookies::{CookieError, KeyProvider};

pub struct BrowserKeys {
    pub application: &'static str,
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

#[cfg(not(target_os = "linux"))]
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
