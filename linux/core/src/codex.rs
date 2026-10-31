//! Codex usage through its own CLI: a short-lived, read-only `codex app-server`.
//! Codex owns sign-in and token renewal; LimitFuel never sees its tokens.

use crate::display::{Provider, WindowOption, duration_label};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::io::{ErrorKind, Read, Write};
#[cfg(unix)]
use std::os::fd::AsRawFd;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
#[cfg(unix)]
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
#[cfg(unix)]
use std::process::Child;
use std::process::{ChildStdin, ChildStdout, Command, Stdio};
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

#[cfg(unix)]
fn is_executable(path: &Path) -> bool {
    path.metadata().is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

#[cfg(windows)]
fn is_executable(path: &Path) -> bool {
    is_windows_executable(path)
}

/// What Windows runs by name: `.exe`, `.cmd`, `.bat` and `.com`, never a script like `.ps1`.
fn is_windows_executable(path: &Path) -> bool {
    let runnable = path
        .extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| ["exe", "cmd", "bat", "com"].iter().any(|x| e.eq_ignore_ascii_case(x)));
    runnable && path.metadata().is_ok_and(|m| m.is_file())
}

#[cfg(not(windows))]
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

#[cfg(windows)]
pub fn resolve_executable(custom: Option<&Path>, path_env: Option<&str>, home: &Path) -> Option<PathBuf> {
    let known = |name: &str, fallback: &[&str]| {
        std::env::var_os(name)
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
            .unwrap_or_else(|| fallback.iter().fold(home.to_path_buf(), |path, part| path.join(part)))
    };
    let app_data = known("APPDATA", &["AppData", "Roaming"]);
    let local_app_data = known("LOCALAPPDATA", &["AppData", "Local"]);
    resolve_windows_executable(custom, path_env, home, &app_data, &local_app_data)
}

/// The npm shim (`codex.cmd`) is the usual install; the rest are other package managers.
pub fn resolve_windows_executable(
    custom: Option<&Path>,
    path_env: Option<&str>,
    home: &Path,
    app_data: &Path,
    local_app_data: &Path,
) -> Option<PathBuf> {
    if let Some(custom) = custom.filter(|p| is_windows_executable(p)) {
        return Some(custom.to_path_buf());
    }
    let under = |base: &Path, parts: &[&str]| parts.iter().fold(base.to_path_buf(), |path, part| path.join(part));
    // Only absolute entries: Windows would otherwise also look in the current directory.
    let from_path = path_env
        .unwrap_or("")
        .split(';')
        .map(|entry| {
            let entry = entry.trim();
            entry.strip_prefix('"').and_then(|e| e.strip_suffix('"')).unwrap_or(entry)
        })
        .filter(|entry| !entry.is_empty() && Path::new(entry).is_absolute())
        .flat_map(|dir| [Path::new(dir).join("codex.exe"), Path::new(dir).join("codex.cmd")]);
    let fixed = [
        under(app_data, &["npm", "codex.cmd"]),
        under(local_app_data, &["pnpm", "codex.cmd"]),
        under(home, &[".bun", "bin", "codex.exe"]),
        under(home, &["scoop", "shims", "codex.exe"]),
        under(local_app_data, &["Microsoft", "WinGet", "Links", "codex.exe"]),
        under(home, &[".local", "bin", "codex.exe"]),
    ];
    from_path.chain(fixed).find(|candidate| is_windows_executable(candidate))
}

pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(45);

pub struct CodexClient {
    pub executable: PathBuf,
    pub timeout: Duration,
}

/// Signals the whole process group on every exit: `codex` is often a Node shim
/// whose native child would otherwise outlive it.
#[cfg(unix)]
struct ProcessGroup {
    child: Option<Child>,
}

#[cfg(unix)]
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

