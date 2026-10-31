//! Acceptance tests written from SPEC.md only; production bodies were not inspected.
//!
//! Plan / What can go wrong (W5, W6, W9, W10): reject unsafe candidates, freeze
//! search precedence, then drive a real cmd shim with disposable Python JSON-RPC
//! fixtures and verify descendant cleanup on success, timeout and protocol error.
//! No global environment or current-directory mutation; tests can run concurrently.
//! Job API fault injection (W11) has no public core seam. No retries or live login.
//! The fake is adapted from tests/codex.rs FAKE_CODEX, without Unix process APIs.
//! Coverage limits: W8 single-instance, W13 Credential Manager fallback, W16-W17
//! startup/uninstall and W20 release metadata belong to the app, outside these
//! public core APIs. W12 is covered only by credential.rs's interrupted-load
//! rejection, not the app's write ordering. W18-W19 are out; W21-W22 are deferred
//! by SPEC.md. No assertion here claims desktop, installer or native-crash proof.

use std::fs;
use std::path::{Path, PathBuf};

use limitfuel_core::codex::resolve_windows_executable;

struct Search {
    dir: tempfile::TempDir,
}

impl Search {
    fn new() -> Self { Self { dir: tempfile::tempdir().unwrap() } }
    fn path(&self, name: &str) -> PathBuf { self.dir.path().join(name) }
    fn resolve(&self, custom: Option<&Path>, path: Option<&str>) -> Option<PathBuf> {
        resolve_windows_executable(custom, path, &self.path("home"), &self.path("roaming"), &self.path("local"))
    }
    fn file(&self, path: &Path) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, "disposable candidate; never executed").unwrap();
    }
    fn fixed(&self) -> Vec<PathBuf> {
        vec![
            self.path("roaming").join("npm").join("codex.cmd"),
            self.path("local").join("pnpm").join("codex.cmd"),
            self.path("home").join(".bun").join("bin").join("codex.exe"),
            self.path("home").join("scoop").join("shims").join("codex.exe"),
            self.path("local").join("Microsoft").join("WinGet").join("Links").join("codex.exe"),
            self.path("home").join(".local").join("bin").join("codex.exe"),
        ]
    }
}

#[test]
fn custom_windows_executable_extensions_are_case_insensitive_and_take_priority() {
    let s = Search::new();
    let fallback = s.fixed()[0].clone();
    s.file(&fallback);
    for extension in ["exe", "EXE", "eXe", "cmd", "CMD", "cMd", "bat", "BAT", "bAt", "com", "COM", "cOm"] {
        let custom = s.path(&format!("custom.{extension}"));
        s.file(&custom);
        assert_eq!(s.resolve(Some(&custom), None), Some(custom));
    }
}

#[test]
fn invalid_custom_candidates_are_rejected_and_search_continues() {
    let s = Search::new();
    let ps1 = s.path("custom.ps1");
    let text = s.path("custom.txt");
    let no_extension = s.path("codex");
    let directory = s.path("directory.exe");
    s.file(&ps1);
    s.file(&text);
    s.file(&no_extension);
    fs::create_dir_all(&directory).unwrap();
    let fallback = s.fixed()[0].clone();
    s.file(&fallback);
    for custom in [ps1, text, no_extension, directory, s.path("missing.exe")] {
        assert_eq!(s.resolve(Some(&custom), None), Some(fallback.clone()), "{custom:?}");
    }
}

#[test]
fn path_entries_are_trimmed_unquoted_and_searched_directory_first_then_exe_cmd() {
    let s = Search::new();
    let first = s.path("first with spaces");
    let second = s.path("second");
    let first_exe = first.join("codex.exe");
    let first_cmd = first.join("codex.cmd");
    let second_exe = second.join("codex.exe");
    for p in [&first_exe, &first_cmd, &second_exe] { s.file(p); }
    let path = format!(" ; relative ; \"{}\" ;  {} ; ;", first.display(), second.display());
    assert_eq!(s.resolve(None, Some(&path)), Some(first_exe.clone()));
    fs::remove_file(&first_exe).unwrap();
    assert_eq!(s.resolve(None, Some(&path)), Some(first_cmd.clone()), "earlier directory cmd beats later exe");
    fs::remove_file(&first_cmd).unwrap();
    fs::create_dir_all(&first_exe).unwrap();
    assert_eq!(s.resolve(None, Some(&path)), Some(second_exe), "a directory named codex.exe is skipped");
}

