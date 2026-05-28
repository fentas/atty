//! Shared `npm`/`pnpm`/`yarn` install-shape parser. Yields every
//! package token after the install verb, skipping flags and their
//! values. Used by:
//!   - `classifier.rs` for the static flagged-package scan,
//!   - `server.rs` for the V2-F OSV live lookup.
//!
//! gpt-review #029: pre-fix the server side called a one-shot
//! `extract_npm_install_pkg` that returned only the FIRST non-flag
//! token, so `npm install clean-pkg vulnerable-pkg` would OSV-check
//! `clean-pkg` and miss the vulnerable one. Attacker bypass: prepend
//! a benign package. The static classifier already walked all
//! tokens; this module unifies the parsing so both layers see the
//! same package set.
//!
//! Recognised shapes (all left-anchored to start-of-line, semicolon,
//! ampersand, or pipe to avoid `xnpm` false-positives):
//!   npm install <pkgs>       npm i <pkgs>       npm add <pkgs>
//!   pnpm install <pkgs>      pnpm i <pkgs>      pnpm add <pkgs>
//!   yarn add <pkgs>
//!
//! Token rules per package:
//!   - leading `-`/`--` flags skip;
//!   - flag VALUES (the next token after `--save-dev`-style switches
//!     that take an argument) are NOT consumed because the recognised
//!     install flags either take no value (`-g`, `--save-dev`,
//!     `--no-save`) or use `=` (`--prefix=...`). Treat any flag as
//!     valueless and let the next non-flag token through as a
//!     package. Better to OSV-check an arg-value-by-mistake than to
//!     miss a real package;
//!   - trailing `@version` strips while preserving the leading
//!     `@scope/` (scoped packages: `@types/node`, `@aws-sdk/client`).

/// Hard cap on returned package count per command. Keeps a hostile
/// or pathological input (e.g. `npm install a b c ... <thousand>`)
/// from spending arbitrary time in the OSV path on a single classify
/// call. 64 is well above realistic real-world installs.
pub const MAX_PKGS_PER_COMMAND: usize = 64;

/// Returns all candidate package names from an install-shape command,
/// in left-to-right order. Empty Vec when the command doesn't match
/// a recognised install shape.
pub fn extract_npm_install_pkgs(line: &str) -> Vec<&str> {
    let verbs = [
        ("npm ", "install"),
        ("npm ", "i "),
        ("npm ", "add"),
        ("pnpm ", "install"),
        ("pnpm ", "i "),
        ("pnpm ", "add"),
        ("yarn ", "add"),
    ];
    for (cmd, verb) in verbs {
        let Some(cmd_at) = line.find(cmd) else {
            continue;
        };
        if cmd_at != 0 {
            let prev = line.as_bytes()[cmd_at - 1];
            if !matches!(prev, b' ' | b';' | b'&' | b'|') {
                continue;
            }
        }
        let after_cmd = cmd_at + cmd.len();
        let verb_end = after_cmd + verb.len();
        if verb_end > line.len() {
            continue;
        }
        if !line[after_cmd..verb_end].eq(verb) {
            continue;
        }
        let args_start = if verb.ends_with(' ') {
            verb_end
        } else if verb_end == line.len() {
            return Vec::new();
        } else if line.as_bytes()[verb_end] == b' ' {
            verb_end + 1
        } else {
            continue;
        };
        return walk_pkgs(&line[args_start..]);
    }
    Vec::new()
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
        assert_eq!(extract_npm_install_pkgs("npm install lodash"), vec!["lodash"]);
        assert_eq!(extract_npm_install_pkgs("npm i lodash"), vec!["lodash"]);
        assert_eq!(extract_npm_install_pkgs("npm add lodash"), vec!["lodash"]);
    }

    #[test]
    fn multi_package_returns_all_in_order() {
        // gpt-review #029 core regression: `npm install clean vulnerable`
        // must return BOTH packages, not just the first.
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
        // space/;/&/|, so `xnpm install` is NOT a match (no false
        // anchor before the verb).
        assert_eq!(
            extract_npm_install_pkgs("ls; npm install pkg"),
            vec!["pkg"],
        );
        assert_eq!(
            extract_npm_install_pkgs("true && npm install pkg"),
            vec!["pkg"],
        );
        assert!(extract_npm_install_pkgs("xnpm install pkg").is_empty());
    }

    #[test]
    fn version_strip_handles_complex_specs() {
        // The implementation uses `rfind('@')` — handles trailing
        // version specs even when the package name itself starts
        // with `@`. `@scope/name@1.2.3` strips to `@scope/name`.
        assert_eq!(
            extract_npm_install_pkgs("npm install pkg@1.2.3"),
            vec!["pkg"],
        );
        assert_eq!(
            extract_npm_install_pkgs("npm install @scope/pkg@1.2.3"),
            vec!["@scope/pkg"],
        );
        // Bare `@` (no version after it) leaves the whole token.
        // Edge case: `pkg@` is degenerate input. `rfind` returns the
        // index of the trailing `@`, so we'd strip to `pkg`. That's
        // a fine outcome.
        assert_eq!(
            extract_npm_install_pkgs("npm install pkg@"),
            vec!["pkg"],
        );
    }

    #[test]
    fn cap_bounds_pathological_inputs() {
        // gpt-review #029 hardening: a hostile command listing 200
        // packages shouldn't OSV-check all 200. Stop at the cap.
        let mut cmd = String::from("npm install");
        for i in 0..MAX_PKGS_PER_COMMAND + 5 {
            cmd.push_str(&format!(" p{i}"));
        }
        let out = extract_npm_install_pkgs(&cmd);
        assert_eq!(out.len(), MAX_PKGS_PER_COMMAND);
    }

    #[test]
    fn extract_first_pkg_legacy_helper() {
        // Returns the first non-flag token — preserves the prior
        // server.rs/classifier.rs API surface for sites that don't
        // need the full list.
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
