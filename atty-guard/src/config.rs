//! TOML config loader for atty-guard. Loaded once at startup via
//! `--config <path>`. All fields are optional — CLI flags +
//! compiled-in defaults fill in anything the file doesn't set.
//!
//! Lives in its own module so callers (main.rs) get a typed view
//! of the config; the rest of the daemon never touches the raw
//! `toml` parser.

use crate::profile::SecurityProfile;
use serde::Deserialize;
use std::path::Path;

#[derive(Debug, Default, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    #[serde(default)]
    pub tier2: Tier2Config,
    /// V2-J Phase 2: accumulator tuning. Empty by default —
    /// every knob has a conservative compiled-in fallback.
    #[serde(default)]
    pub accumulator: AccumulatorConfig,
    /// Server-side resource caps. Defaults are documented on
    /// each field; the [server] table is optional in the file
    /// and falls back to safe values when omitted.
    #[serde(default)]
    pub server: ServerConfig,
    /// eBPF kernel enforcement depth (block mode). Optional; the
    /// `--enforcement-depth` CLI flag wins when set, otherwise this
    /// table, otherwise one_level. Only meaningful on `ebpf` builds
    /// running `--ebpf-mode=block`.
    #[serde(default)]
    pub enforcement: EnforcementConfig,
    /// Security posture for non-proxy execs in the atty-session subtree.
    /// Optional; defaults to `prompt` (the historical tripwire). See
    /// docs/security-profiles.md for the ladder + the `smart` router.
    #[serde(default)]
    pub profile: ProfileConfig,
}

/// `[profile]` table — the security posture + its consent knobs.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProfileConfig {
    /// `prompt` | `audit` | `session` | `strict` | `lockdown` | `smart`.
    #[serde(default)]
    pub mode: SecurityProfile,
    /// Allow `smart` to escalate to lockdown-grade (SIGSTOP
    /// freeze-and-frisk) for risky-ambiguous execs. Off by default —
    /// `smart` never exceeds the operator's consented ceiling, so without
    /// this it tops out at async-kill.
    #[serde(default)]
    pub smart_allow_lockdown: bool,
    /// Binary PATHS `strict` synchronously blocks (-EPERM) in a watched
    /// subtree, BEFORE the exec runs (Phase 3 "A"). Populated into the
    /// kernel deny-map on startup when `mode = "strict"`; ignored by other
    /// profiles. Full ABSOLUTE paths, e.g. `["/usr/bin/nc"]` — matched
    /// against the kernel's literal exec path (`bprm->filename`, exact
    /// string), so a bare `nc` or a symlink to the target won't match (A+
    /// adds basename matching). The full Tier-1 command patterns stay on
    /// `session`'s reactive path (see docs/security-profiles.md).
    #[serde(default)]
    pub deny_binaries: Vec<String>,
}

/// How far the eBPF LSM hook looks for a Critical mark on each execve.
/// See `docs/benchmarking.md` for the per-mode coverage/cost trade-off.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EnforcementConfig {
    /// `one_level` (direct children of a marked PID — the historical
    /// default) / `ancestry` (bounded ancestor walk) / `propagate_on_fork`
    /// (mark copied onto every fork child; covers double-fork/daemonize).
    /// Validated at startup — an unrecognized value fails the load.
    #[serde(default = "default_enforcement_depth")]
    pub depth: String,
    /// Ancestor-walk ceiling when `depth = "ancestry"`. The kernel walks
    /// at most its compiled MAX_ANCESTRY (16) hops, so a larger value
    /// just caps there; 0 disables the walk (never matches), so keep it
    /// ≥ 1.
    #[serde(default = "default_ancestry_max_depth")]
    pub max_depth: u8,
}

fn default_enforcement_depth() -> String {
    "one_level".into()
}
fn default_ancestry_max_depth() -> u8 {
    8
}

impl Default for EnforcementConfig {
    fn default() -> Self {
        EnforcementConfig {
            depth: default_enforcement_depth(),
            max_depth: default_ancestry_max_depth(),
        }
    }
}