#[test]
fn empty_relative_or_nonexistent_path_entries_do_not_resolve() {
    let s = Search::new();
    for path in [None, Some(""), Some(" ; ; \"\" ; . ; relative ; ./bin ; ../bin ; "), Some("/missing-limitfuel-codex-fixture")] {
        assert_eq!(s.resolve(None, path), None, "{path:?}");
    }
    // A relative spelling that DOES resolve to a real temp executable must still
    // be ignored. Only construct it when temp and cwd have the same filesystem root.
    let candidate = s.path("relative target").join("codex.exe");
    s.file(&candidate);
    let cwd = std::env::current_dir().unwrap();
    let common = cwd.ancestors().find(|ancestor| candidate.starts_with(ancestor));
    if let Some(common) = common {
        let mut relative = PathBuf::new();
        for _ in cwd.strip_prefix(common).unwrap().components() { relative.push(".."); }
        relative.push(candidate.parent().unwrap().strip_prefix(common).unwrap());
        assert!(!relative.is_absolute());
        assert!(cwd.join(&relative).join("codex.exe").is_file());
        assert_eq!(s.resolve(None, Some(relative.to_str().unwrap())), None);
    }
}

#[test]
fn fixed_locations_follow_spec_order_and_path_beats_all_of_them() {
    let s = Search::new();
    let fixed = s.fixed();
    for p in &fixed { s.file(p); }
    let path_exe = s.path("path").join("codex.exe");
    s.file(&path_exe);
    let path = path_exe.parent().unwrap().to_str().unwrap();
    assert_eq!(s.resolve(None, Some(path)), Some(path_exe.clone()));
    fs::remove_file(&path_exe).unwrap();
    for p in fixed {
        assert_eq!(s.resolve(None, Some(path)), Some(p.clone()));
        fs::remove_file(p).unwrap();
    }
    assert_eq!(s.resolve(None, Some(path)), None);
}

#[cfg(windows)]
mod windows {
    use super::*;
    use std::thread;
    use std::time::{Duration, Instant};

    use limitfuel_core::codex::{CodexClient, CodexError, DEFAULT_TIMEOUT};
    use serde_json::{json, Value};
    use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, ERROR_INVALID_PARAMETER, STILL_ACTIVE};
    use windows_sys::Win32::System::Threading::{
        GetExitCodeProcess, OpenProcess, TerminateProcess, PROCESS_QUERY_LIMITED_INFORMATION,
        PROCESS_TERMINATE,
    };

    const FAKE_CODEX: &str = r#"
import json, os, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(HERE, 'cfg.json')) as f:
    CFG = json.load(f)
def log(value):
    with open(os.path.join(HERE, 'rpc.jsonl'), 'a') as f:
        f.write(json.dumps(value) + '\n')
def send(value):
    print(json.dumps(value), flush=True)
log({'argv': sys.argv[1:], 'pid': os.getpid()})
if CFG.get('spawn_child'):
    child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(600)'],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with open(os.path.join(HERE, 'child.pid'), 'w') as f:
        f.write(str(child.pid))
BUCKET = {'limitId': 'codex', 'limitName': 'codex',
    'primary': {'usedPercent': 42, 'windowDurationMins': 300, 'resetsAt': 1900000000},
    'secondary': {'usedPercent': 7.5, 'windowDurationMins': 10080, 'resetsAt': 1900500000}}
DEFAULTS = {'initialize': {'userAgent': 'fake-codex/1.0'},
    'account/read': {'account': {'type': 'chatgpt', 'email': 'user@example.com'}, 'requiresOpenaiAuth': True},
    'account/rateLimits/read': {'rateLimits': BUCKET}}
