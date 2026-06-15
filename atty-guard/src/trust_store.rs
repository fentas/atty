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
//! write`). Parser strips the suffix at load (the entry itself is
//! the canonical key in the in-memory set). The writer re-stamps
//! EVERY entry with the current date on each rewrite — the parser/
//! writer pair is lossy by design: we don't track per-entry "added
//! on" history across round-trips. The mtime of the file is the
//! load-bearing "when was this last touched" signal; inline
//! metadata is a courtesy for humans reading the file.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::atom_fetcher::is_placeholder_atom_public;

/// Per-UID trust state held by the running daemon.
#[derive(Debug, Default)]
pub struct PerUserState {
    /// Persistent atom additions loaded from `atoms.user.txt`.
    pub persistent_atoms: HashSet<String>,
    /// Persistent URL allow decisions from `urls.decisions.txt`.
    pub persistent_urls_allow: HashSet<String>,
    /// Persistent URL block decisions from `urls.decisions.txt`.
    pub persistent_urls_block: HashSet<String>,
    /// Persistent trust hashes loaded from `commands.trusted.txt`.
    /// SHA-256 hex of `<category>:<matched>` — the same shape the
    /// atty proxy used to write to `~/.cache/atty/security_trust.txt`
    /// before the daemon-side migration. The daemon does NOT consult
    /// this set at classify time — atty proxy seeds its own in-proc
    /// trust set from `TrustList` at module attach + on banner `[t]`,
    /// then short-circuits before any UDS round-trip. This field is
    /// the source of truth for cross-shell sharing + visibility.
    pub persistent_trust: HashSet<String>,
    /// Session-only atom adds (from `[A]llow always` taps on atoms).
    pub session_atoms: HashSet<String>,
    /// Session-only URL allow decisions.
    pub session_urls_allow: HashSet<String>,
    /// Session-only URL block decisions.
    pub session_urls_block: HashSet<String>,
    /// Session trust hashes — `[a]llow always` taps from the
    /// security_guard banner. Each entry is the lowercase hex
    /// SHA-256 of `<category>:<matched>` as computed atty-side in
    /// `security_guard/trust_cache.zig::hashCategoryMatch`. atty
    /// proxy enforces the bypass locally; the daemon-side set
    /// exists for `atty-guard session list` visibility + future
    /// `session write` persistence.
    pub session_trust: HashSet<String>,
}

/// Daemon-wide trust store. Keyed by UID. Persistent data dir is
/// `/var/lib/atty-guard/users/<uid>/`. Ownership enforcement is
/// delegated to systemd's `StateDirectory=atty-guard` directive in
/// the unit — that creates the parent `atty:atty 0750` and the
/// daemon writes per-UID subdirs under it. The daemon itself
/// doesn't stat existing ownership before writing (it can't lower
/// the perms of a misconfigured dir, and the typical failure mode
/// of "atty user can't write" surfaces as a plain io::Error on the
/// first write).
pub struct TrustStore {
    data_root: PathBuf,
    state: Mutex<HashMap<u32, PerUserState>>,
    /// Per-UID serializer for persistent write paths (GPT-review
    /// #024). The thread-per-connection server allows two writes
    /// for the same UID to interleave their read-modify-write
    /// cycles and lose updates. Each persistent_* mutator + the
    /// session_write flow acquires the per-UID Arc<Mutex<()>> via
    /// `acquire_write_lock(uid)` BEFORE doing any disk RMW. The
    /// classify hot path does NOT take this lock — it only reads
    /// the in-memory layer behind `state`, so write serialization
    /// has zero impact on dispatch latency.
    ///
    /// Lock order, strictly: `write_lock(uid)` → `state` (held
    /// briefly inside the write-locked region for swap/snapshot).
    /// Reverse order would deadlock. Classify-only reads of
    /// `state` are fine because they never reach for `write_locks`.
    ///
    /// The outer Mutex is held ONLY for the lazy-insert lookup;
    /// once the inner `Arc<Mutex<()>>` is cloned out, the outer
    /// guard drops and the per-UID critical section runs without
    /// contending against other UIDs' writes.
    write_locks: Mutex<HashMap<u32, Arc<Mutex<()>>>>,
    /// UIDs whose persistent layer has been loaded from disk at
    /// least once. After a mutation the in-memory layer is updated
    /// in-place (no re-read), so this flag is "have we ever read
    /// the on-disk file for this UID?" — flipped to true on first
    /// `load_persistent` or first mutation. classify hot-path
    /// short-circuits the file read when the flag is set.
    loaded: Mutex<HashSet<u32>>,
    /// System-wide fetched atom corpus loaded from
    /// `<state_root>/atoms.system.txt`. Refreshed by the daemon's
    /// own `--atoms-update-interval` thread + `sudo atty-guard
    /// --update-atoms-now`. Loaded with a permission gate: the
    /// file must be `atty:atty` owned (daemon's own UID) and NOT
    /// group/world-writable, otherwise the load is refused with a
    /// journald warning and the in-memory copy stays at whatever
    /// it was. classify hot path scans this alongside the
    /// per-UID overlays.
    ///
    /// Wrapped in `Arc<Vec<String>>` so the classify hot path can
    /// clone JUST the Arc (one refcount bump, no per-atom string
    /// clone) instead of allocating a Vec per request. The mutex
    /// is held only briefly during the swap-on-reload.
    system_fetched_atoms: Mutex<std::sync::Arc<Vec<String>>>,
    /// Path of `atoms.system.txt`. Cached at construction so the
    /// classify path doesn't re-derive it per request. Lives at
    /// `<state_root>/../atoms.system.txt` because `data_root` is
    /// the `users/` subdir.
    system_fetched_path: PathBuf,
    /// `false` until first successful load. Caps off the lazy load
    /// path on classify hot-call so repeated empty-file reads
    /// don't burn syscalls; explicit reload via `reload_system_fetched`
    /// is the only way to re-stat after a refresh.
    system_fetched_loaded: Mutex<bool>,
}

