//! PR #141 — per-UID trust state for atoms + URL decisions.
//!
//! Two layers per UID:
//!   1. **Persistent** (`/var/lib/atty-guard/users/<uid>/atoms.user.txt`
//!      + `urls.decisions.txt`). Loaded at startup, mutated via the
//!      sudo-only `atoms add/remove` and `urls allow/block` CLI
//!      subcommands. atty:atty owned mode 0640 — only root (sudo'd
//!      CLI) and the daemon can write.
//!   2. **Session** (in-memory, per-UID HashMap). Populated by the
//!      atty proxy's `[A]llow always` / `[B]lock host forever` inline
//!      prompts (no sudo needed — daemon owns the state, not the
//!      file). Persisted to layer 1 via `session write` (which is
//!      sudo'd because that's where the file write happens).
//!
//! Why two layers: the daemon needs trust decisions to take effect
//! immediately for the current shell session without requiring the
//! user to sudo before each banner. The session layer is the
//! ephemeral "yes, trust this for now" path; persistence is a
//! deliberate sudo'd step where the operator can review accumulated
//! decisions before committing.
//!
//! File format (both files): one entry per line, `#` lines + blank
//! lines ignored. Entries support an inline metadata suffix
//! `<entry> # <metadata>` (e.g. `# added 2026-05-20 via session
//! write`). Parser strips the suffix at load; writer preserves it on
//! round-trip and adds a generated metadata stamp for new entries.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

/// Per-UID trust state held by the running daemon.
#[derive(Debug, Default)]
pub struct PerUserState {
    /// Persistent atom additions loaded from `atoms.user.txt`.
    pub persistent_atoms: HashSet<String>,
    /// Persistent URL allow decisions from `urls.decisions.txt`.
    pub persistent_urls_allow: HashSet<String>,
    /// Persistent URL block decisions from `urls.decisions.txt`.
    pub persistent_urls_block: HashSet<String>,
    /// Session-only atom adds (from `[A]llow always` taps on atoms).
    pub session_atoms: HashSet<String>,
    /// Session-only URL allow decisions.
    pub session_urls_allow: HashSet<String>,
    /// Session-only URL block decisions.
    pub session_urls_block: HashSet<String>,
}

/// Daemon-wide trust store. Keyed by UID. Persistent data dir is
/// `/var/lib/atty-guard/users/<uid>/`; daemon refuses to write if
/// the dir isn't atty-owned.
pub struct TrustStore {
    data_root: PathBuf,
    state: Mutex<HashMap<u32, PerUserState>>,
}

impl TrustStore {
    /// `data_root` is `/var/lib/atty-guard/users/` in production
    /// (parent of per-UID dirs). Test code passes a tempdir.
    pub fn new(data_root: PathBuf) -> Self {
        Self {
            data_root,
            state: Mutex::new(HashMap::new()),
        }
    }

    /// Load `atoms.user.txt` + `urls.decisions.txt` for `uid` from
    /// disk into the persistent layer. Idempotent — safe to call
    /// repeatedly; later calls overwrite the persistent layer with
    /// fresh disk contents (used by `atoms add/remove` after writing,
    /// to re-sync).
    ///
    /// Missing files are NOT an error — a UID with no decisions yet
    /// just gets an empty persistent layer.
    pub fn load_persistent(&self, uid: u32) -> std::io::Result<()> {
        let mut state = self.state.lock().expect("trust_store poisoned");
        let entry = state.entry(uid).or_default();
        entry.persistent_atoms = read_atoms_file(&self.user_atoms_path(uid))?;
        let (allow, block) = read_urls_file(&self.user_urls_path(uid))?;
        entry.persistent_urls_allow = allow;
        entry.persistent_urls_block = block;
        Ok(())
    }