/// Map a `depth` string to the byte the kernel `enforce_cfg` map
/// expects, or `None` for an unrecognized value (caller fails closed).
/// Byte values must match the `ENFORCE_*` defines in
/// `atty-guard/ebpf/atty_guard.bpf.c`.
pub fn depth_mode_byte(depth: &str) -> Option<u8> {
    match depth {
        "one_level" => Some(0),
        "ancestry" => Some(1),
        "propagate_on_fork" => Some(2),
        _ => None,
    }
}

/// Bounded-resources knobs for the UDS server. The socket is
/// group-accessible (atty group on system installs); without
/// these caps a buggy / hostile local process could exhaust
/// daemon resources by opening many idle connections.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ServerConfig {
    /// Maximum concurrent connections accepted at one time.
    /// Reached → new connections are accepted-then-closed
    /// immediately so the client sees a fast EOF rather than
    /// queuing indefinitely. Default 64 — generous for typical
    /// single-user use (one shell × handful of classify calls
    /// in flight) and tight enough that a runaway client can't
    /// peg the daemon. Values above a few hundred meaningfully
    /// weaken the DoS bound; values of 0 are clamped to 1 at
    /// startup with a stderr warning.
    #[serde(default = "default_max_concurrent_connections")]
    pub max_concurrent_connections: usize,
    /// Per-connection read timeout in seconds. An idle client
    /// holding a connection without sending any bytes is
    /// disconnected after this many seconds. Default 30 —
    /// well past a healthy classify round-trip (sub-millisecond
    /// to single-digit milliseconds) and short enough that a
    /// silent client can't squat on a handler thread forever.
    /// Set to 0 to disable.
    #[serde(default = "default_idle_read_timeout_secs")]
    pub idle_read_timeout_secs: u64,
}

fn default_max_concurrent_connections() -> usize {
    64
}
fn default_idle_read_timeout_secs() -> u64 {
    30
}

impl Default for ServerConfig {
    fn default() -> Self {
        ServerConfig {
            max_concurrent_connections: default_max_concurrent_connections(),
            idle_read_timeout_secs: default_idle_read_timeout_secs(),
        }
    }
}

#[derive(Debug, Default, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AccumulatorConfig {
    /// V2-J Phase 2: auto-`Block` threshold. When the combined
    /// confidence of multiple Tier-1 + Tier-2 signals reaches
    /// this value AND at least 2 distinct signals fired, the
    /// classifier escalates the verdict from `Warn` to `Block`.
    /// `Block` means atty refuses the command outright instead
    /// of prompting the user, so this is a load-bearing policy
    /// knob — default `None` keeps the conservative "always
    /// prompt" behaviour.
    ///
    /// Recommended values when opting in:
    /// - `0.95`: requires ≥ 5 atoms OR an atom + a high-conf
    ///   regex/SLM signal. Low false-positive risk; some legit
    ///   scripted runs may still trip and get refused.
    /// - `0.99`: practically needs 8+ atoms or multiple high-
    ///   confidence rules. Very low false-positive risk; only
    ///   the most signal-saturated commands auto-block.
    ///
    /// The minimum-hit-count guard (≥ 2 distinct signals) is
    /// non-configurable — a single regex hit at 1.0 confidence
    /// always stays a `Warn`, because we want users to retain
    /// the [y]/[t]/cancel choice for unambiguous-but-legitimate
    /// shapes like `curl … | sh` (the canonical install-script
    /// pattern).
    ///
    /// Validation happens at classifier construction, not here:
    /// `Classifier::with_block_threshold` accepts only
    /// `(WARN_THRESHOLD, 1.0]`, finite. Out-of-range values
    /// degrade to `None` with a stderr warning at daemon start
    /// — TOML deserialization itself only enforces "must be a
    /// number," so e.g. `block_threshold = 2.0` parses fine and
    /// is then rejected at runtime.
    #[serde(default)]
    pub block_threshold: Option<f32>,
}