impl TrustStore {
    /// `data_root` is `/var/lib/atty-guard/users/` in production
    /// (parent of per-UID dirs). Test code passes a tempdir.
    pub fn new(data_root: PathBuf) -> Self {
        // `atoms.system.txt` lives at the state-root level (sibling
        // of the `users/` subdir that `data_root` points at). The
        // systemd unit's StateDirectory=atty-guard makes that
        // `/var/lib/atty-guard/atoms.system.txt`.
        let system_fetched_path = data_root
            .parent()
            .map(|p| p.join("atoms.system.txt"))
            .unwrap_or_else(|| data_root.join("atoms.system.txt"));

        // #252 — sweep stale `.tmp.*` files left behind by a crash
        // mid-rename. Linux PID reuse can make `create_new(true)`
        // hard-error on a future write when the recycled PID
        // collides with a stale tmp name; eagerly clean them at
        // startup so the operator doesn't see the failure first.
        // Best-effort: I/O errors here surface to journald via the
        // wrapper but never block daemon startup — the worst case
        // is the operational papercut we're trying to avoid.
        sweep_stale_tmp_files(&data_root);

        Self {
            data_root,
            state: Mutex::new(HashMap::new()),
            write_locks: Mutex::new(HashMap::new()),
            loaded: Mutex::new(HashSet::new()),
            system_fetched_atoms: Mutex::new(std::sync::Arc::new(Vec::new())),
            system_fetched_path,
            system_fetched_loaded: Mutex::new(false),
        }
    }

    /// Look up (or lazily insert) the per-UID write-serialization
    /// mutex. Outer `write_locks` map is held briefly only for the
    /// HashMap lookup; the returned `Arc<Mutex<()>>` is owned by
    /// the caller and can be locked without blocking other UIDs.
    /// See the `write_locks` field doc-comment for lock ordering.
    ///
    /// #251 — opportunistic prune of idle entries. The map grows
    /// monotonically without this — one Arc per UID that ever
    /// performed a persistent write. When the map exceeds the
    /// soft cap, drop entries whose only strong reference is the
    /// map itself (i.e. no write is currently in flight for that
    /// UID). Safe under the outer guard: any thread that would
    /// `clone()` an Arc out of the map is blocked behind this
    /// lock, so `strong_count == 1` reliably means "no live writer."
    fn acquire_write_lock(&self, uid: u32) -> Arc<Mutex<()>> {
        const SOFT_CAP: usize = 1024;
        let mut map = self
            .write_locks
            .lock()
            .expect("write_locks poisoned");
        if map.len() > SOFT_CAP {
            map.retain(|_, arc| Arc::strong_count(arc) > 1);
        }
        map.entry(uid)
            .or_insert_with(|| Arc::new(Mutex::new(())))
            .clone()
    }

    /// Read `atoms.system.txt` from disk + replace the in-memory
    /// copy. Used by daemon startup, SIGHUP, and the `--atoms-update-
    /// interval` thread after a successful fetch. Enforces the
    /// permission gate: returns Err WITHOUT touching the in-memory
    /// copy if the file isn't `atty:atty` owned or has unsafe perms.
    pub fn reload_system_fetched(&self) -> std::io::Result<usize> {
        let parsed = read_system_atoms_file_checked(&self.system_fetched_path)?;
        let count = parsed.len();
        // Materialize into a sorted Vec for stable scan order on
        // the hot path (deterministic `reason` text when multiple
        // atoms could match).
        let mut sorted: Vec<String> = parsed.into_iter().collect();
        sorted.sort();
        let snapshot = std::sync::Arc::new(sorted);
        let mut atoms = self
            .system_fetched_atoms
            .lock()
            .expect("system_fetched_atoms poisoned");
        *atoms = snapshot;
        let mut loaded = self
            .system_fetched_loaded
            .lock()
            .expect("system_fetched_loaded poisoned");
        *loaded = true;
        Ok(count)
    }

