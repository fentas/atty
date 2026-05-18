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
    Health {
        version: String,
    },
    Classify(ClassifyResult),
    ThreatLevel {
        level: ThreatLevel,
    },
    Error {
        message: String,
    },
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Envelope<T> {
    pub id: u64,
    #[serde(flatten)]
    pub body: T,
}
