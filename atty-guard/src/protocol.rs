//! JSON-line RPC protocol over the UDS.
//!
//! One JSON object per line, framed by `\n`. Each Request carries a
//! `id` echoed back in the Response so a pipelined client can match
//! replies. No streaming RPCs in V2-A — the ringbuf subscription
//! lands in V2-B.

use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(tag = "method", rename_all = "snake_case")]
pub enum Request {
    /// Health probe. Always replies `{ verdict: "Safe", confidence: 1.0 }`.
    /// Useful for atty to detect "is the daemon up?" without burning
    /// classifier work.
    Health,

    /// Classify a typed command line. Returns the verdict + the
    /// matched category (when Tier-1 fires) + a confidence score.
    Classify {
        /// The user's typed line BEFORE the shell receives it.
        command: String,
        /// Best-effort context — atty fills these when available.
        #[serde(default)]
        context: ClassifyContext,
    },

    /// Mark a PID (and, by intent, its child tree) as high-risk.
    /// In V2-A this is in-memory only; V2-B will mirror to the eBPF
    /// hash map.
    SetThreatLevel { pid: u32, level: ThreatLevel },

    /// Read back the current threat level for a PID. Returns
    /// `ThreatLevel::Low` for unmapped PIDs.
    GetThreatLevel { pid: u32 },

    // --- Mediated trust-state mutations (PR #141) ---
    //
    // All "mutating" variants below require the connecting client to
    // have EUID 0 (verified by daemon via SO_PEERCRED at accept).
    // Read-only variants are open to any client. The CLI subcommands
    // in atty-guard's main.rs (`atoms`, `urls`, `session`) drive
    // these and surface a friendly error when sudo is missing.
    //
    // Session state is keyed by the connecting client's UID (also via
    // SO_PEERCRED). The same user's multiple atty proxies share one
    // session; CLI invocations from the same user see + manipulate
    // that state. `session write` then persists into per-UID files
    // under /var/lib/atty-guard/users/<uid>/.
    /// Append `pattern` to the persistent atoms.user.txt for the
    /// caller's UID. Daemon validates length, rejects placeholder-
    /// shaped atoms (see atom_fetcher::is_placeholder_atom), and
    /// reloads its matcher. Requires EUID 0 client.
    AtomsAdd { pattern: String },
    /// Remove `pattern` from atoms.user.txt for the caller's UID.
    /// Requires EUID 0 client.
    AtomsRemove { pattern: String },
    /// List atoms in scope `system` (always-on bundled set),
    /// `user` (per-UID overlay), or `session` (ephemeral in-memory).
    /// No privilege check.
    AtomsList { scope: AtomScope },

    /// Append `host` to the persistent urls.decisions.txt for the
    /// caller's UID as an "allow" decision. EUID 0 required.
    UrlsAllow { host: String },
    /// Same shape but records "block". EUID 0 required.
    UrlsBlock { host: String },
    /// List recorded URL decisions for the caller's UID + the
    /// in-memory session overlay (combined for the read path).
    /// No privilege check.
    UrlsList,

    /// Read the caller's in-memory session-state pending decisions
    /// (atoms-allow, urls-allow, urls-block) — anything added via
    /// the atty proxy's `[A]llow always` / `[B]lock host forever`
    /// inline prompts in this session. Empty for a fresh login.
    SessionList,
    /// Drop the caller's in-memory session state (does not touch
    /// any persistent file). Useful when the operator wants to
    /// revisit decisions without committing them.
    SessionClear,
    /// Persist the caller's in-memory session state into the
    /// per-UID atoms.user.txt + urls.decisions.txt files. The
    /// session is then cleared. Requires EUID 0 client because
    /// the target files live under /var/lib/atty-guard/ and are
    /// `atty:atty 0640` — only root (or atty itself) can write.
    SessionWrite,
}

/// Scope selector for `AtomsList`. The matcher serves the union of
/// all three at classification time; this lets the operator see
/// where any given atom came from (debugging an unexpected hit).
#[derive(Debug, Serialize, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AtomScope {
    /// Compile-time bundled corpus from
    /// `src/modules/security_guard/data/flagged_atoms.txt`. Read-only;
    /// hand-curated by atty maintainers + refreshed pre-release.
    System,
    /// Per-UID `atoms.user.txt`. Mutated via `atoms add/remove` or
    /// `session write`. Persisted to /var/lib/atty-guard/users/<uid>/.
    User,
    /// In-memory daemon session state for the caller's UID.
    /// Ephemeral; survives only until daemon restart OR `session clear`
    /// / `session write`.
    Session,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct ClassifyContext {
    /// PID atty assigns to the source shell, if known. Lets the
    /// classifier upgrade verdicts on a high-threat PID without atty
    /// having to query first.
    #[serde(default)]
    pub pid: Option<u32>,

    /// User's shell name (`bash`/`zsh`/…). Some patterns are
    /// shell-specific.
    #[serde(default)]
    pub shell: Option<String>,

    /// Whether the user is in atty's incognito mode. Daemon may
    /// choose to skip persistence / logging for incognito traffic.
    #[serde(default)]
    pub incognito: bool,
}

#[derive(Debug, Serialize, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ThreatLevel {
    /// Default — no signal.
    Low,
    /// PTY proxy decided "watch this PID's tree more carefully".
    /// In V2-B this maps to "sync inspection mode in the kernel
    /// LSM hook".
    High,
    /// Hard refuse — kernel should EPERM on execve in V2-B.
    Critical,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(rename_all = "snake_case")]
pub enum Verdict {
    /// Low-risk; allow.
    Safe,
    /// Tier-1 or Tier-2 flagged the command. Caller (atty) prompts
    /// the user.
    Warn,
    /// Hard block; caller should refuse the command outright.
    Block,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(rename_all = "snake_case")]
pub enum Category {
    None,
    CurlPipeSh,
    NpmUnsafeInstall,
    BashCBase64,
    PidHighThreat,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ClassifyResult {
    pub verdict: Verdict,
    pub category: Category,
    /// Confidence in `[0.0, 1.0]`. Tier-1 hits are 1.0; Tier-2 SLM
    /// returns its softmax score.
    pub confidence: f32,
    /// Human-facing one-line reason for surfacing in atty's banner.
    /// Bounded to 256 bytes — anything longer gets truncated.
    pub reason: String,
    /// The substring that matched (for atty's trust cache hash).
    /// Empty when no match.
    pub matched: String,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ResponseBody {
    Ok,
    Health { version: String },
    Classify(ClassifyResult),
    ThreatLevel { level: ThreatLevel },
    Error { message: String },
    /// Reply to AtomsList. Each entry is the atom string verbatim
    /// (no metadata) — CLI renders them one per line.
    AtomsList { atoms: Vec<String> },
    /// Reply to UrlsList. Pairs of (host, decision) where decision
    /// is `"allow"`, `"block"`, or `"session-allow"` /
    /// `"session-block"` for entries that are session-only.
    UrlsList { entries: Vec<UrlDecisionEntry> },
    /// Reply to SessionList. Lists pending atoms/url-decisions held
    /// in the caller's in-memory session.
    SessionList {
        atoms: Vec<String>,
        urls_allow: Vec<String>,
        urls_block: Vec<String>,
    },
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct UrlDecisionEntry {
    pub host: String,
    /// `"allow"` / `"block"` (persistent) or `"session-allow"` /
    /// `"session-block"` (in-memory only).
    pub decision: String,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Envelope<T> {
    pub id: u64,
    #[serde(flatten)]
    pub body: T,
}