    /// Ensure the in-memory copy is loaded at least once (lazy
    /// init from the classify hot path). Idempotent — subsequent
    /// calls are O(1) flag-check on the success path.
    ///
    /// Failure path: a failed `reload_system_fetched` leaves the
    /// `loaded` flag at `false` so a subsequent classify retries
    /// the file open + perm-gate check. This costs one stat per
    /// keystroke when the file is genuinely missing / mis-owned,
    /// but it lets `sudo chown atty:atty atoms.system.txt` take
    /// effect on the very next classify rather than waiting for a
    /// daemon restart (or the next `--atoms-update-interval` cron
    /// tick). Operators running without cron — common on small
    /// installs — would otherwise have to restart the daemon
    /// after every chown fix.
    pub fn ensure_system_fetched_loaded(&self) {
        if *self
            .system_fetched_loaded
            .lock()
            .expect("system_fetched_loaded poisoned")
        {
            return;
        }
        // reload_system_fetched flips loaded=true on success.
        // Drop the result intentionally — failure leaves loaded=false
        // so the next keystroke retries (see docstring).
        let _ = self.reload_system_fetched();
    }

    /// Snapshot of the system-fetched corpus for classify-time
    /// substring scan. Cheap: bumps the Arc refcount, no atom
    /// strings get cloned. The classify hot path iterates the
    /// returned slice — keeps per-Enter allocation bounded.
    pub fn list_system_fetched(&self) -> std::sync::Arc<Vec<String>> {
        self.system_fetched_atoms
            .lock()
            .expect("system_fetched_atoms poisoned")
            .clone()
    }

    /// Load `atoms.user.txt` + `urls.decisions.txt` for `uid` from
    /// disk into the persistent layer. Idempotent — safe to call
    /// repeatedly; later calls overwrite the persistent layer with
    /// fresh disk contents (used by `atoms add/remove` after writing,
    /// to re-sync).
    ///
    /// File I/O happens OUTSIDE the global state lock so a slow
    /// disk doesn't block other trust-store operations (classify
    /// dispatch in particular). After reading + parsing, we take
    /// the lock just long enough to swap the in-memory layer.
    ///
    /// Missing files are NOT an error — a UID with no decisions yet
    /// just gets an empty persistent layer.
    pub fn load_persistent(&self, uid: u32) -> std::io::Result<()> {
        // I/O first, no locks held.
        let atoms = read_atoms_file(&self.user_atoms_path(uid))?;
        let (allow, block) = read_urls_file(&self.user_urls_path(uid))?;
        let trust = read_trust_file(&self.user_trust_path(uid))?;
        // Brief locked swap.
        let mut state = self.state.lock().expect("trust_store poisoned");
        let entry = state.entry(uid).or_default();
        entry.persistent_atoms = atoms;
        entry.persistent_urls_allow = allow;
        entry.persistent_urls_block = block;
        entry.persistent_trust = trust;
        drop(state);
        self.loaded
            .lock()
            .expect("loaded poisoned")
            .insert(uid);
        Ok(())
    }