#[cfg(windows)]
mod job {
    use std::os::windows::io::AsRawHandle;
    use std::process::Child;
    use std::time::{Duration, Instant};
    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, TH32CS_SNAPTHREAD, THREADENTRY32, Thread32First, Thread32Next,
    };
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation, SetInformationJobObject,
        TerminateJobObject,
    };
    use windows_sys::Win32::System::Threading::{OpenThread, ResumeThread, THREAD_SUSPEND_RESUME};

    /// A Job Object that ends every process in it when closed.
    pub struct Job(HANDLE);

    // SAFETY: a job handle may be used and closed from any thread.
    unsafe impl Send for Job {}

    impl Job {
        pub fn new() -> Option<Job> {
            // SAFETY: plain Win32 calls; the handle is owned by the returned Job.
            unsafe {
                let handle = CreateJobObjectW(std::ptr::null(), std::ptr::null());
                if handle.is_null() {
                    return None;
                }
                let job = Job(handle);
                let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
                limits.BasicLimitInformation.LimitFlags = 0; let _ = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                let size = std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32;
                let set = SetInformationJobObject(
                    job.0,
                    JobObjectExtendedLimitInformation,
                    (&raw const limits).cast(),
                    size,
                );
                (set != 0).then_some(job)
            }
        }

        /// The child was created suspended, so nothing it starts can escape the job.
        pub fn adopt(&self, child: &Child) -> bool {
            // SAFETY: both handles are valid; the child's handle stays owned by `child`.
            let assigned = unsafe { AssignProcessToJobObject(self.0, child.as_raw_handle()) } != 0;
            assigned && resume(child.id())
        }

        pub fn terminate(&self) {
            // SAFETY: valid job handle.
            unsafe { TerminateJobObject(self.0, 1) };
        }
    }

    impl Drop for Job {
        fn drop(&mut self) {
            // SAFETY: closing the last handle also kills the job (KILL_ON_JOB_CLOSE).
            unsafe { CloseHandle(self.0) };
        }
    }

    /// Resumes the suspended primary thread. `std` does not expose its handle.
    fn resume(pid: u32) -> bool {
        // SAFETY: a thread snapshot walked with a correctly sized entry; every handle is closed.
        unsafe {
            let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
            if snapshot == INVALID_HANDLE_VALUE {
                return false;
            }
            let mut entry: THREADENTRY32 = std::mem::zeroed();
            entry.dwSize = std::mem::size_of::<THREADENTRY32>() as u32;
            let mut resumed = false;
            let mut more = Thread32First(snapshot, &mut entry) != 0;
            while more {
                if entry.th32OwnerProcessID == pid {
                    let thread = OpenThread(THREAD_SUSPEND_RESUME, 0, entry.th32ThreadID);
                    if !thread.is_null() {
                        resumed |= ResumeThread(thread) != u32::MAX;
                        CloseHandle(thread);
                    }
                }
                more = Thread32Next(snapshot, &mut entry) != 0;
            }
            CloseHandle(snapshot);
            resumed
        }
    }

    /// Ends the whole tree on every exit: `codex.cmd` starts node, which starts codex.exe.
    pub struct ProcessGroup {
        pub child: Option<Child>,
        pub job: Option<Job>,
    }

    impl Drop for ProcessGroup {
        fn drop(&mut self) {
            let (Some(mut child), Some(job)) = (self.child.take(), self.job.take()) else { return };
            // Stdin is already closed; give the server half a second to exit on its own.
            std::thread::spawn(move || {
                let start = Instant::now();
                while start.elapsed() < Duration::from_millis(500) && !matches!(child.try_wait(), Ok(Some(_))) {
                    std::thread::sleep(Duration::from_millis(25));
                }
                drop(job);
                let _ = child.wait();
            });
        }
    }
}

#[cfg(windows)]
use job::{Job, ProcessGroup};

/// The child's stdout, read until a deadline without blocking past it.
#[cfg(unix)]
struct Output(ChildStdout);

#[cfg(unix)]
impl Output {
    /// `Ok(None)`: nothing within `wait`. `Ok(Some(empty))`: end of output.
    fn read(&mut self, wait: Duration) -> Result<Option<Vec<u8>>, CodexError> {
        let mut descriptor = libc::pollfd { fd: self.0.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        // SAFETY: one valid pollfd for the child's stdout, which this struct owns.
        let ready = unsafe { libc::poll(&mut descriptor, 1, wait.as_millis() as libc::c_int) };
        if ready < 0 {
            if std::io::Error::last_os_error().kind() == ErrorKind::Interrupted {
                return Ok(None);
            }
            return Err(CodexError::Protocol);
        }
        if ready == 0 {
            return Ok(None);
        }
        let mut chunk = [0u8; 65_536];
        match self.0.read(&mut chunk) {
            Ok(count) => Ok(Some(chunk[..count].to_vec())),
            Err(error) if matches!(error.kind(), ErrorKind::Interrupted | ErrorKind::WouldBlock) => Ok(None),
            Err(_) => Err(CodexError::Protocol),
        }
    }
}

/// Windows pipes cannot be polled, so a helper thread reads into a bounded queue.
#[cfg(windows)]
struct Output(std::sync::mpsc::Receiver<std::io::Result<Vec<u8>>>);

#[cfg(windows)]
impl Output {
    fn new(mut stdout: ChildStdout) -> Self {
        // At most 16 chunks of 64 KiB wait in the queue; MAX_OUTPUT stops the reader sooner.
        let (sender, receiver) = std::sync::mpsc::sync_channel(16);
        std::thread::spawn(move || {
            loop {
                let mut chunk = vec![0u8; 65_536];
                let message = match stdout.read(&mut chunk) {
                    Err(error) if error.kind() == ErrorKind::Interrupted => continue,
                    Ok(count) => {
                        chunk.truncate(count);
                        Ok(chunk)
                    }
                    Err(error) => Err(error),
                };
                let last = !matches!(&message, Ok(chunk) if !chunk.is_empty());
                // The receiver is gone once the exchange ended; the job kill closes the pipe.
                if sender.send(message).is_err() || last {
                    break;
                }
            }
        });
        Output(receiver)
    }