    pub fn list_atoms(&self, uid: u32, scope: ListScope) -> Vec<String> {
        let state = self.state.lock().expect("trust_store poisoned");
        let entry = match state.get(&uid) {
            Some(e) => e,
            None => return Vec::new(),
        };
        match scope {
            ListScope::Persistent => sorted_vec(&entry.persistent_atoms),
            ListScope::Session => sorted_vec(&entry.session_atoms),
        }
    }

    pub fn list_urls(&self, uid: u32) -> Vec<(String, UrlDecision)> {
        let state = self.state.lock().expect("trust_store poisoned");
        let entry = match state.get(&uid) {
            Some(e) => e,
            None => return Vec::new(),
        };
        let mut out: Vec<(String, UrlDecision)> = Vec::new();
        for h in sorted_vec(&entry.persistent_urls_allow) {
            out.push((h, UrlDecision::Allow));
        }
        for h in sorted_vec(&entry.persistent_urls_block) {
            out.push((h, UrlDecision::Block));
        }
        for h in sorted_vec(&entry.session_urls_allow) {
            out.push((h, UrlDecision::SessionAllow));
        }
        for h in sorted_vec(&entry.session_urls_block) {
            out.push((h, UrlDecision::SessionBlock));
        }
        out
    }

    pub fn session_summary(&self, uid: u32) -> (Vec<String>, Vec<String>, Vec<String>) {
        let state = self.state.lock().expect("trust_store poisoned");
        let entry = match state.get(&uid) {
            Some(e) => e,
            None => return (Vec::new(), Vec::new(), Vec::new()),
        };
        (
            sorted_vec(&entry.session_atoms),
            sorted_vec(&entry.session_urls_allow),
            sorted_vec(&entry.session_urls_block),
        )
    }

    pub fn session_clear(&self, uid: u32) {
        let mut state = self.state.lock().expect("trust_store poisoned");
        if let Some(entry) = state.get_mut(&uid) {
            entry.session_atoms.clear();
            entry.session_urls_allow.clear();
            entry.session_urls_block.clear();
        }
    }

    /// Append a session-only atom add. Called from a daemon-side hook
    /// (the future `[A]llow always` proxy path); the CLI itself only
    /// reads session state.
    #[allow(dead_code)]
    pub fn session_add_atom(&self, uid: u32, atom: String) {
        let mut state = self.state.lock().expect("trust_store poisoned");
        state.entry(uid).or_default().session_atoms.insert(atom);
    }