#[derive(Debug, Default, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Tier2Config {
    /// `stub` / `heuristic` / `onnx`. CLI `--tier2` wins when set;
    /// otherwise this field is honored; otherwise the default is
    /// `stub`. Validated at startup — an invalid value here fails
    /// the daemon load (matches the explicit-config posture from
    /// `--config`).
    #[serde(default)]
    pub backend: Option<String>,

    /// Sub-table populated only when backend = "onnx". Keeping
    /// the ONNX-specific knobs nested keeps `[tier2]` tidy for
    /// future backends (`[tier2.transformer]`, `[tier2.tract]`
    /// etc.).
    #[serde(default)]
    pub onnx: OnnxConfig,
}

#[derive(Debug, Clone, Deserialize)]
// Fields are only read by the ONNX backend; the struct itself is
// parsed in every build so config validation is consistent across
// feature flavors.
#[cfg_attr(not(feature = "tier2-onnx"), allow(dead_code))]
#[serde(deny_unknown_fields)]
pub struct OnnxConfig {
    /// Model selector — defaults to `securebert2` because it's
    /// the smaller, faster option for the same Tier-2 verdict
    /// quality (per Gemini's review). `qwen-coder` swaps to the
    /// code-native classifier when the user has already curated
    /// a Qwen2.5-Coder-INT8 fine-tune.
    #[serde(default = "default_model")]
    pub model: String,

    /// Absolute path to the ONNX file. Empty = backend reports
    /// "model not configured" at attach time; daemon falls back
    /// to Heuristic + warns.
    #[serde(default)]
    pub model_path: String,

    /// Absolute path to the HuggingFace `tokenizer.json`.
    #[serde(default)]
    pub tokenizer_path: String,

    /// Max input tokens. SecureBERT 2.0 (ModernBERT base) handles
    /// 1024 natively; Qwen2.5-Coder handles 4096+. Longer
    /// commands are truncated at the LEFT (the right side is
    /// typically the payload).
    #[serde(default = "default_max_tokens")]
    pub max_tokens: usize,

    /// Softmax threshold above which we issue a Warn verdict.
    /// Tier-2 reports Safe when below this; Warn between this
    /// and `block_threshold`; Block above. Tune per model
    /// calibration.
    #[serde(default = "default_warn_threshold")]
    pub warn_threshold: f32,

    /// Softmax threshold for Block. Should be ≥ warn_threshold.
    #[serde(default = "default_block_threshold")]
    pub block_threshold: f32,
}

impl Default for OnnxConfig {
    fn default() -> Self {
        Self {
            model: default_model(),
            model_path: String::new(),
            tokenizer_path: String::new(),
            max_tokens: default_max_tokens(),
            warn_threshold: default_warn_threshold(),
            block_threshold: default_block_threshold(),
        }
    }
}

fn default_model() -> String {
    "securebert2".into()
}
fn default_max_tokens() -> usize {
    1024
}
fn default_warn_threshold() -> f32 {
    0.5
}
fn default_block_threshold() -> f32 {
    0.85
}

#[derive(Debug)]
pub enum LoadError {
    Io(std::io::Error),
    Parse(String),
}

impl std::fmt::Display for LoadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LoadError::Io(e) => write!(f, "config read failed: {e}"),
            LoadError::Parse(e) => write!(f, "config parse failed: {e}"),
        }
    }
}

impl std::error::Error for LoadError {}

/// Hard cap on config file size. Real-world atty-guard configs
/// are <4 KiB; the cap defends against `--config` pointing at
/// /dev/urandom, a fifo, or a misplaced large file that would
/// OOM the daemon under an unbounded `read_to_string`.
const MAX_CONFIG_BYTES: u64 = 1024 * 1024;

