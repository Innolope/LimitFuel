//! Codex usage through its own CLI: a short-lived, read-only `codex app-server`.
//! Codex owns sign-in and token renewal; LimitFuel never sees its tokens.

use crate::display::{Provider, WindowOption, duration_label};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::io::{ErrorKind, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CodexError {
    Unavailable,
    SignIn,
    Protocol,
    Timeout,
    InvalidData,
}

#[derive(Clone, Debug, PartialEq)]
pub struct CodexWindow {
    pub used_percent: f64,
    pub window_duration_mins: Option<i64>,
    pub resets_at: Option<f64>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct CodexBucket {
    pub id: String,
    pub name: String,
    pub primary: Option<CodexWindow>,
    pub secondary: Option<CodexWindow>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct CodexSnapshot {
    pub account_label: Option<String>,
    pub buckets: Vec<CodexBucket>,
}

impl CodexSnapshot {
    pub fn window_options(&self) -> Vec<WindowOption> {
        let mut name_counts: HashMap<&str, usize> = HashMap::new();
        for bucket in &self.buckets {
            *name_counts.entry(bucket.name.as_str()).or_default() += 1;
        }
        // The usual single "codex" bucket needs no prefix: "Weekly · 7d".
        let shows_bucket =
            self.buckets.len() > 1 || self.buckets.iter().any(|b| !b.name.eq_ignore_ascii_case("codex"));
        let mut options = Vec::new();
        for bucket in &self.buckets {
            let name = if name_counts[bucket.name.as_str()] > 1 {
                format!("{} ({})", bucket.name, bucket.id)
            } else {
                bucket.name.clone()
            };
            // Hash the id so delimiters and Unicode in it cannot alias another option.
            let digest: String = Sha256::digest(bucket.id.as_bytes()).iter().map(|b| format!("{b:02x}")).collect();
            for (role, title, window) in
                [("primary", "Primary", &bucket.primary), ("secondary", "Secondary", &bucket.secondary)]
            {
                let Some(window) = window else { continue };
                let label = window_label(window.window_duration_mins, title);
                options.push(WindowOption {
                    id: format!("codex:{digest}:{role}"),
                    provider: Provider::Codex,
                    label: if shows_bucket { format!("{name} · {label}") } else { label },
                    percent: window.used_percent,
                    duration_minutes: window.window_duration_mins,
                    is_preferred_bucket: bucket.id == "codex",
                    resets_at: window.resets_at,
                });
            }
        }
        options
    }
}

const MAX_OUTPUT: usize = 1_048_576;
const MAX_TIMESTAMP: f64 = 253_402_300_799.0;

fn number(value: Option<&Value>) -> Result<Option<f64>, CodexError> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(n)) => n.as_f64().filter(|v| v.is_finite()).map(Some).ok_or(CodexError::InvalidData),
        Some(_) => Err(CodexError::InvalidData),
    }
}

fn window(raw: Option<&Value>) -> Result<Option<CodexWindow>, CodexError> {
    let object = match raw {
        None | Some(Value::Null) => return Ok(None),
        Some(Value::Object(object)) => object,
        Some(_) => return Err(CodexError::InvalidData),
    };
    let Some(used_percent) = number(object.get("usedPercent"))? else { return Ok(None) };
    if used_percent < 0.0 {
        return Err(CodexError::InvalidData);
    }
    let duration = number(object.get("windowDurationMins"))?;
    if let Some(d) = duration
        && (d <= 0.0 || d.fract() != 0.0 || d >= i64::MAX as f64)
    {
        return Err(CodexError::InvalidData);
    }
    let resets_at = number(object.get("resetsAt"))?;
    if let Some(r) = resets_at
        && !(0.0..=MAX_TIMESTAMP).contains(&r)
    {
        return Err(CodexError::InvalidData);
    }
    Ok(Some(CodexWindow { used_percent, window_duration_mins: duration.map(|d| d as i64), resets_at }))
}

pub fn parse_limits(body: &[u8]) -> Result<Vec<CodexBucket>, CodexError> {
    if body.len() > MAX_OUTPUT {
        return Err(CodexError::InvalidData);
    }
    let result: Value = serde_json::from_slice(body).map_err(|_| CodexError::InvalidData)?;
    let result = result.as_object().ok_or(CodexError::InvalidData)?;
    let entries: Map<String, Value> = match result.get("rateLimitsByLimitId").and_then(Value::as_object) {
        Some(multi) if !multi.is_empty() => multi.clone(),
        _ => {
            let legacy = result.get("rateLimits").and_then(Value::as_object).ok_or(CodexError::InvalidData)?;
            let id = legacy.get("limitId").and_then(Value::as_str).unwrap_or("codex");
            Map::from_iter([(id.to_string(), Value::Object(legacy.clone()))])
        }
    };
    if entries.is_empty() || entries.len() > 64 {
        return Err(CodexError::InvalidData);
    }
    let mut ids: Vec<&String> = entries.keys().collect();
    ids.sort();
    ids.into_iter()
        .map(|id| {
            let length = id.chars().count();
            let object = entries[id].as_object().ok_or(CodexError::InvalidData)?;
            if length == 0 || length > 200 {
                return Err(CodexError::InvalidData);
            }
            let name = object.get("limitName").and_then(Value::as_str).unwrap_or(id);
            if name.chars().count() > 200 {
                return Err(CodexError::InvalidData);
            }
            Ok(CodexBucket {
                id: id.clone(),
                name: name.to_string(),
                primary: window(object.get("primary"))?,
                secondary: window(object.get("secondary"))?,
            })
        })
        .collect()
}