    /// classify hot-path entry point: ensures persistent state is
    /// loaded ONCE per UID per daemon lifetime, then no-op on
    /// subsequent calls. Mutating operations call `load_persistent`
    /// directly after writing — keeps the in-memory layer fresh
    /// without a per-classify disk read.
    pub fn ensure_loaded(&self, uid: u32) -> std::io::Result<()> {
        if self
            .loaded
            .lock()
            .expect("loaded poisoned")
            .contains(&uid)
        {
            return Ok(());
        }
        self.load_persistent(uid)
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

    pub fn session_summary(
        &self,
        uid: u32,
    ) -> (Vec<String>, Vec<String>, Vec<String>, Vec<String>) {
        let state = self.state.lock().expect("trust_store poisoned");
        let entry = match state.get(&uid) {
            Some(e) => e,
            None => return (Vec::new(), Vec::new(), Vec::new(), Vec::new()),
        };
        (
            sorted_vec(&entry.session_atoms),
            sorted_vec(&entry.session_urls_allow),
            sorted_vec(&entry.session_urls_block),
            sorted_vec(&entry.session_trust),
        )
    }

    pub fn session_clear(&self, uid: u32) {
        let mut state = self.state.lock().expect("trust_store poisoned");
        if let Some(entry) = state.get_mut(&uid) {
            entry.session_atoms.clear();
            entry.session_urls_allow.clear();
            entry.session_urls_block.clear();
            entry.session_trust.clear();
        }
    }

    /// Add a SHA-256 trust hash to the session set. Validates
    /// the hash shape (64 lowercase hex chars) to keep the set
    /// from filling with malformed strings. Per-UID cap protects
    /// against an unprivileged process spamming unique hashes to
    /// grow daemon memory unbounded — `[a]llow always` from a
    /// real banner is a once-per-prompt event, the cap is many
    /// thousands of multiples above any realistic operator pace.
    pub fn session_add_trust(&self, uid: u32, hash: &str) -> Result<(), String> {
        validate_trust_hash(hash)?;
        let mut state = self.state.lock().expect("trust_store poisoned");
        let entry = state.entry(uid).or_default();
        if entry.session_trust.len() >= SESSION_PER_KIND_CAP
            && !entry.session_trust.contains(hash)
        {
            return Err(format!(
                "session trust set full ({} entries) — run `sudo atty-guard session write` to persist + clear, or `atty-guard session clear`",
                SESSION_PER_KIND_CAP
            ));
        }
        entry.session_trust.insert(hash.to_owned());
        Ok(())
    }

    /// Mirror an atty-side `[B]lock host forever` keystroke into
    /// the per-UID session_urls_block set. atty proxy enforces
    /// locally; this is the visibility log. Per-UID cap (see
    /// `session_add_trust` for rationale).
    pub fn session_add_url_block(&self, uid: u32, host: &str) -> Result<(), String> {
        validate_host(host)?;
        let mut state = self.state.lock().expect("trust_store poisoned");
        let entry = state.entry(uid).or_default();
        if entry.session_urls_block.len() >= SESSION_PER_KIND_CAP
            && !entry.session_urls_block.contains(host)
        {
            return Err(format!(
                "session url-block set full ({} entries)",
                SESSION_PER_KIND_CAP
            ));
        }
        entry.session_urls_block.insert(host.to_owned());
        Ok(())
    }

    /// Daemon-side hot-path predicate: is `hash` in the caller's
    /// session trust set? Today no daemon code path calls this —
    /// the runtime check is atty-side. Kept as a hook for a future
    /// daemon-side defense-in-depth check, OR for PR #143's
    /// `commands.trusted.txt` persistence path.
    #[allow(dead_code)]
    pub fn is_session_trusted(&self, uid: u32, hash: &str) -> bool {
        let state = self.state.lock().expect("trust_store poisoned");
        state
            .get(&uid)
            .map(|e| e.session_trust.contains(hash))
            .unwrap_or(false)
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
        // GPT-review #024: serialize concurrent writers for this
        // UID so the RMW cycle on `atoms.user.txt` can't interleave
        // and lose updates.
        let lock = self.acquire_write_lock(uid);
        let _guard = lock.lock().expect("per-uid write lock poisoned");
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
        let lock = self.acquire_write_lock(uid);
        let _guard = lock.lock().expect("per-uid write lock poisoned");
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
        let lock = self.acquire_write_lock(uid);
        let _guard = lock.lock().expect("per-uid write lock poisoned");
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
        // GPT-review #024: serialize against concurrent
        // persistent_add_* + parallel session_write calls for the
        // same UID so the RMW cycles below can't interleave and
        // lose updates. Acquired BEFORE any file I/O.
        let lock = self.acquire_write_lock(uid);
        let _guard = lock.lock().expect("per-uid write lock poisoned");
        // Snapshot under the state lock, do file I/O outside the
        // critical section, then re-lock to clear the session ONLY
        // for entries we successfully persisted. Avoids holding the
        // global state mutex during fsync.
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

        // GPT-review #025: track which session entries we actually
        // persisted (or saw already-present on disk). Cleanup
        // retains everything NOT in these sets — including valid-
        // but-not-persisted entries (e.g. trust cap reached). The
        // prior shape removed all VALIDATING entries unconditionally,
        // which lost cap-blocked hashes from the session.
        let mut persisted_atoms: HashSet<String> = HashSet::new();
        let mut persisted_urls_allow: HashSet<String> = HashSet::new();
        let mut persisted_urls_block: HashSet<String> = HashSet::new();
        let mut persisted_trust: HashSet<String> = HashSet::new();

        let mut report = SessionWriteReport::default();

        if !sess_atoms.is_empty() {
            let path = self.user_atoms_path(uid);
            ensure_parent_dir(&path)?;
            let mut existing = read_atoms_file(&path)?;
            for atom in &sess_atoms {
                match validate_atom(atom) {
                    Ok(()) => {
                        if existing.insert(atom.clone()) {
                            report.atoms_added += 1;
                        }
                        // Already-present-on-disk counts as
                        // persisted for the cleanup pass — there's
                        // no work left to do for this entry.
                        persisted_atoms.insert(atom.clone());
                    }
                    Err(reason) => {
                        report.invalid.push((atom.clone(), reason));
                    }
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
                match validate_host(h) {
                    Ok(()) => {
                        block.remove(h);
                        if allow.insert(h.clone()) {
                            report.urls_allow_added += 1;
                        }
                        persisted_urls_allow.insert(h.clone());
                    }
                    Err(reason) => {
                        report.invalid.push((h.clone(), reason));
                    }
                }
            }
            for h in &sess_block {
                match validate_host(h) {
                    Ok(()) => {
                        allow.remove(h);
                        if block.insert(h.clone()) {
                            report.urls_block_added += 1;
                        }
                        persisted_urls_block.insert(h.clone());
                    }
                    Err(reason) => {
                        report.invalid.push((h.clone(), reason));
                    }
                }
            }
            if report.urls_allow_added > 0 || report.urls_block_added > 0 {
                write_urls_file(&path, &allow, &block)?;
            }
        }

        // Trust hashes go to commands.trusted.txt (post-#143
        // migration). Per-UID cap applies. Three outcomes:
        //  - malformed (validate fails)            → report.invalid
        //  - cap-full / persist-blocked            → report.not_persisted
        //                                            (GPT-review #025)
        //  - already-on-disk OR newly-inserted     → persisted_trust
        // The retain pass at the end keeps anything NOT in
        // persisted_trust — including not-persisted entries, so the
        // operator can retry after pruning commands.trusted.txt.
        let sess_trust = {
            let state = self.state.lock().expect("trust_store poisoned");
            state
                .get(&uid)
                .map(|e| e.session_trust.clone())
                .unwrap_or_default()
        };
        if !sess_trust.is_empty() {
            let path = self.user_trust_path(uid);
            ensure_parent_dir(&path)?;
            let mut existing = read_trust_file(&path)?;
            for h in &sess_trust {
                match validate_trust_hash(h) {
                    Ok(()) => {
                        if existing.contains(h) {
                            // Already persisted; nothing to do.
                            persisted_trust.insert(h.clone());
                        } else if existing.len() >= PERSISTENT_TRUST_CAP {
                            // Valid hash, but the on-disk file is
                            // full. Surface in `not_persisted` and
                            // INTENTIONALLY DO NOT add to
                            // `persisted_trust` so the cleanup pass
                            // keeps it in session for retry.
                            report.not_persisted.push((
                                h.clone(),
                                format!("trust file full ({PERSISTENT_TRUST_CAP})"),
                            ));
                        } else {
                            existing.insert(h.clone());
                            report.trust_added += 1;
                            persisted_trust.insert(h.clone());
                        }
                    }
                    Err(reason) => report.invalid.push((h.clone(), reason)),
                }
            }
            if report.trust_added > 0 {
                write_trust_file(&path, &existing)?;
            }
        }

        // Re-sync in-memory + cleanup: drop entries that we
        // actually persisted (or were already on disk). Everything
        // else stays in the session — malformed entries for
        // operator review, cap-blocked entries for retry. This is
        // the GPT-review #025 fix: prior shape removed ALL
        // validating entries, losing cap-blocked hashes.
        self.load_persistent(uid)?;
        {
            let mut state = self.state.lock().expect("trust_store poisoned");
            if let Some(entry) = state.get_mut(&uid) {
                entry
                    .session_atoms
                    .retain(|a| !persisted_atoms.contains(a));
                entry
                    .session_urls_allow
                    .retain(|h| !persisted_urls_allow.contains(h));
                entry
                    .session_urls_block
                    .retain(|h| !persisted_urls_block.contains(h));
                entry
                    .session_trust
                    .retain(|h| !persisted_trust.contains(h));
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
    fn user_trust_path(&self, uid: u32) -> PathBuf {
        self.data_root
            .join(uid.to_string())
            .join("commands.trusted.txt")
    }

    /// Append `hash` to the user's persistent trust file + reload
    /// the in-memory layer. Atomic write via tmp+rename. Validates
    /// the hash shape (64 lowercase hex chars). No sudo gate — this
    /// is the daemon-side analog of the banner's `[t]rust permanently`
    /// keystroke, which has always been a non-sudo action (since
    /// PR #1's atty-side trust_cache.txt write); per-UID file
    /// ownership stays sound because the connecting peer's UID
    /// scopes which file gets written.
    pub fn persistent_add_trust(&self, uid: u32, hash: &str) -> std::io::Result<()> {
        validate_trust_hash(hash)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidInput, e))?;
        let lock = self.acquire_write_lock(uid);
        let _guard = lock.lock().expect("per-uid write lock poisoned");
        let path = self.user_trust_path(uid);
        ensure_parent_dir(&path)?;
        let mut existing = read_trust_file(&path)?;
        if existing.contains(hash) {
            return Ok(()); // idempotent
        }
        if existing.len() >= PERSISTENT_TRUST_CAP {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                format!(
                    "persistent trust file full ({PERSISTENT_TRUST_CAP} entries) \
                     — `atty-guard atoms remove` won't help (different file); \
                     edit `commands.trusted.txt` directly to prune",
                ),
            ));
        }
        existing.insert(hash.to_owned());
        write_trust_file(&path, &existing)?;
        self.load_persistent(uid)?;
        Ok(())
    }

    /// Snapshot of the caller's persistent trust hashes. atty
    /// proxy fetches this at module attach to seed its local
    /// runtime trust set, so subsequent banner-armed paths can
    /// short-circuit without an extra UDS round-trip. The daemon
    /// itself does NOT consult trust at classify time — atty is
    /// authoritative for the runtime check (its in-proc trust set
    /// fires BEFORE the daemon's Classify dispatch ever sees the
    /// command).
    pub fn list_persistent_trust(&self, uid: u32) -> Vec<String> {
        let state = self.state.lock().expect("trust_store poisoned");
        let entry = match state.get(&uid) {
            Some(e) => e,
            None => return Vec::new(),
        };
        sorted_vec(&entry.persistent_trust)
    }
}

#[derive(Debug, Default, Clone)]
pub struct SessionWriteReport {
    pub atoms_added: usize,
    pub urls_allow_added: usize,
    pub urls_block_added: usize,
    pub trust_added: usize,
    /// Entries that failed VALIDATION (malformed atom / bad hash
    /// shape / etc) and stayed in the session for the operator to
    /// review/correct. Each `(entry, reason)` pair surfaces in the
    /// CLI's `session write` output and via `session list` until
    /// the operator deletes or fixes them.
    pub invalid: Vec<(String, String)>,
    /// GPT-review #025: entries that PASSED validation but could
    /// not be persisted right now (typical reason: trust file at
    /// cap; possible future reasons: disk full, ENOSPC during
    /// `write_atomic`'s rename). These stay in the session for
    /// retry after the operator prunes whatever blocked the write.
    /// Kept separate from `invalid` so CLI output can distinguish
    /// "fix the entry" from "fix the destination."
    pub not_persisted: Vec<(String, String)>,
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

/// Per-UID cap on each kind of session entry (atoms, urls-allow,
/// urls-block, trust hashes). Defends against an unprivileged
/// caller spamming the no-sudo session RPCs to grow daemon memory
/// unbounded. Real banner-driven taps are at most one-per-prompt,
/// so the cap is many thousands of multiples above any realistic
/// operator pace; hitting it means something's wrong + the
/// operator should `session write` or `session clear`.
const SESSION_PER_KIND_CAP: usize = 4096;

/// Per-UID cap on persistent trust hashes (`commands.trusted.txt`).
/// Larger than the session cap because trust hashes ARE intended to
/// accumulate over the lifetime of a user account — every `[t]rust
/// permanently` keystroke at the banner adds one. 16K is roughly
/// "decades of routine use before any operator hits it"; if you
/// do hit it, you have a different problem (likely the same atom
/// firing on slightly-different commands → cache mostly garbage).
const PERSISTENT_TRUST_CAP: usize = 16384;

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
    // ` #` is reserved as the inline-metadata delimiter in the
    // on-disk format. An atom containing this substring would be
    // silently truncated on the next file load. Reject upfront so
    // operators see a clear error at `atoms add` time, not silent
    // data loss later. (Atoms starting at column 0 with `#` are
    // also rejected by this check via the leading whitespace
    // check below — the canonical Sigma/GTFOBins shape never
    // starts with `#`.)
    if atom.contains(" #") || atom.starts_with('#') {
        return Err("atom contains ` #` (reserved as the inline-metadata delimiter)".into());
    }
    // The atom-fetcher's placeholder check applies to user atoms
    // too — adding `/path/to/foo` or `<user>` as an atom would
    // never match real input (Aho-Corasick has no wildcards).
    if is_placeholder_atom_public(atom) {
        return Err(
            "atom looks like a Sigma/LOLBAS-style placeholder \
             (`/path/to/...`, `{PATH:...}`, or `<identifier>`) — \
             these match no real input"
                .into(),
        );
    }
    Ok(())
}

fn validate_trust_hash(hash: &str) -> Result<(), String> {
    // SHA-256 in lowercase hex = exactly 64 chars `[0-9a-f]`. Keeps
    // the session_trust set from collecting bogus uppercase /
    // truncated values that would never match a real hash on
    // dispatch. The shape is fixed atty-side in
    // security_guard/trust_cache.zig::hashCategoryMatch.
    if hash.len() != 64 {
        return Err(format!("trust hash length {} (expected 64)", hash.len()));
    }
    if !hash.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) {
        return Err("trust hash contains non-lowercase-hex chars".into());
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
    // Same ` #` reservation as validate_atom — keeps the file
    // format parser/writer pair lossless on the canonical input.
    if host.contains('#') {
        return Err("host contains `#` (reserved character)".into());
    }
    Ok(())
}

/// Read `atoms.system.txt` from disk with a permission gate. The
/// daemon writes this file as the `atty` user, so on load we
/// require: (a) owner == our own EUID (i.e. atty's UID), and (b)
/// no group-write or world-write bit set. Drift in either fails
/// the load and the caller keeps whatever in-memory state it had.
///
/// Why this gate: the system corpus feeds the V2-J accumulator,
/// which can escalate Safe → Block, which the daemon writes to
/// the eBPF threat-map. A poisoned corpus is a kernel-level DOS
/// vector — bytes in this file affect every user's classify
/// outcome. Refusing-on-drift is the conservative choice.
fn read_system_atoms_file_checked(path: &Path) -> std::io::Result<HashSet<String>> {
    let mut out = HashSet::new();
    let meta = match std::fs::metadata(path) {
        Ok(m) => m,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(out),
        Err(e) => return Err(e),
    };
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        use std::os::unix::fs::PermissionsExt;
        // Owner must be our own EUID — the daemon is supposed to
        // be the sole writer, and "owner == self" is the
        // strongest precondition for that. Using `geteuid()` from
        // libc avoids a dependency on the `users` crate just for
        // this one syscall.
        let our_uid = unsafe {
            extern "C" {
                fn geteuid() -> u32;
            }
            geteuid()
        };
        if meta.uid() != our_uid {
            return Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                format!(
                    "refusing to load {}: owner uid {} != daemon uid {} \
                     (daemon-managed corpus must stay daemon-owned; \
                     `sudo chown atty:atty {}` if you trust the current contents)",
                    path.display(),
                    meta.uid(),
                    our_uid,
                    path.display(),
                ),
            ));
        }
        let mode = meta.permissions().mode() & 0o777;
        // Reject group-write OR world-write. Read bits are OK
        // (group=atty needs to stat the file for `atty doctor`).
        if mode & 0o022 != 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                format!(
                    "refusing to load {}: mode 0{:o} has group/world-write \
                     (chmod g-w,o-w {})",
                    path.display(),
                    mode,
                    path.display(),
                ),
            ));
        }
    }
    let content = std::fs::read_to_string(path)?;
    for line in content.lines() {
        let body = strip_inline_comment(line).trim();
        if !body.is_empty() {
            out.insert(body.to_owned());
        }
    }
    Ok(out)
}