/// Parse a TOML config file. Always fails closed so an explicit
/// `--config` never silently degrades to defaults:
///   - missing / unreadable path → `LoadError::Io`
///   - non-regular file (fifo, directory, char/block device) →
///     `LoadError::Io` with EINVAL — refuses to read from
///     anything that could block or OOM us
///   - file > `MAX_CONFIG_BYTES` → `LoadError::Io` with
///     `FileTooLarge`
///   - malformed TOML → `LoadError::Parse`
pub fn load(path: &Path) -> Result<Config, LoadError> {
    let meta = std::fs::metadata(path).map_err(LoadError::Io)?;
    if !meta.is_file() {
        return Err(LoadError::Io(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!(
                "{} is not a regular file (refusing to read from fifo/dir/device)",
                path.display()
            ),
        )));
    }
    if meta.len() > MAX_CONFIG_BYTES {
        return Err(LoadError::Io(std::io::Error::new(
            std::io::ErrorKind::FileTooLarge,
            format!(
                "{} is {} bytes (cap is {})",
                path.display(),
                meta.len(),
                MAX_CONFIG_BYTES,
            ),
        )));
    }
    let text = std::fs::read_to_string(path).map_err(LoadError::Io)?;
    toml::from_str(&text).map_err(|e| LoadError::Parse(e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_complete_tier2_onnx_block() {
        let src = r#"
[tier2]
backend = "onnx"

[tier2.onnx]
model = "qwen-coder"
model_path = "/var/lib/atty-guard/qwen.onnx"
tokenizer_path = "/var/lib/atty-guard/qwen-tokenizer.json"
max_tokens = 4096
warn_threshold = 0.45
block_threshold = 0.9
"#;
        let cfg: Config = toml::from_str(src).unwrap();
        assert_eq!(cfg.tier2.backend.as_deref(), Some("onnx"));
        assert_eq!(cfg.tier2.onnx.model, "qwen-coder");
        assert_eq!(cfg.tier2.onnx.max_tokens, 4096);
        assert!((cfg.tier2.onnx.block_threshold - 0.9).abs() < 1e-6);
    }

    #[test]
    fn empty_config_yields_defaults() {
        let cfg: Config = toml::from_str("").unwrap();
        assert_eq!(cfg.tier2.onnx.model, "securebert2");
        assert_eq!(cfg.tier2.onnx.max_tokens, 1024);
    }

    #[test]
    fn parses_enforcement_table() {
        let src = r#"
[enforcement]
depth = "propagate_on_fork"
max_depth = 12
"#;
        let cfg: Config = toml::from_str(src).unwrap();
        assert_eq!(cfg.enforcement.depth, "propagate_on_fork");
        assert_eq!(cfg.enforcement.max_depth, 12);
    }

    #[test]
    fn enforcement_defaults_to_one_level() {
        let cfg: Config = toml::from_str("").unwrap();
        assert_eq!(cfg.enforcement.depth, "one_level");
        assert_eq!(cfg.enforcement.max_depth, 8);
    }

    #[test]
    fn depth_mode_byte_maps_all_modes_and_rejects_garbage() {
        assert_eq!(depth_mode_byte("one_level"), Some(0));
        assert_eq!(depth_mode_byte("ancestry"), Some(1));
        assert_eq!(depth_mode_byte("propagate_on_fork"), Some(2));
        assert_eq!(depth_mode_byte("nonsense"), None);
    }

    #[test]
    fn load_rejects_unknown_key_in_enforcement_table() {
        let mut tmp = tempfile::NamedTempFile::new().unwrap();
        use std::io::Write as _;
        tmp.write_all(b"[enforcement]\ndeapth = \"ancestry\"\n")
            .unwrap();
        let err = load(tmp.path()).expect_err("unknown enforcement field must fail");
        assert!(matches!(err, LoadError::Parse(_)), "got {err:?}");
    }

    #[test]
    fn parses_profile_table() {
        let src = r#"
[profile]
mode = "smart"
smart_allow_lockdown = true
"#;
        let cfg: Config = toml::from_str(src).unwrap();
        assert_eq!(cfg.profile.mode, crate::profile::SecurityProfile::Smart);
        assert!(cfg.profile.smart_allow_lockdown);
    }

    #[test]
    fn profile_defaults_to_prompt() {
        let cfg: Config = toml::from_str("").unwrap();
        assert_eq!(cfg.profile.mode, crate::profile::SecurityProfile::Prompt);
        assert!(!cfg.profile.smart_allow_lockdown);
    }

    #[test]
    fn load_rejects_unknown_key_in_profile_table() {
        let mut tmp = tempfile::NamedTempFile::new().unwrap();
        use std::io::Write as _;
        tmp.write_all(b"[profile]\nmdoe = \"smart\"\n").unwrap();
        let err = load(tmp.path()).expect_err("unknown profile field must fail");
        assert!(matches!(err, LoadError::Parse(_)), "got {err:?}");
    }

    #[test]
    fn rejects_unknown_profile_mode() {
        toml::from_str::<Config>("[profile]\nmode = \"paranoid\"\n")
            .expect_err("unknown profile mode must fail");
    }

    #[test]
    fn missing_onnx_subtable_keeps_defaults() {
        let cfg: Config = toml::from_str("[tier2]\nbackend = \"heuristic\"").unwrap();
        assert_eq!(cfg.tier2.backend.as_deref(), Some("heuristic"));
        assert_eq!(cfg.tier2.onnx.model, "securebert2");
    }

    #[test]
    fn load_parses_server_and_accumulator_tables() {
        // Invariant: `load` honors non-ONNX policy tables in every
        // build flavor. Drives `load` (not bare `toml::from_str`)
        // so a future cfg-gate on the parser regresses loudly.
        let src = br#"
[server]
max_concurrent_connections = 8
idle_read_timeout_secs = 5

[accumulator]
block_threshold = 0.97
"#;
        let mut tmp = tempfile::NamedTempFile::new().unwrap();
        use std::io::Write as _;
        tmp.write_all(src).unwrap();
        let cfg = load(tmp.path()).expect("readable + valid TOML");
        assert_eq!(cfg.server.max_concurrent_connections, 8);
        assert_eq!(cfg.server.idle_read_timeout_secs, 5);
        assert!((cfg.accumulator.block_threshold.unwrap() - 0.97).abs() < 1e-6);
    }

    #[test]
    fn load_parses_non_onnx_tier2_backend() {
        // Invariant: non-ONNX backend selection round-trips through
        // `load` in every build flavor. Asserts the parsed Config
        // field directly so the test fails on a parsing regression
        // even if downstream `resolve_backend` is also broken.
        let mut tmp = tempfile::NamedTempFile::new().unwrap();
        use std::io::Write as _;
        tmp.write_all(b"[tier2]\nbackend = \"heuristic\"").unwrap();
        let cfg = load(tmp.path()).unwrap();
        assert_eq!(cfg.tier2.backend.as_deref(), Some("heuristic"));
    }

    #[test]
    fn load_rejects_malformed_toml() {
        // Invariant: explicit --config must fail closed on parse
        // errors so an operator's malformed policy can't silently
        // fall through to compiled-in defaults.
        let mut tmp = tempfile::NamedTempFile::new().unwrap();
        use std::io::Write as _;
        tmp.write_all(b"this = is = not = valid").unwrap();
        let err = load(tmp.path()).unwrap_err();
        assert!(matches!(err, LoadError::Parse(_)), "got {err:?}");
    }

    #[test]
    fn load_missing_file_errors() {
        // Explicit --config with a missing path is always a hard
        // I/O error, in every build flavor.
        let dir = tempfile::tempdir().unwrap();
        let missing = dir.path().join("does-not-exist.toml");
        assert!(!missing.exists());
        match load(&missing) {
            Err(LoadError::Io(_)) => {}
            other => panic!("expected LoadError::Io, got {other:?}"),
        }
    }

    #[test]
    fn load_parses_onnx_subtable_in_every_build() {
        // Even in non-`tier2-onnx` builds the `[tier2.onnx]`
        // subtable must Deserialize cleanly — `OnnxConfig` is
        // parsed in every build flavor, only READS of its fields
        // are gated behind the feature. A future refactor that
        // cfg-gates the struct definition would silently break
        // operators who supply ONNX paths in a non-feature build
        // and expect a recognisable parse error rather than a
        // mysterious "unknown field" rejection.
        let mut tmp = tempfile::NamedTempFile::new().unwrap();
        use std::io::Write as _;
        tmp.write_all(
            br#"
[tier2.onnx]
model = "securebert2"
model_path = "/var/lib/atty-guard/m.onnx"
tokenizer_path = "/var/lib/atty-guard/t.json"
max_tokens = 2048
warn_threshold = 0.4
block_threshold = 0.88
"#,
        )
        .unwrap();
        let cfg = load(tmp.path()).expect("OnnxConfig must parse in all builds");
        assert_eq!(cfg.tier2.onnx.model, "securebert2");
        assert_eq!(cfg.tier2.onnx.max_tokens, 2048);
        assert!((cfg.tier2.onnx.block_threshold - 0.88).abs() < 1e-6);
    }

    #[test]
    fn load_rejects_unknown_top_level_key() {
        // A typo'd top-level table/key must fail closed rather than
        // silently no-op into compiled-in defaults (audit #427). Mirrors
        // atoms.pins.toml's deny_unknown_fields posture.
        let mut tmp = tempfile::NamedTempFile::new().unwrap();
        use std::io::Write as _;
        tmp.write_all(b"[serverz]\nmax_concurrent_connections = 8\n")
            .unwrap();
        let err = load(tmp.path()).expect_err("unknown table must fail");
        assert!(matches!(err, LoadError::Parse(_)), "got {err:?}");
    }

    #[test]
    fn load_rejects_unknown_key_in_known_table() {
        // A typo'd field inside a recognized table (e.g.
        // `max_concurrent_connection` missing the trailing `s`) must
        // also fail rather than silently use the default.
        let mut tmp = tempfile::NamedTempFile::new().unwrap();
        use std::io::Write as _;
        tmp.write_all(b"[server]\nmax_concurrent_connection = 8\n")
            .unwrap();
        let err = load(tmp.path()).expect_err("unknown field must fail");
        assert!(matches!(err, LoadError::Parse(_)), "got {err:?}");
    }

    #[test]
    fn load_rejects_unknown_key_in_onnx_subtable() {
        let mut tmp = tempfile::NamedTempFile::new().unwrap();
        use std::io::Write as _;
        tmp.write_all(b"[tier2.onnx]\nmax_token = 2048\n").unwrap();
        let err = load(tmp.path()).expect_err("unknown onnx field must fail");
        assert!(matches!(err, LoadError::Parse(_)), "got {err:?}");
    }

    #[test]
    fn load_refuses_oversize_file() {
        // Defense-in-depth: a misplaced `--config` pointing at a
        // huge file (or /dev/urandom) would OOM the daemon. Cap
        // exceeded = hard error.
        let mut tmp = tempfile::NamedTempFile::new().unwrap();
        use std::io::Write as _;
        // Write just over the cap. Use a comment line so the
        // content is still valid TOML if the cap were lifted.
        let mut payload = String::from("# ");
        payload.push_str(&"x".repeat(MAX_CONFIG_BYTES as usize));
        tmp.write_all(payload.as_bytes()).unwrap();
        let err = load(tmp.path()).expect_err("oversize file must fail");
        match err {
            LoadError::Io(e) => {
                assert!(
                    e.to_string().contains("cap is"),
                    "expected cap message, got {e}"
                );
            }
            other => panic!("expected LoadError::Io, got {other:?}"),
        }
    }

    #[cfg(unix)]
    #[test]
    fn load_refuses_non_regular_file() {
        // Pointing --config at a directory (operator typo) or a
        // fifo (mkfifo'd by mistake or maliciously) would block /
        // misbehave under `read_to_string`. Reject before reading.
        let dir = tempfile::tempdir().unwrap();
        match load(dir.path()) {
            Err(LoadError::Io(e)) => {
                assert!(
                    e.to_string().contains("not a regular file"),
                    "expected filetype error, got {e}"
                );
            }
            other => panic!("expected non-regular-file error, got {other:?}"),
        }
    }
}