/// Matches the menu titles: "Session · 5h", "Weekly · 7d", "Primary · 2h".
pub fn window_label(minutes: Option<i64>, role: &str) -> String {
    match minutes {
        Some(300) => "Session · 5h".into(),
        Some(10080) => "Weekly · 7d".into(),
        Some(m) if m > 0 => format!("{role} · {}", duration_label(m)),
        _ => role.into(),
    }
}

fn is_executable(path: &Path) -> bool {
    path.metadata().is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

pub fn resolve_executable(custom: Option<&Path>, path_env: Option<&str>, home: &Path) -> Option<PathBuf> {
    if let Some(custom) = custom.filter(|p| is_executable(p)) {
        return Some(custom.to_path_buf());
    }
    let from_path = path_env
        .unwrap_or("")
        .split(':')
        .filter(|dir| dir.starts_with('/'))
        .map(|dir| Path::new(dir).join("codex"));
    let fixed = [
        home.join(".local/bin/codex"),
        home.join(".npm-global/bin/codex"),
        PathBuf::from("/usr/local/bin/codex"),
        PathBuf::from("/usr/bin/codex"),
    ];
    from_path.chain(fixed).find(|candidate| is_executable(candidate))
}

pub fn resolve_windows_executable(
    custom: Option<&Path>,
    path_env: Option<&str>,
    home: &Path,
    app_data: &Path,
    local_app_data: &Path,
) -> Option<PathBuf> {
    let _ = (custom, path_env, home, app_data, local_app_data);
    unimplemented!()
}

pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(45);

pub struct CodexClient {
    pub executable: PathBuf,
    pub timeout: Duration,
}

/// Signals the whole process group on every exit: `codex` is often a Node shim
/// whose native child would otherwise outlive it.
struct ProcessGroup {
    child: Option<Child>,
}

impl Drop for ProcessGroup {
    fn drop(&mut self) {
        let Some(mut child) = self.child.take() else { return };
        let group = child.id() as libc::pid_t;
        // SAFETY: plain signal calls on the group this client created.
        unsafe { libc::killpg(group, libc::SIGTERM) };
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(500));
            unsafe { libc::killpg(group, libc::SIGKILL) };
            let _ = child.wait();
        });
    }
}

struct Connection {
    input: ChildStdin,
    output: ChildStdout,
    buffer: Vec<u8>,
    total: usize,
    deadline: Instant,
    account_established: bool,
    account_updated: bool,
}

impl Connection {
    fn send(&mut self, message: Value) -> Result<(), CodexError> {
        let mut line = serde_json::to_vec(&message).map_err(|_| CodexError::Protocol)?;
        line.push(b'\n');
        // The Rust runtime ignores SIGPIPE, so a child that already exited is EPIPE here.
        self.input.write_all(&line).map_err(|_| CodexError::Protocol)
    }

