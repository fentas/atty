//! `npm`/`pnpm`/`yarn` install-shape parser. Yields every package
//! token after the install verb, skipping flag tokens. Currently
//! consumed by the V2-F OSV live lookup in `server.rs`.
//!
//! Pre-refactor the server side returned only the FIRST non-flag
//! token, so `npm install clean vulnerable` would OSV-check `clean`
//! and miss the vulnerable one — attacker bypass = prepend a benign
//! package. The unified parser checks every token, capped at
//! `MAX_PKGS_PER_COMMAND` to bound work on hostile inputs.
//!
//! Scope note: `classifier.rs` has its OWN regex-anchored npm walk
//! for the static flagged-packages lookup. That path already
//! iterates all tokens, and its emission shape (per-pkg
//! `ClassifyResult` with `flagged_npm_packages` membership) doesn't
//! substitute cleanly for this Vec-returning helper. Unifying is a
//! deliberate non-goal of this module.
//!
//! Recognised shapes (verb anchored to start-of-line, `;`, `&`, or
//! `|` — to avoid `xnpm install` false-positives — with any ASCII
//! whitespace run between tool and verb):
//!   npm install / npm i / npm add
//!   pnpm install / pnpm i / pnpm add
//!   yarn add
//!
//! Token rules per package:
//!   - tokens starting with `-` are skipped as flags;
//!   - flag VALUES (the next token after a flag) are NOT consumed:
//!     known install flags either take no value (`-g`, `--save-dev`,
//!     `--no-save`) or use `=` (`--prefix=...`). Better to OSV-check
//!     an arg-value-by-mistake than to miss a real package. This is
//!     a documented trade-off, not an oversight;
//!   - trailing `@version` strips while preserving leading `@scope/`
//!     (scoped packages: `@types/node`, `@aws-sdk/client-s3`).

/// Hard cap on returned package count per command. Keeps a hostile
/// or pathological input (e.g. `npm install a b c ... <thousand>`)
/// from spending arbitrary time in the OSV path on a single classify
/// call. 64 is well above realistic real-world installs.
pub const MAX_PKGS_PER_COMMAND: usize = 64;

/// Returns all candidate package names from an install-shape command,
/// in left-to-right order. Empty Vec when the command doesn't match
/// a recognised install shape.
///
/// Walks all occurrences of each `(tool, verb)` pair so a leading
/// false-anchor like `xnpm install foo; npm install bar` still
/// matches the real install farther in. Tolerates any amount of
/// ASCII whitespace (` `, `\t`) between tool, verb, and args.
pub fn extract_npm_install_pkgs(line: &str) -> Vec<&str> {
    // `(tool, verb)` — the tool is the bare program name; whitespace
    // between tool/verb/args is matched by `expect_ws_after`.
    let shapes: &[(&str, &str)] = &[
        ("npm", "install"),
        ("npm", "i"),
        ("npm", "add"),
        ("pnpm", "install"),
        ("pnpm", "i"),
        ("pnpm", "add"),
        ("yarn", "add"),
    ];
    for &(tool, verb) in shapes {
        // Walk every occurrence of the tool name so a failed anchor
        // check (e.g. matching the `npm` inside `xnpm`) doesn't
        // prevent matching a real later occurrence.
        for (idx, _) in line.match_indices(tool) {
            // Anchor: tool must start the line OR follow one of
            // ` ` / `\t` / `;` / `&` / `|`. Disqualifies `xnpm`.
            if idx != 0 {
                let prev = line.as_bytes()[idx - 1];
                if !matches!(prev, b' ' | b'\t' | b';' | b'&' | b'|') {
                    continue;
                }
            }
            // Whitespace between tool and verb (≥1 byte).
            let after_tool = idx + tool.len();
            let verb_start = match skip_ws(line, after_tool) {
                Some(p) if p > after_tool => p,
                _ => continue,
            };
            // Verb must match exactly, followed by whitespace OR
            // end-of-line (the latter being a `npm install` with no
            // args — returns empty Vec).
            let verb_end = verb_start + verb.len();
            // Byte-compare the candidate span: `line[verb_start..verb_end]`
            // would panic if `verb_end` lands inside a multi-byte UTF-8
            // char (e.g. `npm 日本語…`). `get(..)` returns None when the
            // range is out of bounds, so this also subsumes the prior
            // `verb_end > line.len()` guard.
            if line.as_bytes().get(verb_start..verb_end) != Some(verb.as_bytes()) {
                continue;
            }
            let args_start = match line.as_bytes().get(verb_end).copied() {
                None => return Vec::new(),
                Some(c) if matches!(c, b' ' | b'\t') => match skip_ws(line, verb_end) {
                    Some(p) => p,
                    None => return Vec::new(),
                },
                Some(_) => continue,
            };
            return walk_pkgs(&line[args_start..]);
        }
    }
    Vec::new()
}

