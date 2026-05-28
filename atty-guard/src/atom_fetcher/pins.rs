use std::path::Path;

use super::{AtomPins, FetchError, PinEntry};

/// Load operator pin overrides from `path`. Absent file → Ok(None)
/// (live tracking — the common case). Present file → check perms
/// (root-owned, no group/world-write), parse, validate. Any
/// failure on a present file is a HARD error: the operator opted
/// in, silent fall-back to live tracking would defeat the point.
#[cfg(feature = "atoms-fetch")]
pub fn load_pins(path: &Path) -> Result<Option<AtomPins>, FetchError> {
    load_pins_with_owner(path, 0)
}

#[cfg(not(feature = "atoms-fetch"))]
pub fn load_pins(_path: &Path) -> Result<Option<AtomPins>, FetchError> {
    Ok(None)
}

/// Test seam — the prod call always passes `expected_uid = 0`
/// (root). Tests run as the user's UID and can't chown a file to
/// root without sudo, so we let them pass their own UID through.
/// The parse + validate logic exercised here is identical; only
/// the owner check changes.
#[cfg(feature = "atoms-fetch")]
pub fn load_pins_with_owner(path: &Path, expected_uid: u32) -> Result<Option<AtomPins>, FetchError> {
    let meta = match std::fs::metadata(path) {
        Ok(m) => m,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => {
            return Err(FetchError::ParseError(format!(
                "stat {}: {}",
                path.display(),
                e
            )))
        }
    };
    if !meta.is_file() {
        return Err(FetchError::ParseError(format!(
            "pin file {} is not a regular file (directory, socket, or fifo \
             at this path is almost certainly a misconfiguration)",
            path.display(),
        )));
    }
    check_pin_file_perms(path, &meta, expected_uid)?;
    let bytes = std::fs::read(path).map_err(|e| {
        FetchError::ParseError(format!("read {}: {}", path.display(), e))
    })?;
    if bytes.iter().all(|b| b.is_ascii_whitespace()) {
        return Err(FetchError::ParseError(format!(
            "pin file {} is empty — remove the file to opt out of pinning, \
             or add at least one [gtfobins] / [sigma] entry",
            path.display(),
        )));
    }
    let text = std::str::from_utf8(&bytes).map_err(|e| {
        FetchError::ParseError(format!("pin file {} not utf-8: {}", path.display(), e))
    })?;
    let pins: AtomPins = toml::from_str(text)
        .map_err(|e| FetchError::ParseError(format!("pin file {} parse: {}", path.display(), e)))?;
    validate_pins(&pins)?;
    if pins.gtfobins.is_none() && pins.sigma.is_none() {
        return Err(FetchError::ParseError(format!(
            "pin file {} has no [gtfobins] or [sigma] entry — remove the file \
             to opt out of pinning, or add at least one entry",
            path.display(),
        )));
    }
    Ok(Some(pins))
}

#[cfg(not(feature = "atoms-fetch"))]
pub fn load_pins_with_owner(
    _path: &Path,
    _expected_uid: u32,
) -> Result<Option<AtomPins>, FetchError> {
    Ok(None)
}

/// Refuse a pin file that isn't admin-owned-only-writable. Parallel
/// to `trust_store::read_system_atoms_file_checked`'s posture but
/// for the *config* surface: the pin file lives under `/etc/`,
/// must be root-owned (uid 0), and must not be group- or world-
/// writable. A local attacker who finds the file world-writable
/// can swap in a pin pointing at a tarball they control (with a
/// pre-computed SHA). Refusing here matches `atoms.system.txt`.
///
/// Permission gate only — readability bits are intentionally not
/// checked. The daemon needs only `O_RDONLY`; if `/etc/atty-guard/`
/// keeps the file world-readable (the common case) that's fine.
#[cfg(all(feature = "atoms-fetch", unix))]
fn check_pin_file_perms(
    path: &Path,
    meta: &std::fs::Metadata,
    expected_uid: u32,
) -> Result<(), FetchError> {
    use std::os::unix::fs::MetadataExt;
    use std::os::unix::fs::PermissionsExt;
    if meta.uid() != expected_uid {
        return Err(FetchError::ParseError(format!(
            "pin file {} has owner uid {} (expected {}) — `sudo chown root:root {}`",
            path.display(),
            meta.uid(),
            expected_uid,
            path.display(),
        )));
    }
    let mode = meta.permissions().mode() & 0o777;
    if mode & 0o022 != 0 {
        return Err(FetchError::ParseError(format!(
            "pin file {} has mode 0{:o} with group/world write (chmod g-w,o-w {})",
            path.display(),
            mode,
            path.display(),
        )));
    }
    Ok(())
}

