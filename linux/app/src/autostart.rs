//! Open at login: an XDG autostart entry on Linux, the per-user Run key on Windows.

#[cfg(not(windows))]
mod imp {
    use std::path::PathBuf;

    fn path() -> Option<PathBuf> {
        dirs::config_dir().map(|dir| dir.join("autostart/limitfuel.desktop"))
    }

    pub fn enabled() -> bool {
        path().is_some_and(|p| p.exists())
    }

    /// Desktop Entry Exec quoting: wrap in quotes, escape `"`, `` ` ``, `$` and `\`.
    fn desktop_quote(path: &str) -> String {
        let mut quoted = String::from('"');
        for c in path.chars() {
            if matches!(c, '"' | '`' | '$' | '\\') {
                quoted.push('\\');
            }
            quoted.push(c);
        }
        quoted.push('"');
        quoted
    }

    /// An AppImage runs from a temporary mount; login must start the AppImage file.
    pub fn set(enabled: bool) -> std::io::Result<()> {
        let path = path().ok_or_else(|| std::io::Error::other("no config directory"))?;
        if !enabled {
            return match std::fs::remove_file(&path) {
                Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e),
                _ => Ok(()),
            };
        }
        let executable = std::env::var_os("APPIMAGE")
            .map(PathBuf::from)
            .filter(|p| p.is_file())
            .map_or_else(std::env::current_exe, Ok)?;
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(
            &path,
            format!(
                "[Desktop Entry]\nType=Application\nName=LimitFuel\nComment=Claude and Codex usage in the tray\n\
                 Exec={}\nIcon=limitfuel\nTerminal=false\nX-GNOME-Autostart-enabled=true\n",
                desktop_quote(&executable.display().to_string())
            ),
        )
    }
}

#[cfg(windows)]
mod imp {
    use windows_sys::Win32::Foundation::{ERROR_FILE_NOT_FOUND, ERROR_SUCCESS, WIN32_ERROR};
    use windows_sys::Win32::System::Registry::{
        HKEY_CURRENT_USER, REG_SZ, RRF_RT_REG_BINARY, RRF_RT_REG_SZ, RegDeleteKeyValueW, RegGetValueW,
        RegSetKeyValueW,
    };

    const RUN: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
    /// Task Manager's "Startup apps" switch; it overrides the Run value without removing it.
    const APPROVED: &str = r"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
    const NAME: &str = "LimitFuel";

    fn wide(text: &str) -> Vec<u16> {
        text.encode_utf16().chain(Some(0)).collect()
    }

    fn read(key: &str, flags: u32) -> Option<Vec<u8>> {
        let (key, name) = (wide(key), wide(NAME));
        let mut size = 0u32;
        let (no_type, no_data) = (std::ptr::null_mut(), std::ptr::null_mut());
        // SAFETY: the first call asks for the size, the second fills a buffer of that size.
        unsafe {
            if RegGetValueW(HKEY_CURRENT_USER, key.as_ptr(), name.as_ptr(), flags, no_type, no_data, &mut size)
                != ERROR_SUCCESS
            {
                return None;
            }
            let mut data = vec![0u8; size as usize];
            let status = RegGetValueW(
                HKEY_CURRENT_USER,
                key.as_ptr(),
                name.as_ptr(),
                flags,
                std::ptr::null_mut(),
                data.as_mut_ptr().cast(),
                &mut size,
            );
            (status == ERROR_SUCCESS).then(|| {
                data.truncate(size as usize);
                data
            })
        }
    }

    fn delete(key: &str) -> WIN32_ERROR {
        let (key, name) = (wide(key), wide(NAME));
        // SAFETY: valid, terminated strings.
        unsafe { RegDeleteKeyValueW(HKEY_CURRENT_USER, key.as_ptr(), name.as_ptr()) }
    }

    /// The Run value as Windows starts it: the quoted path of this executable.
    fn command() -> std::io::Result<String> {
        Ok(format!("\"{}\"", std::env::current_exe()?.display()))
    }

    pub fn enabled() -> bool {
        let Some(value) = read(RUN, RRF_RT_REG_SZ) else { return false };
        let units: Vec<u16> = value.chunks_exact(2).map(|b| u16::from_le_bytes([b[0], b[1]])).collect();
        let value = String::from_utf16_lossy(&units);
        let ours = command().is_ok_and(|c| value.trim_end_matches('\0').eq_ignore_ascii_case(&c));
        // An odd first byte means the user turned it off in Task Manager.
        let disabled = read(APPROVED, RRF_RT_REG_BINARY).is_some_and(|b| b.first().is_some_and(|f| f & 1 == 1));
        ours && !disabled
    }

    pub fn set(enabled: bool) -> std::io::Result<()> {
        let ok = |status: WIN32_ERROR| match status {
            ERROR_SUCCESS | ERROR_FILE_NOT_FOUND => Ok(()),
            code => Err(std::io::Error::from_raw_os_error(code as i32)),
        };
        if !enabled {
            ok(delete(RUN))?;
            return ok(delete(APPROVED));
        }
        let (key, name, value) = (wide(RUN), wide(NAME), wide(&command()?));
        let size = (value.len() * 2) as u32;
        // SAFETY: valid, terminated strings; `value` is REG_SZ data including its terminator.
        ok(unsafe { RegSetKeyValueW(HKEY_CURRENT_USER, key.as_ptr(), name.as_ptr(), REG_SZ, value.as_ptr().cast(), size) })?;
        // Turning it on here also clears a "disabled" left by Task Manager.
        ok(delete(APPROVED))
    }
}

pub use imp::{enabled, set};