fn read_trust_file(path: &Path) -> std::io::Result<HashSet<String>> {
    let mut out = HashSet::new();
    if !path.exists() {
        return Ok(out);
    }
    let content = std::fs::read_to_string(path)?;
    for line in content.lines() {
        // Trust lines are bare 64-char hex; strip inline metadata
        // first (same convention as atoms.user.txt).
        let body = strip_inline_comment(line).trim();
        if body.is_empty() {
            continue;
        }
        // Silently skip malformed lines instead of erroring — a
        // hand-edited file with one bad line shouldn't lock the
        // operator out of the rest of their trust state.
        if validate_trust_hash(body).is_ok() {
            out.insert(body.to_owned());
        }
    }
    Ok(out)
}

fn write_trust_file(path: &Path, hashes: &HashSet<String>) -> std::io::Result<()> {
    let mut sorted: Vec<&String> = hashes.iter().collect();
    sorted.sort();
    let mut content = String::with_capacity(64 + hashes.len() * 80);
    content.push_str("# atty-guard persistent trust file. Each line is a SHA-256\n");
    content.push_str("# hex digest of `<category>:<matched>` — see\n");
    content.push_str("# atty's `src/modules/security_guard/trust_cache.zig::hashCategoryMatch`.\n");
    content.push_str("# Edit by hand to prune entries. New writes go through\n");
    content.push_str("# `atty-guard trust add <hash>` or the banner's [t]rust\n");
    content.push_str("# permanently keystroke.\n");
    content.push_str("\n");
    let stamp = utc_timestamp_ymd();
    for h in &sorted {
        content.push_str(&format!("{h} # set {stamp}\n"));
    }
    write_atomic(path, content.as_bytes())
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

/// Monotonic counter used to uniquify temp filenames across
/// concurrent `write_atomic` calls in the same process. The prior
/// shape used only PID — fine across processes, but two daemon
/// threads writing to the same target file collided on the SAME
/// `<file>.tmp.<pid>` path and could overwrite each other's temp
/// content before either rename (GPT-review #024).
static WRITE_ATOMIC_COUNTER: AtomicU64 = AtomicU64::new(0);

fn write_atomic(path: &Path, content: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let pid = std::process::id();
    let seq = WRITE_ATOMIC_COUNTER.fetch_add(1, Ordering::Relaxed);
    let tmp = path.with_file_name(format!(
        "{}.tmp.{}.{}",
        path.file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("trust_store_tmp"),
        pid,
        seq,
    ));
    // `create_new(true)` is the real guard here. It refuses to:
    //   - follow an attacker-pre-created symlink at the tmp path,
    //   - clobber a stale `<file>.tmp.<pid>.<seq>` left by a
    //     crashed prior daemon if the OS happens to recycle our
    //     PID into a new daemon process (Linux pid_max is bounded;
    //     wrap is rare but possible after long uptime).
    // The per-process counter advances every call so two threads
    // in the SAME daemon process can't pick the same `<seq>`.
    // The combination (PID + per-process counter + create_new) is
    // collision-proof from atty-guard's side; the only remaining
    // window is the PID-recycle case above, which create_new
    // surfaces as a hard EEXIST instead of silent data loss.
    {
        let mut opts = std::fs::OpenOptions::new();
        opts.write(true).create_new(true);
        // Create the tmp at the final 0640 from the start (umask can
        // only tighten this), so it never carries broader-than-0640
        // perms — e.g. other-readable — while we write the content. The
        // explicit set_permissions below then guarantees the exact 0640
        // even if umask stripped the group-read bit here.
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            opts.mode(0o640);
        }
        let mut f = opts.open(&tmp)?;
        if let Err(e) = f.write_all(content) {
            // Best-effort cleanup; if the write half-failed we
            // shouldn't leave the tmp behind for the next caller
            // to wonder about.
            let _ = std::fs::remove_file(&tmp);
            return Err(e);
        }
        // Mode 0640: owner (atty) rw, group (atty) r, others nothing.
        // Group `atty` includes the user accounts that talk to the
        // daemon — they can READ the persisted decisions via the
        // daemon, but the file itself is also stat()'able by them.
        // Set it on the tmp BEFORE the rename so the published file is
        // 0640 the instant it appears: no post-rename window where it
        // carries looser perms, and no dependence on umask having left
        // the group-read bit set.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if let Err(e) = f.set_permissions(std::fs::Permissions::from_mode(0o640)) {
                let _ = std::fs::remove_file(&tmp);
                return Err(e);
            }
        }
        // fsync the content + metadata before the rename. Without this,
        // a crash or power loss after the rename can publish an empty or
        // truncated file — the rename would point at bytes the kernel
        // hadn't flushed — silently dropping operator-added detections
        // (a fail-open for the user-atom layer).
        if let Err(e) = f.sync_all() {
            let _ = std::fs::remove_file(&tmp);
            return Err(e);
        }
    }
    if let Err(e) = std::fs::rename(&tmp, path) {
        let _ = std::fs::remove_file(&tmp);
        return Err(e);
    }
    // fsync the parent directory so the rename itself (the directory
    // entry swap) is durable. The content sync above guarantees the
    // bytes survive a crash; this guarantees the new name does too,
    // rather than reverting to the old file. Best-effort: the write has
    // already succeeded, so a parent that can't be opened/synced (rare)
    // isn't worth failing the whole operation over.
    #[cfg(unix)]
    {
        if let Some(parent) = path.parent() {
            if let Ok(dir) = std::fs::File::open(parent) {
                let _ = dir.sync_all();
            }
        }
    }
    Ok(())
}