#[cfg(all(feature = "atoms-fetch", not(unix)))]
fn check_pin_file_perms(
    _path: &Path,
    _meta: &std::fs::Metadata,
    _expected_uid: u32,
) -> Result<(), FetchError> {
    Ok(())
}

/// Reject obviously-malformed pin entries early. Both fields must
/// be hex (case-insensitive) of the expected length (40 for git SHA-1, 64
/// for SHA-256). We don't bother with SHA-256 git commits yet —
/// when GitHub flips, bump the length check.
#[cfg(feature = "atoms-fetch")]
fn validate_pins(pins: &AtomPins) -> Result<(), FetchError> {
    fn check(label: &str, entry: &PinEntry) -> Result<(), FetchError> {
        if entry.commit.len() != 40 || !entry.commit.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(FetchError::ParseError(format!(
                "{label}.commit must be 40 hex chars (sha-1), got {:?}",
                entry.commit
            )));
        }
        if entry.sha256.len() != 64 || !entry.sha256.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(FetchError::ParseError(format!(
                "{label}.sha256 must be 64 hex chars (sha-256), got {:?}",
                entry.sha256
            )));
        }
        Ok(())
    }
    if let Some(g) = &pins.gtfobins {
        check("gtfobins", g)?;
    }
    if let Some(s) = &pins.sigma {
        check("sigma", s)?;
    }
    Ok(())
}

#[cfg(all(test, feature = "atoms-fetch"))]
mod tests {
    use super::*;

    #[test]
    fn pin_file_absent_returns_none() {
        let path =
            std::env::temp_dir().join(format!("atty-guard-pin-absent-{}", std::process::id()));
        assert!(!path.exists());
        let pins = load_pins(&path).expect("absent file is not an error");
        assert!(pins.is_none());
    }