/// Returns the offset of the first non-whitespace byte at or after
/// `start`. `None` if the rest is all whitespace (or `start` is
/// past end-of-line). Treats ` ` and `\t` as whitespace; newlines
/// are not expected in single-command input but tolerated.
fn skip_ws(line: &str, start: usize) -> Option<usize> {
    let bytes = line.as_bytes();
    let mut i = start;
    while i < bytes.len() && matches!(bytes[i], b' ' | b'\t' | b'\n' | b'\r') {
        i += 1;
    }
    if i >= bytes.len() {
        None
    } else {
        Some(i)
    }
}

/// Convenience: first parsed package, or `None`. Used by server.rs
/// tests for `Option<&str>`-shaped assertions kept from the
/// pre-refactor unit tests; the production OSV path consumes the
/// full Vec via `extract_npm_install_pkgs`.
#[cfg(test)]
pub fn extract_npm_install_first_pkg(line: &str) -> Option<&str> {
    let v = extract_npm_install_pkgs(line);
    v.into_iter().next()
}

fn walk_pkgs(args: &str) -> Vec<&str> {
    let mut out: Vec<&str> = Vec::new();
    for tok in args.split_whitespace() {
        if out.len() >= MAX_PKGS_PER_COMMAND {
            break;
        }
        if tok.starts_with('-') {
            continue;
        }
        // Strip trailing `@version`. Scoped packages start with `@`,
        // so a `@` at index 0 is NOT a version separator.
        let name = match tok.rfind('@') {
            Some(0) | None => tok,
            Some(i) => &tok[..i],
        };
        if !name.is_empty() {
            out.push(name);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn returns_empty_when_not_an_install() {
        assert!(extract_npm_install_pkgs("ls -la").is_empty());
        assert!(extract_npm_install_pkgs("git pull origin main").is_empty());
        assert!(extract_npm_install_pkgs("npm test").is_empty());
        assert!(extract_npm_install_pkgs("npm run install").is_empty());
    }

    #[test]
    fn single_package_unversioned() {
        assert_eq!(
            extract_npm_install_pkgs("npm install lodash"),
            vec!["lodash"]
        );
        assert_eq!(extract_npm_install_pkgs("npm i lodash"), vec!["lodash"]);
        assert_eq!(extract_npm_install_pkgs("npm add lodash"), vec!["lodash"]);
    }

    #[test]
    fn multi_package_returns_all_in_order() {
        // Core attacker-bypass regression: `npm install clean
        // vulnerable` must return BOTH packages, not just the first.
        assert_eq!(
            extract_npm_install_pkgs("npm install clean vulnerable"),
            vec!["clean", "vulnerable"],
        );
        assert_eq!(
            extract_npm_install_pkgs("pnpm add react bad@1.0.0"),
            vec!["react", "bad"],
        );
    }

    #[test]
    fn scoped_packages_preserve_at_prefix() {
        assert_eq!(
            extract_npm_install_pkgs("npm install @types/node"),
            vec!["@types/node"],
        );
        assert_eq!(
            extract_npm_install_pkgs("npm install --save-dev @types/node bad"),
            vec!["@types/node", "bad"],
        );
        assert_eq!(
            extract_npm_install_pkgs("npm install @aws-sdk/client-s3@3.0.0"),
            vec!["@aws-sdk/client-s3"],
        );
    }

    #[test]
    fn flags_are_skipped() {
        assert_eq!(
            extract_npm_install_pkgs("npm install -g typescript"),
            vec!["typescript"],
        );
        assert_eq!(
            extract_npm_install_pkgs("npm install --save-dev --no-fund pkg"),
            vec!["pkg"],
        );
        // Flag-with-value-via-= still skipped wholesale.
        assert_eq!(
            extract_npm_install_pkgs("npm install --prefix=/opt/foo pkg"),
            vec!["pkg"],
        );
    }

    #[test]
    fn pnpm_and_yarn_variants() {
        assert_eq!(
            extract_npm_install_pkgs("pnpm install one two"),
            vec!["one", "two"],
        );
        assert_eq!(
            extract_npm_install_pkgs("pnpm i one two"),
            vec!["one", "two"],
        );
        assert_eq!(
            extract_npm_install_pkgs("yarn add react react-dom"),
            vec!["react", "react-dom"],
        );
    }

    #[test]
    fn leading_separators_anchor_the_install_verb() {
        // The verb must be at start-of-line OR after one of
        // space/tab/;/&/|, so `xnpm install` is NOT a match.
        assert_eq!(extract_npm_install_pkgs("ls; npm install pkg"), vec!["pkg"],);
        assert_eq!(
            extract_npm_install_pkgs("true && npm install pkg"),
            vec!["pkg"],
        );
    }

    #[test]
    fn anchor_false_positive_skipped_then_real_match_succeeds() {
        // `find("npm ")` would have matched inside `xnpm install`
        // first, then bailed; the new walker continues past it and
        // hits the real `npm install bar` later in the line.
        assert_eq!(
            extract_npm_install_pkgs("xnpm install foo; npm install bar"),
            vec!["bar"],
        );
    }

    #[test]
    fn standalone_xnpm_doesnt_match() {
        // Same anchor check but with no later real install — must
        // return empty rather than emitting `foo` from inside
        // `xnpm install foo`.
        assert!(extract_npm_install_pkgs("xnpm install foo").is_empty());
    }

    #[test]
    fn double_whitespace_between_tool_and_verb_still_matches() {
        // Subagent flagged `"npm  install pkg"` (double space) and
        // `"npm\tinstall pkg"` (tab) being rejected by the old
        // single-` `-separator code path. The new parser uses
        // skip_ws so both render as the canonical form.
        assert_eq!(extract_npm_install_pkgs("npm  install pkg"), vec!["pkg"],);
        assert_eq!(extract_npm_install_pkgs("npm\tinstall pkg"), vec!["pkg"],);
        assert_eq!(extract_npm_install_pkgs("npm install   pkg"), vec!["pkg"],);
        assert_eq!(extract_npm_install_pkgs("pnpm  add\treact"), vec!["react"],);
    }

    #[test]
    fn version_strip_handles_complex_specs() {
        assert_eq!(
            extract_npm_install_pkgs("npm install pkg@1.2.3"),
            vec!["pkg"],
        );
        assert_eq!(
            extract_npm_install_pkgs("npm install @scope/pkg@1.2.3"),
            vec!["@scope/pkg"],
        );
        // `pkg@` is degenerate npm input; rfind returns the trailing
        // `@`, so we strip to `pkg`. OSV will be queried for `pkg`,
        // which is harmless.
        assert_eq!(extract_npm_install_pkgs("npm install pkg@"), vec!["pkg"],);
    }

    #[test]
    fn cap_bounds_pathological_inputs() {
        // Hostile input listing 200 packages shouldn't trigger 200
        // OSV round-trips. Stop at the cap.
        let mut cmd = String::from("npm install");
        for i in 0..MAX_PKGS_PER_COMMAND + 5 {
            cmd.push_str(&format!(" p{i}"));
        }
        let out = extract_npm_install_pkgs(&cmd);
        assert_eq!(out.len(), MAX_PKGS_PER_COMMAND);
    }

    #[test]
    fn multibyte_after_tool_does_not_panic() {
        // The verb span check used `line[verb_start..verb_end]`, which
        // panicked when verb_end landed inside a multi-byte char. These
        // must parse cleanly (no match → empty), not panic.
        assert!(extract_npm_install_pkgs("npm 日本語パッケージ").is_empty());
        assert!(extract_npm_install_pkgs("npm i日").is_empty());
        assert!(extract_npm_install_pkgs("yarn 安裝").is_empty());
        // A real install with a unicode package name still works.
        assert_eq!(
            extract_npm_install_pkgs("npm install 日本語-pkg"),
            vec!["日本語-pkg"],
        );
    }

    #[test]
    fn extract_first_pkg_legacy_helper() {
        assert_eq!(
            extract_npm_install_first_pkg("npm install lodash"),
            Some("lodash"),
        );
        assert_eq!(
            extract_npm_install_first_pkg("npm install --save lodash bad"),
            Some("lodash"),
        );
        assert_eq!(extract_npm_install_first_pkg("ls -la"), None);
    }
}