/// Scan per-UID dirs under `data_root` and unlink any `*.tmp.*`
/// files. Called once at TrustStore::new — these are stale `write_atomic`
/// scratch files from a crashed prior daemon. Linux PID reuse can
/// otherwise collide a recycled PID's first write with a stale tmp
/// name, hard-erroring on `create_new(true)`.
///
/// Best-effort, never blocks startup. The top-level `read_dir` and
/// individual `unlink` failures log to journald. Per-UID `read_dir`
/// failures + DirEntry iteration errors via `flatten()` are
/// silently dropped — they're typically transient permission
/// glitches that the daemon's own write path will surface again
/// at first use; logging them at startup would be noise.
fn sweep_stale_tmp_files(data_root: &Path) {
    let entries = match std::fs::read_dir(data_root) {
        Ok(e) => e,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return,
        Err(e) => {
            eprintln!(
                "atty-guard: tmp-sweep — read_dir({}) failed: {e}",
                data_root.display()
            );
            return;
        }
    };
    let mut swept: u32 = 0;
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        // Per-UID dir. Walk one level deeper and unlink any file
        // whose name contains ".tmp." — the write_atomic suffix
        // shape is `<file>.tmp.<pid>.<seq>`.
        let sub = match std::fs::read_dir(&path) {
            Ok(s) => s,
            Err(_) => continue,
        };
        for f in sub.flatten() {
            let fname = f.file_name();
            let s = match fname.to_str() {
                Some(s) => s,
                None => continue,
            };
            if !s.contains(".tmp.") {
                continue;
            }
            let p = f.path();
            match std::fs::remove_file(&p) {
                Ok(_) => swept += 1,
                Err(e) => eprintln!(
                    "atty-guard: tmp-sweep — unlink({}) failed: {e}",
                    p.display()
                ),
            }
        }
    }
    if swept > 0 {
        eprintln!(
            "atty-guard: tmp-sweep — removed {swept} stale write_atomic tmp file(s) under {}",
            data_root.display()
        );
    }
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