    #[test]
    fn pin_file_round_trips() {
        let dir = std::env::temp_dir()
            .join(format!("atty-guard-pin-roundtrip-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("atoms.pins.toml");
        let body = r#"
[gtfobins]
commit = "7382261ef936e35896ba70e7a6b833352ffb9a22"
sha256 = "3121cb8f46b90ba663dbd9b7b4177cacba32589fc55221ac0874dccbfc3ffaca"
"#;
        std::fs::write(&path, body).unwrap();
        let pins = load_pins_with_owner(&path, current_uid())
            .unwrap()
            .expect("file present → Some");
        let g = pins.gtfobins.expect("gtfobins entry");
        assert_eq!(g.commit, "7382261ef936e35896ba70e7a6b833352ffb9a22");
        assert!(pins.sigma.is_none(), "missing entry = partial pin");
        assert_eq!(
            g.tarball_url("GTFOBins/GTFOBins.github.io"),
            "https://codeload.github.com/GTFOBins/GTFOBins.github.io/tar.gz/7382261ef936e35896ba70e7a6b833352ffb9a22"
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn pin_file_rejects_short_commit_hash() {
        // Bad commit, valid sha256 — proves the commit-length
        // check fires independently. Operators who paste an
        // abbreviated SHA need to learn this is a hard error.
        let dir = std::env::temp_dir()
            .join(format!("atty-guard-pin-shortsha-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("atoms.pins.toml");
        std::fs::write(
            &path,
            "[gtfobins]\ncommit = \"7382261e\"\nsha256 = \"3121cb8f46b90ba663dbd9b7b4177cacba32589fc55221ac0874dccbfc3ffaca\"\n",
        )
        .unwrap();
        match load_pins_with_owner(&path, current_uid()) {
            Err(FetchError::ParseError(s)) => {
                assert!(
                    s.contains("commit") && s.contains("40 hex"),
                    "msg should fault the commit specifically: {s}"
                );
            }
            other => panic!("expected ParseError, got {other:?}"),
        }
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn pin_file_rejects_nonhex() {
        let dir =
            std::env::temp_dir().join(format!("atty-guard-pin-nonhex-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("atoms.pins.toml");
        // 40 chars including a `z` — not hex.
        std::fs::write(
            &path,
            "[gtfobins]\ncommit = \"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\"\nsha256 = \"3121cb8f46b90ba663dbd9b7b4177cacba32589fc55221ac0874dccbfc3ffaca\"\n",
        )
        .unwrap();
        assert!(matches!(load_pins_with_owner(&path, current_uid()), Err(FetchError::ParseError(_))));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn pin_file_rejects_short_sha256() {
        // Valid commit, bad sha256 — independent of the commit
        // check. Confirms BOTH validators fire, not just the
        // first one in evaluation order.
        let dir = std::env::temp_dir()
            .join(format!("atty-guard-pin-shortsha256-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("atoms.pins.toml");
        std::fs::write(
            &path,
            "[gtfobins]\ncommit = \"7382261ef936e35896ba70e7a6b833352ffb9a22\"\nsha256 = \"3121cb8f\"\n",
        )
        .unwrap();
        match load_pins_with_owner(&path, current_uid()) {
            Err(FetchError::ParseError(s)) => {
                assert!(
                    s.contains("sha256") && s.contains("64 hex"),
                    "msg should fault the sha256 specifically: {s}"
                );
            }
            other => panic!("expected ParseError, got {other:?}"),
        }
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn pin_file_rejects_malformed_toml() {
        let dir = std::env::temp_dir()
            .join(format!("atty-guard-pin-malformed-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("atoms.pins.toml");
        std::fs::write(&path, "this is = not [ toml\n").unwrap();
        assert!(matches!(load_pins_with_owner(&path, current_uid()), Err(FetchError::ParseError(_))));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn pin_entry_tarball_url_uses_commit() {
        let p = PinEntry {
            commit: "abcd1234".repeat(5),
            sha256: "0".repeat(64),
        };
        let url = p.tarball_url("owner/repo");
        assert!(url.ends_with(&p.commit));
        assert!(url.contains("codeload.github.com"));
        assert!(url.contains("owner/repo"));
        assert!(!url.contains("refs/heads/master"));
    }

    #[test]
    fn pin_file_rejects_unknown_section() {
        // Operator typo: `[gtfobin]` instead of `[gtfobins]`.
        // Without `deny_unknown_fields`, serde parses this as
        // `AtomPins{None,None}` and the source falls back to
        // live tracking silently — defeating the whole point
        // of opting in. The reject path is the security
        // guarantee, not a nicety.
        let dir = std::env::temp_dir().join(format!(
            "atty-guard-pin-unknownsec-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("atoms.pins.toml");
        let body = r#"
[gtfobin]
commit = "7382261ef936e35896ba70e7a6b833352ffb9a22"
sha256 = "3121cb8f46b90ba663dbd9b7b4177cacba32589fc55221ac0874dccbfc3ffaca"
"#;
        std::fs::write(&path, body).unwrap();
        assert!(matches!(
            load_pins_with_owner(&path, current_uid()),
            Err(FetchError::ParseError(_))
        ));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn pin_file_rejects_unknown_key() {
        // Operator added an unrecognised key (`branch = ...`)
        // alongside valid commit + sha256. Without
        // `#[serde(deny_unknown_fields)]` this would parse
        // successfully (extra fields silently ignored) and the
        // operator's expectation (e.g. "I want master branch")
        // would be silently violated. We keep BOTH required
        // fields valid so the test fails for the right reason
        // — the `branch` key — not because `commit` was missing.
        let dir = std::env::temp_dir().join(format!(
            "atty-guard-pin-unknownkey-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("atoms.pins.toml");
        let body = r#"
[gtfobins]
commit = "7382261ef936e35896ba70e7a6b833352ffb9a22"
sha256 = "3121cb8f46b90ba663dbd9b7b4177cacba32589fc55221ac0874dccbfc3ffaca"
branch = "main"
"#;
        std::fs::write(&path, body).unwrap();
        match load_pins_with_owner(&path, current_uid()) {
            Err(FetchError::ParseError(msg)) => {
                assert!(
                    msg.contains("branch") || msg.contains("unknown"),
                    "error should fault the unknown key, not the parse generically: {msg}"
                );
            }
            other => panic!("expected ParseError, got {other:?}"),
        }
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn pin_file_rejects_empty() {
        // Zero-byte file means "operator opted in with nothing".
        // Without this check it parses to AtomPins{None,None}
        // and silently disables pinning. Hard error matches the
        // rest of the pin-file parse posture.
        let dir = std::env::temp_dir()
            .join(format!("atty-guard-pin-empty-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("atoms.pins.toml");
        std::fs::write(&path, "").unwrap();
        match load_pins_with_owner(&path, current_uid()) {
            Err(FetchError::ParseError(msg)) => {
                assert!(msg.contains("empty"));
            }
            other => panic!("expected ParseError, got {other:?}"),
        }
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn pin_file_rejects_whitespace_only() {
        // Comments-only file (newlines + `# ...`) — operator
        // pasted the example template but never uncommented a
        // section. Without this check, all-comment TOML parses
        // to AtomPins{None,None} which we treat as opt-out.
        let dir = std::env::temp_dir().join(format!(
            "atty-guard-pin-comments-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("atoms.pins.toml");
        std::fs::write(&path, "   \n  \n\t\n").unwrap();
        match load_pins_with_owner(&path, current_uid()) {
            Err(FetchError::ParseError(msg)) => {
                assert!(msg.contains("empty"));
            }
            other => panic!("expected ParseError, got {other:?}"),
        }
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn pin_file_rejects_perms_wrong_owner() {
        // Pin file's contract is "root-owned only". Anything
        // else means a local attacker (or a fat-finger
        // `chown $user`) could swap pins to point at attacker-
        // controlled commits. Refuse to load.
        let dir = std::env::temp_dir().join(format!(
            "atty-guard-pin-badowner-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("atoms.pins.toml");
        // Valid content — only the owner check should fire.
        std::fs::write(
            &path,
            "[gtfobins]\ncommit = \"7382261ef936e35896ba70e7a6b833352ffb9a22\"\nsha256 = \"3121cb8f46b90ba663dbd9b7b4177cacba32589fc55221ac0874dccbfc3ffaca\"\n",
        )
        .unwrap();
        // Pass an expected_uid that the file ISN'T owned by.
        // current_uid()+1 is guaranteed not to match (and not
        // be zero, so the message format is still meaningful).
        let bad_uid = current_uid().wrapping_add(1);
        match load_pins_with_owner(&path, bad_uid) {
            Err(FetchError::ParseError(msg)) => {
                assert!(
                    msg.contains("owner uid"),
                    "msg should mention owner: {msg}"
                );
            }
            other => panic!("expected ParseError, got {other:?}"),
        }
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn pin_file_rejects_world_writable() {
        // 0666 means anyone on the box can edit pins. Trust
        // model says "admin-managed via sudo only" — refuse.
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!(
            "atty-guard-pin-worldwrite-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("atoms.pins.toml");
        std::fs::write(
            &path,
            "[gtfobins]\ncommit = \"7382261ef936e35896ba70e7a6b833352ffb9a22\"\nsha256 = \"3121cb8f46b90ba663dbd9b7b4177cacba32589fc55221ac0874dccbfc3ffaca\"\n",
        )
        .unwrap();
        let mut perms = std::fs::metadata(&path).unwrap().permissions();
        perms.set_mode(0o666);
        std::fs::set_permissions(&path, perms).unwrap();
        match load_pins_with_owner(&path, current_uid()) {
            Err(FetchError::ParseError(msg)) => {
                assert!(msg.contains("group/world write"));
            }
            other => panic!("expected ParseError, got {other:?}"),
        }
        std::fs::remove_dir_all(&dir).ok();
    }

    /// Resolve the current EUID for tests — pin file perm
    /// checks compare against this so a test running as a
    /// regular user can still exercise the parse path. Prod
    /// callers (`load_pins`) always pass 0.
    fn current_uid() -> u32 {
        unsafe {
            extern "C" {
                fn geteuid() -> u32;
            }
            geteuid()
        }
    }
}