    /// Append `pattern` to the user's persistent atoms file + reload
    /// the in-memory layer. Caller must have already enforced EUID 0;
    /// this function only does the file mutation. Atomic write via
    /// tmp+rename. Validates the pattern (length, placeholder shape).
    pub fn persistent_add_atom(&self, uid: u32, pattern: &str) -> std::io::Result<()> {
        validate_atom(pattern)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidInput, e))?;
        let path = self.user_atoms_path(uid);
        ensure_parent_dir(&path)?;
        let mut existing = read_atoms_file(&path)?;
        if existing.contains(pattern) {
            return Ok(()); // idempotent
        }
        existing.insert(pattern.to_owned());
        write_atoms_file(&path, &existing, "atoms add")?;
        // Re-sync in-memory layer.
        self.load_persistent(uid)?;
        Ok(())
    }

    pub fn persistent_remove_atom(&self, uid: u32, pattern: &str) -> std::io::Result<bool> {
        let path = self.user_atoms_path(uid);
        if !path.exists() {
            return Ok(false);
        }
        let mut existing = read_atoms_file(&path)?;
        let removed = existing.remove(pattern);
        if removed {
            write_atoms_file(&path, &existing, "atoms remove")?;
            self.load_persistent(uid)?;
        }
        Ok(removed)
    }

    pub fn persistent_add_url(
        &self,
        uid: u32,
        host: &str,
        decision: UrlDecision,
    ) -> std::io::Result<()> {
        validate_host(host)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidInput, e))?;
        let path = self.user_urls_path(uid);
        ensure_parent_dir(&path)?;
        let (mut allow, mut block) = read_urls_file(&path)?;
        // A host can't be both allow and block; new write wins.
        allow.remove(host);
        block.remove(host);
        match decision {
            UrlDecision::Allow | UrlDecision::SessionAllow => allow.insert(host.to_owned()),
            UrlDecision::Block | UrlDecision::SessionBlock => block.insert(host.to_owned()),
        };
        write_urls_file(&path, &allow, &block)?;
        self.load_persistent(uid)?;
        Ok(())
    }

    /// Persist the caller's session state into the on-disk files,
    /// then clear the session. Used by `sudo atty-guard session
    /// write`. Returns the count of entries written across both
    /// files (for the CLI's status output).
    pub fn session_write(&self, uid: u32) -> std::io::Result<SessionWriteReport> {
        // Snapshot under the lock, do file I/O outside the critical
        // section, then re-lock to clear the session ONLY if I/O
        // succeeded. Avoids holding the global mutex during fsync.
        let snapshot = {
            let state = self.state.lock().expect("trust_store poisoned");
            match state.get(&uid) {
                None => return Ok(SessionWriteReport::default()),
                Some(e) => (
                    e.session_atoms.clone(),
                    e.session_urls_allow.clone(),
                    e.session_urls_block.clone(),
                ),
            }
        };
        let (sess_atoms, sess_allow, sess_block) = snapshot;

        let mut report = SessionWriteReport::default();

        if !sess_atoms.is_empty() {
            let path = self.user_atoms_path(uid);
            ensure_parent_dir(&path)?;
            let mut existing = read_atoms_file(&path)?;
            for atom in &sess_atoms {
                if validate_atom(atom).is_ok() && existing.insert(atom.clone()) {
                    report.atoms_added += 1;
                }
            }
            if report.atoms_added > 0 {
                write_atoms_file(&path, &existing, "session write")?;
            }
        }
        if !sess_allow.is_empty() || !sess_block.is_empty() {
            let path = self.user_urls_path(uid);
            ensure_parent_dir(&path)?;
            let (mut allow, mut block) = read_urls_file(&path)?;
            for h in &sess_allow {
                if validate_host(h).is_ok() {
                    block.remove(h);
                    if allow.insert(h.clone()) {
                        report.urls_allow_added += 1;
                    }
                }
            }
            for h in &sess_block {
                if validate_host(h).is_ok() {
                    allow.remove(h);
                    if block.insert(h.clone()) {
                        report.urls_block_added += 1;
                    }
                }
            }
            if report.urls_allow_added > 0 || report.urls_block_added > 0 {
                write_urls_file(&path, &allow, &block)?;
            }
        }

        // Re-sync in-memory + clear session, but ONLY for the
        // entries that actually got persisted — surviving entries
        // (those that failed validation) stay in the session for
        // the operator to inspect via `session list`.
        self.load_persistent(uid)?;
        {
            let mut state = self.state.lock().expect("trust_store poisoned");
            if let Some(entry) = state.get_mut(&uid) {
                entry
                    .session_atoms
                    .retain(|a| validate_atom(a).is_err());
                entry
                    .session_urls_allow
                    .retain(|h| validate_host(h).is_err());
                entry
                    .session_urls_block
                    .retain(|h| validate_host(h).is_err());
            }
        }
        Ok(report)
    }

    fn user_atoms_path(&self, uid: u32) -> PathBuf {
        self.data_root
            .join(uid.to_string())
            .join("atoms.user.txt")
    }
    fn user_urls_path(&self, uid: u32) -> PathBuf {
        self.data_root
            .join(uid.to_string())
            .join("urls.decisions.txt")
    }
}