    fn receive(&mut self, id: i64) -> Result<Map<String, Value>, CodexError> {
        loop {
            while let Some(newline) = self.buffer.iter().position(|b| *b == b'\n') {
                let line: Vec<u8> = self.buffer.drain(..=newline).collect();
                let line = &line[..line.len() - 1];
                if line.iter().all(u8::is_ascii_whitespace) {
                    continue;
                }
                let message: Map<String, Value> = serde_json::from_slice(line).map_err(|_| CodexError::Protocol)?;
                if let Some(method) = message.get("method") {
                    // Unexpected server requests (token renewal UI) get an unsupported-client reply.
                    if let Some(request_id) = message.get("id") {
                        let request_id = request_id.clone();
                        self.send(json!({"id": request_id, "error": {"code": -32601, "message": "Read-only usage client"}}))?;
                        return Err(CodexError::SignIn);
                    }
                    if method == "account/updated" && self.account_established {
                        // Codex's own start-up notice can arrive after account/read; only a
                        // non-ChatGPT mode is a sign-out, anything else is confirmed below.
                        if let Some(mode) = message.get("params").and_then(|p| p.get("authMode")).and_then(Value::as_str)
                            && mode != "chatgpt"
                        {
                            return Err(CodexError::SignIn);
                        }
                        self.account_updated = true;
                    }
                    continue;
                }
                if message.get("id").and_then(Value::as_i64) != Some(id) {
                    continue;
                }
                if message.get("error").is_some_and(|e| !e.is_null()) {
                    return Err(CodexError::Protocol);
                }
                return message.get("result").and_then(Value::as_object).cloned().ok_or(CodexError::Protocol);
            }
            let remaining = self.deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(CodexError::Timeout);
            }
            let mut descriptor =
                libc::pollfd { fd: self.output.as_raw_fd(), events: libc::POLLIN, revents: 0 };
            let wait = remaining.as_millis().min(50) as libc::c_int;
            // SAFETY: one valid pollfd for the child's stdout, which this struct owns.
            let ready = unsafe { libc::poll(&mut descriptor, 1, wait) };
            if ready < 0 {
                if std::io::Error::last_os_error().kind() == ErrorKind::Interrupted {
                    continue;
                }
                return Err(CodexError::Protocol);
            }
            if ready == 0 {
                continue;
            }
            let mut chunk = [0u8; 65_536];
            match self.output.read(&mut chunk) {
                Ok(0) => {
                    return Err(if Instant::now() >= self.deadline { CodexError::Timeout } else { CodexError::Protocol });
                }
                Ok(count) => {
                    self.total += count;
                    if self.total > MAX_OUTPUT {
                        return Err(CodexError::InvalidData);
                    }
                    self.buffer.extend_from_slice(&chunk[..count]);
                }
                Err(error) if matches!(error.kind(), ErrorKind::Interrupted | ErrorKind::WouldBlock) => continue,
                Err(_) => return Err(CodexError::Protocol),
            }
        }
    }

    fn read_account(&mut self, id: i64) -> Result<Option<String>, CodexError> {
        self.send(json!({"id": id, "method": "account/read", "params": {"refreshToken": false}}))?;
        let result = self.receive(id)?;
        let account = result.get("account").and_then(Value::as_object).ok_or(CodexError::SignIn)?;
        if account.get("type").and_then(Value::as_str) != Some("chatgpt") {
            return Err(CodexError::SignIn);
        }
        Ok(account.get("email").and_then(Value::as_str).map(|e| e.chars().take(200).collect()))
    }

    fn read_limits(&mut self, id: i64) -> Result<Vec<CodexBucket>, CodexError> {
        self.send(json!({"id": id, "method": "account/rateLimits/read"}))?;
        let result = self.receive(id)?;
        parse_limits(&serde_json::to_vec(&result).map_err(|_| CodexError::InvalidData)?)
    }
}

impl CodexClient {
    pub fn fetch(&self) -> Result<CodexSnapshot, CodexError> {
        if !is_executable(&self.executable) {
            return Err(CodexError::Unavailable);
        }
        // A GUI session's PATH often lacks the directory of an nvm-managed node,
        // which usually sits next to the codex shim.
        let mut path = self.executable.parent().map(|p| p.display().to_string()).unwrap_or_default();
        for extra in [std::env::var("PATH").unwrap_or_default(), "/usr/local/bin:/usr/bin:/bin".into()] {
            if !extra.is_empty() {
                path.push(':');
                path.push_str(&extra);
            }
        }
        let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"));
        let mut child = Command::new(&self.executable)
            .args(["app-server", "--listen", "stdio://"])
            .current_dir(if home.is_dir() { home } else { PathBuf::from("/") })
            .env("PATH", path)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .process_group(0)
            .spawn()
            .map_err(|_| CodexError::Unavailable)?;
        let (Some(input), Some(output)) = (child.stdin.take(), child.stdout.take()) else {
            drop(ProcessGroup { child: Some(child) });
            return Err(CodexError::Protocol);
        };
        let _group = ProcessGroup { child: Some(child) };
        let mut connection = Connection {
            input,
            output,
            buffer: Vec::new(),
            total: 0,
            deadline: Instant::now() + self.timeout,
            account_established: false,
            account_updated: false,
        };
        let version = env!("CARGO_PKG_VERSION");
        connection.send(json!({"id": 1, "method": "initialize", "params": {"clientInfo": {
            "name": "limitfuel", "title": "LimitFuel", "version": version}}}))?;
        connection.receive(1)?;
        connection.send(json!({"method": "initialized", "params": {}}))?;
        let mut label = connection.read_account(2)?;
        // Updates before this point are start-up announcements. Later ones may be
        // the same announcement racing account/read, or a real account switch.
        connection.account_established = true;
        let mut buckets = connection.read_limits(3)?;
        if connection.account_updated {
            connection.account_updated = false;
            let confirmed = connection.read_account(4)?;
            if confirmed != label {
                label = confirmed;
                buckets = connection.read_limits(5)?;
            }
            // Still changing: report a transient failure and keep the last values.
            if connection.account_updated {
                return Err(CodexError::Protocol);
            }
        }
        Ok(CodexSnapshot { account_label: label, buckets })
    }
}