    fn read(&mut self, wait: Duration) -> Result<Option<Vec<u8>>, CodexError> {
        use std::sync::mpsc::RecvTimeoutError;
        match self.0.recv_timeout(wait) {
            Ok(Ok(chunk)) => Ok(Some(chunk)),
            // A broken pipe is how a Windows child's exit looks.
            Ok(Err(error)) if error.kind() == ErrorKind::BrokenPipe => Ok(Some(Vec::new())),
            Ok(Err(_)) => Err(CodexError::Protocol),
            Err(RecvTimeoutError::Timeout) => Ok(None),
            Err(RecvTimeoutError::Disconnected) => Ok(Some(Vec::new())),
        }
    }
}

struct Connection {
    input: ChildStdin,
    output: Output,
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
            let Some(chunk) = self.output.read(remaining.min(Duration::from_millis(50)))? else { continue };
            if chunk.is_empty() {
                return Err(if Instant::now() >= self.deadline { CodexError::Timeout } else { CodexError::Protocol });
            }
            self.total += chunk.len();
            if self.total > MAX_OUTPUT {
                return Err(CodexError::InvalidData);
            }
            self.buffer.extend_from_slice(&chunk);
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
        let (input, output, _group) = self.spawn()?;
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

    #[cfg(unix)]
    fn spawn(&self) -> Result<(ChildStdin, Output, ProcessGroup), CodexError> {
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
        Ok((input, Output(output), ProcessGroup { child: Some(child) }))
    }

    #[cfg(windows)]
    fn spawn(&self) -> Result<(ChildStdin, Output, ProcessGroup), CodexError> {
        use std::os::windows::process::CommandExt;
        use windows_sys::Win32::System::Threading::{CREATE_NO_WINDOW, CREATE_SUSPENDED};
        // The npm shim needs node; a login session's PATH usually has it, the default install dir is the fallback.
        let mut path = self.executable.parent().map(|p| p.as_os_str().to_os_string()).unwrap_or_default();
        let node = std::env::var_os("ProgramFiles").map(|p| PathBuf::from(p).join("nodejs").into_os_string());
        for extra in [std::env::var_os("PATH"), node].into_iter().flatten() {
            if !extra.is_empty() {
                path.push(";");
                path.push(extra);
            }
        }
        let home = std::env::var_os("USERPROFILE").map(PathBuf::from).filter(|p| p.is_dir());
        let job = Job::new().ok_or(CodexError::Unavailable)?;
        let mut command = Command::new(&self.executable);
        command
            .args(["app-server", "--listen", "stdio://"])
            .env("PATH", path)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .creation_flags(CREATE_NO_WINDOW | CREATE_SUSPENDED);
        if let Some(home) = home {
            command.current_dir(home);
        }
        let mut child = command.spawn().map_err(|_| CodexError::Unavailable)?;
        if !job.adopt(&child) {
            // Still suspended, or already in the job: either way nothing else runs.
            let _ = child.kill();
            drop(job);
            let _ = child.wait();
            return Err(CodexError::Unavailable);
        }
        let (Some(input), Some(output)) = (child.stdin.take(), child.stdout.take()) else {
            drop(ProcessGroup { child: Some(child), job: Some(job) });
            return Err(CodexError::Protocol);
        };
        Ok((input, Output::new(output), ProcessGroup { child: Some(child), job: Some(job) }))
    }
}