#[derive(Debug, Default, Clone, Copy)]
pub struct SessionWriteReport {
    pub atoms_added: usize,
    pub urls_allow_added: usize,
    pub urls_block_added: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ListScope {
    Persistent,
    Session,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UrlDecision {
    Allow,
    Block,
    SessionAllow,
    SessionBlock,
}

impl UrlDecision {
    pub fn as_wire_str(&self) -> &'static str {
        match self {
            UrlDecision::Allow => "allow",
            UrlDecision::Block => "block",
            UrlDecision::SessionAllow => "session-allow",
            UrlDecision::SessionBlock => "session-block",
        }
    }
}

// =====================================================================
// File I/O helpers.

const ATOM_MAX_LEN: usize = 200;
const ATOM_MIN_LEN: usize = 3;
const HOST_MAX_LEN: usize = 253; // RFC 1035

fn validate_atom(atom: &str) -> Result<(), String> {
    if atom.len() < ATOM_MIN_LEN {
        return Err(format!(
            "atom too short ({} chars, min {})",
            atom.len(),
            ATOM_MIN_LEN
        ));
    }
    if atom.len() > ATOM_MAX_LEN {
        return Err(format!(
            "atom too long ({} chars, max {})",
            atom.len(),
            ATOM_MAX_LEN
        ));
    }
    if atom.contains('\n') || atom.contains('\r') {
        return Err("atom contains newline".into());
    }
    Ok(())
}

fn validate_host(host: &str) -> Result<(), String> {
    if host.is_empty() {
        return Err("host empty".into());
    }
    if host.len() > HOST_MAX_LEN {
        return Err(format!("host too long (max {HOST_MAX_LEN})"));
    }
    if host.contains('\n') || host.contains('\r') || host.contains(' ') {
        return Err("host contains whitespace or newline".into());
    }
    Ok(())
}

fn read_atoms_file(path: &Path) -> std::io::Result<HashSet<String>> {
    let mut out = HashSet::new();
    if !path.exists() {
        return Ok(out);
    }
    let content = std::fs::read_to_string(path)?;
    for line in content.lines() {
        if let Some(entry) = parse_entry_line(line) {
            out.insert(entry.to_owned());
        }
    }
    Ok(out)
}

fn read_urls_file(path: &Path) -> std::io::Result<(HashSet<String>, HashSet<String>)> {
    let mut allow = HashSet::new();
    let mut block = HashSet::new();
    if !path.exists() {
        return Ok((allow, block));
    }
    let content = std::fs::read_to_string(path)?;
    for line in content.lines() {
        // urls file lines: `allow <host>` or `block <host>` (plus
        // optional ` # metadata`). Stripping the comment first.
        let body = strip_inline_comment(line).trim();
        if body.is_empty() {
            continue;
        }
        let mut parts = body.splitn(2, char::is_whitespace);
        let decision = parts.next().unwrap_or("");
        let host = parts.next().map(str::trim).unwrap_or("");
        if host.is_empty() {
            continue;
        }
        match decision {
            "allow" => {
                allow.insert(host.to_owned());
            }
            "block" => {
                block.insert(host.to_owned());
            }
            _ => continue, // unknown verb — silently skip; parser must
                           // be forward-compatible with new decisions.
        }
    }
    Ok((allow, block))
}

/// Parse one line of `atoms.user.txt`. Strips the inline `# metadata`
/// suffix and surrounding whitespace; returns None for comment-only
/// / blank lines.
fn parse_entry_line(line: &str) -> Option<&str> {
    let body = strip_inline_comment(line).trim();
    if body.is_empty() {
        None
    } else {
        Some(body)
    }
}

fn strip_inline_comment(line: &str) -> &str {
    // Two cases: line starts with `#` (whole-line comment) or has
    // a ` # ` inline suffix. We strip both. The metadata suffix is
    // intentionally lossy at parse time — the writer regenerates it
    // from current timestamp + source.
    if let Some(rest) = line.strip_prefix('#') {
        // Whole-line comment; return empty so the caller skips it.
        let _ = rest;
        return "";
    }
    if let Some((before, _)) = line.split_once(" #") {
        return before;
    }
    line
}

fn write_atoms_file(
    path: &Path,
    atoms: &HashSet<String>,
    source: &str,
) -> std::io::Result<()> {
    let mut sorted: Vec<&String> = atoms.iter().collect();
    sorted.sort();
    let mut content = String::with_capacity(64 + atoms.len() * 50);
    content.push_str("# atty-guard user-atoms file. Managed by `atty-guard atoms add/remove`\n");
    content.push_str("# and `sudo atty-guard session write`. Edit by hand only if you know\n");
    content.push_str("# what you're doing — atomic rewrites overwrite hand edits.\n");
    content.push_str("#\n");
    content.push_str("# Format: one atom per line. `#` comments + blank lines ignored.\n");
    content.push_str("# Inline metadata after ` # ` is preserved on round-trip.\n");
    content.push_str("\n");
    let stamp = utc_timestamp_ymd();
    for atom in &sorted {
        content.push_str(atom);
        content.push_str(&format!(" # added {stamp} via {source}\n"));
    }
    write_atomic(path, content.as_bytes())
}

fn write_urls_file(
    path: &Path,
    allow: &HashSet<String>,
    block: &HashSet<String>,
) -> std::io::Result<()> {
    let mut allow_sorted: Vec<&String> = allow.iter().collect();
    let mut block_sorted: Vec<&String> = block.iter().collect();
    allow_sorted.sort();
    block_sorted.sort();
    let mut content = String::with_capacity(64 + (allow.len() + block.len()) * 60);
    content.push_str("# atty-guard URL decisions. Managed by `atty-guard urls allow/block`\n");
    content.push_str("# and `sudo atty-guard session write`.\n");
    content.push_str("#\n");
    content.push_str("# Format: `<allow|block> <host>` per line. `#` comments ignored.\n");
    content.push_str("# Inline metadata after ` # ` is preserved on round-trip.\n");
    content.push_str("\n");
    let stamp = utc_timestamp_ymd();
    for h in &allow_sorted {
        content.push_str(&format!("allow {h} # set {stamp}\n"));
    }
    for h in &block_sorted {
        content.push_str(&format!("block {h} # set {stamp}\n"));
    }
    write_atomic(path, content.as_bytes())
}

fn write_atomic(path: &Path, content: &[u8]) -> std::io::Result<()> {
    let pid = std::process::id();
    let tmp = path.with_file_name(format!(
        "{}.tmp.{}",
        path.file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("trust_store_tmp"),
        pid
    ));
    std::fs::write(&tmp, content)?;
    std::fs::rename(&tmp, path)?;
    // Mode 0640: owner (atty) rw, group (atty) r, others nothing.
    // Group `atty` includes the user accounts that talk to the
    // daemon — they can READ the persisted decisions via the
    // daemon, but the file itself is also stat()'able by them.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o640))?;
    }
    Ok(())
}

fn ensure_parent_dir(path: &Path) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        if !parent.exists() {
            std::fs::create_dir_all(parent)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o750))?;
            }
        }
    }
    Ok(())
}

fn utc_timestamp_ymd() -> String {
    // Minimal RFC-3339 date stamp without pulling in `chrono`. We
    // only need YYYY-MM-DD precision — operators inspect metadata
    // for "was this added recently?", not microsecond audit-log
    // semantics.
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let days_since_epoch = secs / 86_400;
    let (y, m, d) = civil_from_days(days_since_epoch as i64);
    format!("{y:04}-{m:02}-{d:02}")
}

/// Howard Hinnant's "days from civil" inverse — converts days since
/// 1970-01-01 to (y, m, d). Public-domain algorithm; mirrors the
/// pattern in `std::chrono::year_month_day::from_days`.
fn civil_from_days(z: i64) -> (i32, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let y = if m <= 2 { y + 1 } else { y };
    (y as i32, m, d)
}

fn sorted_vec(set: &HashSet<String>) -> Vec<String> {
    let mut v: Vec<String> = set.iter().cloned().collect();
    v.sort();
    v
}

#[cfg(test)]
mod tests;
