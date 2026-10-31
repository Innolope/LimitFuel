//! Preferences in `$XDG_CONFIG_HOME/limitfuel/settings.json`. No secrets: a pasted
//! cookie lives in the Secret Service and a browser cookie is re-read when needed.

use serde::{Deserialize, Serialize};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::PathBuf;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ClaudeSource {
    #[default]
    None,
    Browser,
    Pasted,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub version: u32,
    pub claude_source: ClaudeSource,
    pub browser: Option<String>,
    pub profile_id: Option<String>,
    pub codex_path: Option<String>,
    pub claude_window: String,
    pub codex_window: String,
    pub percentage_mode: String,
    pub notifications: bool,
    pub diagnostics: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            version: 1,
            claude_source: ClaudeSource::None,
            browser: None,
            profile_id: None,
            codex_path: None,
            claude_window: limitfuel_core::display::AUTOMATIC.into(),
            codex_window: limitfuel_core::display::AUTOMATIC.into(),
            percentage_mode: "remaining".into(),
            notifications: true,
            diagnostics: true,
        }
    }
}

fn directory() -> Option<PathBuf> {
    dirs::config_dir().map(|dir| dir.join("limitfuel"))
}

impl Settings {
    pub fn load() -> Self {
        directory()
            .and_then(|dir| fs::read(dir.join("settings.json")).ok())
            .filter(|data| data.len() <= 65_536)
            .and_then(|data| serde_json::from_slice(&data).ok())
            .unwrap_or_default()
    }

    /// Written to a private temporary file and renamed, so a crash never leaves half a file.
    pub fn save(&self) -> std::io::Result<()> {
        let dir = directory().ok_or_else(|| std::io::Error::other("no config directory"))?;
        fs::DirBuilder::new().recursive(true).mode(0o700).create(&dir)?;
        let temporary = dir.join("settings.json.tmp");
        let mut file = OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&temporary)?;
        file.write_all(&serde_json::to_vec_pretty(self).map_err(std::io::Error::other)?)?;
        file.sync_all()?;
        fs::rename(temporary, dir.join("settings.json"))
    }

    pub fn mode(&self) -> limitfuel_core::display::PercentageMode {
        if self.percentage_mode == "used" {
            limitfuel_core::display::PercentageMode::Used
        } else {
            limitfuel_core::display::PercentageMode::Remaining
        }
    }
}