for raw in sys.stdin:
    msg = json.loads(raw)
    log(msg)
    method = msg.get('method')
    if method in DEFAULTS:
        time.sleep(CFG.get('reply_delay', 0))
    if method == CFG.get('trigger', 'initialize'):
        if CFG.get('action') == 'hang':
            while True:
                time.sleep(1)
        if CFG.get('action') == 'partial':
            sys.stdout.write('{"id":1,"res')
            sys.stdout.flush()
            while True:
                time.sleep(1)
        if CFG.get('action') == 'eof':
            os._exit(0)
        if CFG.get('action') == 'rpc_error':
            send({'id': msg['id'], 'error': {'code': -32000, 'message': 'fixture'}})
            continue
    if 'id' in msg and method in DEFAULTS:
        send({'method': 'thread/started', 'params': {}})
        send({'id': msg['id'], 'result': DEFAULTS[method]})
"#;

    struct Fake { dir: tempfile::TempDir, exe: PathBuf }

    impl Fake {
        fn new(config: Value) -> Self {
            let dir = tempfile::Builder::new().prefix("limitfuel codex ").tempdir().unwrap();
            let exe = dir.path().join("codex.cmd");
            fs::write(dir.path().join("fake.py"), FAKE_CODEX).unwrap();
            fs::write(dir.path().join("cfg.json"), serde_json::to_vec(&config).unwrap()).unwrap();
            fs::write(&exe, "@echo off\r\npython -u \"%~dp0fake.py\" %*\r\n").unwrap();
            Self { dir, exe }
        }
        fn client(&self, timeout: Duration) -> CodexClient {
            CodexClient { executable: self.exe.clone(), timeout }
        }
        fn log(&self) -> Vec<Value> {
            fs::read_to_string(self.dir.path().join("rpc.jsonl")).unwrap_or_default()
                .lines().map(|s| serde_json::from_str(s).unwrap()).collect()
        }
        fn child(&self) -> Option<u32> {
            fs::read_to_string(self.dir.path().join("child.pid")).ok()?.parse().ok()
        }
        fn assert_tree_gone(&self) {
            let child = self.child().expect("fake must have started and logged a grandchild");
            let server = self.log()[0]["pid"].as_u64().unwrap() as u32;
            let deadline = Instant::now() + Duration::from_secs(3);
            loop {
                if !alive(child) && !alive(server) { return; }
                assert!(Instant::now() < deadline, "job descendants remain alive: child {child}, server {server}");
                thread::sleep(Duration::from_millis(20));
            }
        }
    }

    // Even if the product fails cleanup and an assertion panics, this test fixture
    // must not leave its ten-minute sleeper behind on the CI runner.
    impl Drop for Fake {
        fn drop(&mut self) {
            let mut pids = Vec::new();
            if let Some(pid) = self.child() { pids.push(pid); }
            // Cleanup must not panic on a partially written log if the product
            // returned while the fake was still running.
            if let Some(pid) = fs::read_to_string(self.dir.path().join("rpc.jsonl")).ok()
                .and_then(|s| s.lines().next().and_then(|line| serde_json::from_str::<Value>(line).ok()))
                .and_then(|v| v["pid"].as_u64()) { pids.push(pid as u32); }
            for pid in pids {
                unsafe {
                    let process = OpenProcess(PROCESS_TERMINATE, 0, pid);
                    if !process.is_null() {
                        TerminateProcess(process, 1);
                        CloseHandle(process);
                    }
                }
            }
        }
    }

    fn alive(pid: u32) -> bool {
        unsafe {
            let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
            if process.is_null() {
                assert_eq!(GetLastError(), ERROR_INVALID_PARAMETER, "cannot inspect fixture process {pid}");
                return false;
            }
            let mut status = 0;
            let ok = GetExitCodeProcess(process, &mut status);
            CloseHandle(process);
            assert_ne!(ok, 0, "GetExitCodeProcess({pid})");
            status == STILL_ACTIVE as u32
        }
    }

    fn err<T>(result: Result<T, CodexError>) -> CodexError {
        match result { Ok(_) => panic!("expected Codex error"), Err(e) => e }
    }

    #[test]
    fn cmd_shim_fetches_snapshot_and_speaks_documented_rpc_sequence() {
        assert_eq!(DEFAULT_TIMEOUT, Duration::from_secs(45));
        let fake = Fake::new(json!({"spawn_child": true}));
        let snapshot = fake.client(Duration::from_secs(120)).fetch().expect("cmd shim works");
        assert_eq!(snapshot.account_label.as_deref(), Some("user@example.com"));
        assert_eq!(snapshot.buckets.len(), 1);
        let bucket = &snapshot.buckets[0];
        assert_eq!(bucket.id, "codex");
        assert_eq!(bucket.name, "codex");
        let primary = bucket.primary.as_ref().unwrap();
        assert_eq!(primary.used_percent, 42.0);
        assert_eq!(primary.window_duration_mins, Some(300));
        assert_eq!(primary.resets_at, Some(1900000000.0));
        let secondary = bucket.secondary.as_ref().unwrap();
        assert_eq!(secondary.used_percent, 7.5);
        assert_eq!(secondary.window_duration_mins, Some(10080));
        assert_eq!(secondary.resets_at, Some(1900500000.0));
        let log = fake.log();
        assert_eq!(log[0]["argv"], json!(["app-server", "--listen", "stdio://"]));
        let rpcs: Vec<_> = log.iter().filter(|v| v.get("method").is_some()).collect();
        assert_eq!(rpcs.iter().map(|v| v["method"].as_str().unwrap()).collect::<Vec<_>>(), ["initialize", "initialized", "account/read", "account/rateLimits/read"]);
        assert_eq!(rpcs[0]["id"], 1);
        assert!(rpcs[1].get("id").is_none());
        assert_eq!(rpcs[2]["id"], 2);
        assert_eq!(rpcs[2]["params"]["refreshToken"], false);
        assert_eq!(rpcs[3]["id"], 3);
        fake.assert_tree_gone();
    }

    #[test]
    fn cmd_shim_hangs_share_one_deadline_and_kill_grandchildren() {
        // Three individually quick replies (2 s each) must still exhaust the
        // shared 5 s budget; restarting the deadline per reply is incorrect.
        for (trigger, action, delay) in [("initialize", "hang", 0), ("account/read", "hang", 0), ("account/rateLimits/read", "hang", 0), ("initialize", "partial", 0), ("", "", 2)] {
            let fake = Fake::new(json!({"spawn_child": true, "trigger": trigger, "action": action, "reply_delay": delay}));
            let timeout = Duration::from_secs(5);
            let start = Instant::now();
            let result = fake.client(timeout).fetch();
            let elapsed = start.elapsed();
            assert_eq!(err(result), CodexError::Timeout, "{trigger}/{action}");
            assert!(elapsed >= timeout.saturating_sub(Duration::from_millis(200)));
            assert!(elapsed < timeout + Duration::from_secs(4), "shared deadline exceeded: {elapsed:?}");
            fake.assert_tree_gone();
        }
    }

    #[test]
    fn cmd_shim_protocol_errors_also_kill_grandchildren_after_leader_exits() {
        for (trigger, action) in [("initialize", "eof"), ("account/read", "rpc_error"), ("account/rateLimits/read", "eof")] {
            let fake = Fake::new(json!({"spawn_child": true, "trigger": trigger, "action": action}));
            assert_eq!(err(fake.client(Duration::from_secs(120)).fetch()), CodexError::Protocol);
            fake.assert_tree_gone();
        }
    }

    #[test]
    fn fetch_rejects_ps1_and_text_custom_paths_as_unavailable() {
        let tmp = tempfile::tempdir().unwrap();
        for extension in ["ps1", "txt"] {
            let path = tmp.path().join(format!("codex.{extension}"));
            fs::write(&path, "must never execute").unwrap();
            let client = CodexClient { executable: path, timeout: Duration::from_secs(5) };
            assert_eq!(err(client.fetch()), CodexError::Unavailable);
        }
    }
}
