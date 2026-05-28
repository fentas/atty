// trust_store tests — tempdir-based, no global env mutation.

use super::*;
use std::io::Write;

fn fresh_store() -> (TrustStore, tempfile::TempDir) {
    let tmp = tempfile::tempdir().expect("tempdir");
    let store = TrustStore::new(tmp.path().to_path_buf());
    (store, tmp)
}

#[test]
fn empty_dir_loads_cleanly() {
    let (store, _tmp) = fresh_store();
    store.load_persistent(1000).unwrap();
    assert!(store.list_atoms(1000, ListScope::Persistent).is_empty());
    assert!(store.list_urls(1000).is_empty());
}

#[test]
fn persistent_add_then_list() {
    let (store, _tmp) = fresh_store();
    store.persistent_add_atom(1000, "nc -e /bin/sh").unwrap();
    store.persistent_add_atom(1000, "bash -i >& /dev/tcp/").unwrap();
    let listed = store.list_atoms(1000, ListScope::Persistent);
    assert_eq!(listed.len(), 2);
    // sorted output
    assert_eq!(listed[0], "bash -i >& /dev/tcp/");
    assert_eq!(listed[1], "nc -e /bin/sh");
}

#[test]
fn persistent_add_validates_length() {
    let (store, _tmp) = fresh_store();
    let err = store.persistent_add_atom(1000, "xx").unwrap_err();
    assert!(err.to_string().contains("too short"));
    let long = "a".repeat(201);
    let err = store.persistent_add_atom(1000, &long).unwrap_err();
    assert!(err.to_string().contains("too long"));
}

#[test]
fn persistent_add_rejects_newline() {
    let (store, _tmp) = fresh_store();
    let err = store
        .persistent_add_atom(1000, "atom with\nnewline")
        .unwrap_err();
    assert!(err.to_string().contains("newline"));
}

#[test]
fn persistent_add_rejects_inline_metadata_delimiter() {
    // ` #` is reserved for the inline-metadata suffix in the
    // on-disk format. An atom containing ` #` would silently
    // truncate on the next file load.
    let (store, _tmp) = fresh_store();
    let err = store
        .persistent_add_atom(1000, "atom with # comment")
        .unwrap_err();
    assert!(err.to_string().contains("inline-metadata"));
}

#[test]
fn persistent_add_rejects_placeholder_atoms() {
    let (store, _tmp) = fresh_store();
    let err = store
        .persistent_add_atom(1000, "fooserver /path/to/output-file")
        .unwrap_err();
    assert!(err.to_string().contains("placeholder"));
    let err = store
        .persistent_add_atom(1000, "ssh <hostname>")
        .unwrap_err();
    assert!(err.to_string().contains("placeholder"));
    let err = store
        .persistent_add_atom(1000, "loader {PATH:.exe}")
        .unwrap_err();
    assert!(err.to_string().contains("placeholder"));
}

#[test]
fn persistent_remove_only_when_present() {
    let (store, _tmp) = fresh_store();
    store.persistent_add_atom(1000, "test atom").unwrap();
    assert!(store.persistent_remove_atom(1000, "test atom").unwrap());
    assert!(!store.persistent_remove_atom(1000, "missing").unwrap());
    assert!(store.list_atoms(1000, ListScope::Persistent).is_empty());
}

#[test]
fn url_add_and_list() {
    let (store, _tmp) = fresh_store();
    store
        .persistent_add_url(1000, "example.com", UrlDecision::Allow)
        .unwrap();
    store
        .persistent_add_url(1000, "evil.io", UrlDecision::Block)
        .unwrap();
    let listed = store.list_urls(1000);
    assert_eq!(listed.len(), 2);
    // allow entries come first (sorted), then block.
    assert_eq!(listed[0].0, "example.com");
    assert_eq!(listed[0].1, UrlDecision::Allow);
    assert_eq!(listed[1].0, "evil.io");
    assert_eq!(listed[1].1, UrlDecision::Block);
}

#[test]
fn url_decision_flip_overwrites() {
    let (store, _tmp) = fresh_store();
    store
        .persistent_add_url(1000, "example.com", UrlDecision::Allow)
        .unwrap();
    // Switching decision removes the old entry, not duplicates it.
    store
        .persistent_add_url(1000, "example.com", UrlDecision::Block)
        .unwrap();
    let listed = store.list_urls(1000);
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].1, UrlDecision::Block);
}

#[test]
fn url_validate_rejects_whitespace_and_newline() {
    let (store, _tmp) = fresh_store();
    assert!(store
        .persistent_add_url(1000, "with space", UrlDecision::Allow)
        .is_err());
    assert!(store
        .persistent_add_url(1000, "with\nnewline", UrlDecision::Allow)
        .is_err());
}

#[test]
fn session_state_separate_from_persistent() {
    let (store, _tmp) = fresh_store();
    store.persistent_add_atom(1000, "persistent atom").unwrap();
    store.session_add_atom(1000, "session atom".into());

    let persisted = store.list_atoms(1000, ListScope::Persistent);
    let session = store.list_atoms(1000, ListScope::Session);
    assert_eq!(persisted, vec!["persistent atom"]);
    assert_eq!(session, vec!["session atom"]);
}

#[test]
fn session_clear_drops_only_session() {
    let (store, _tmp) = fresh_store();
    store.persistent_add_atom(1000, "persistent").unwrap();
    store.session_add_atom(1000, "session".into());
    store.session_clear(1000);
    assert!(store.list_atoms(1000, ListScope::Session).is_empty());
    assert_eq!(
        store.list_atoms(1000, ListScope::Persistent),
        vec!["persistent"]
    );
}

#[test]
fn session_write_persists_and_clears() {
    let (store, _tmp) = fresh_store();
    store.session_add_atom(1000, "fresh atom".into());
    {
        let mut state = store.state.lock().unwrap();
        let entry = state.entry(1000).or_default();
        entry.session_urls_allow.insert("good.io".into());
        entry.session_urls_block.insert("bad.io".into());
    }
    let report = store.session_write(1000).unwrap();
    assert_eq!(report.atoms_added, 1);
    assert_eq!(report.urls_allow_added, 1);
    assert_eq!(report.urls_block_added, 1);

    // Session cleared (all entries were valid).
    let (atoms, allow, block, trust) = store.session_summary(1000);
    assert!(atoms.is_empty());
    assert!(allow.is_empty());
    assert!(block.is_empty());
    assert!(trust.is_empty());

    // Persistent contains everything.
    assert_eq!(
        store.list_atoms(1000, ListScope::Persistent),
        vec!["fresh atom"]
    );
    let urls = store.list_urls(1000);
    assert_eq!(urls.len(), 2);
}

#[test]
fn session_write_keeps_invalid_entries_for_review() {
    let (store, _tmp) = fresh_store();
    // Add a valid atom + an invalid one (too short).
    store.session_add_atom(1000, "valid atom".into());
    store.session_add_atom(1000, "xx".into());
    let report = store.session_write(1000).unwrap();
    assert_eq!(report.atoms_added, 1);
    // The invalid one stays in session AND surfaces in the report's
    // `invalid` list so the CLI can show the operator what was
    // rejected and why.
    let session = store.list_atoms(1000, ListScope::Session);
    assert_eq!(session, vec!["xx"]);
    assert_eq!(report.invalid.len(), 1);
    assert_eq!(report.invalid[0].0, "xx");
    assert!(
        report.invalid[0].1.contains("too short"),
        "expected reason to mention 'too short', got: {}",
        report.invalid[0].1
    );
}

#[test]
fn write_round_trips_through_disk() {
    // Test the file format: write, read back via a fresh store
    // pointing at the same data_root.
    let tmp = tempfile::tempdir().unwrap();
    let path_root = tmp.path().to_path_buf();
    {
        let store = TrustStore::new(path_root.clone());
        store.persistent_add_atom(1000, "round-trip atom").unwrap();
        store
            .persistent_add_url(1000, "rt.example", UrlDecision::Allow)
            .unwrap();
    }
    // New store sees the on-disk state.
    let store = TrustStore::new(path_root);
    store.load_persistent(1000).unwrap();
    assert_eq!(
        store.list_atoms(1000, ListScope::Persistent),
        vec!["round-trip atom"]
    );
    let urls = store.list_urls(1000);
    assert_eq!(urls.len(), 1);
    assert_eq!(urls[0].0, "rt.example");
    assert_eq!(urls[0].1, UrlDecision::Allow);
}

#[test]
fn file_parser_strips_inline_metadata() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("atoms.user.txt");
    let mut f = std::fs::File::create(&path).unwrap();
    writeln!(f, "# header comment").unwrap();
    writeln!(f).unwrap();
    writeln!(f, "atom one # added 2026-01-01 via legacy").unwrap();
    writeln!(f, "atom two").unwrap();
    drop(f);
    let read = read_atoms_file(&path).unwrap();
    assert!(read.contains("atom one"));
    assert!(read.contains("atom two"));
    assert_eq!(read.len(), 2);
}

#[test]
fn file_parser_skips_unknown_url_verbs_forward_compat() {
    // Simulates a future entry shape the current parser doesn't
    // recognise. Should not panic; should not surface the entry.
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("urls.decisions.txt");
    let mut f = std::fs::File::create(&path).unwrap();
    writeln!(f, "allow good.io").unwrap();
    writeln!(f, "audit example.com").unwrap();  // future verb
    writeln!(f, "block bad.io").unwrap();
    drop(f);
    let (allow, block) = read_urls_file(&path).unwrap();
    assert_eq!(allow.len(), 1);
    assert_eq!(block.len(), 1);
    assert!(allow.contains("good.io"));
    assert!(block.contains("bad.io"));
}

#[test]
fn session_add_trust_validates_hash_shape() {
    let (store, _tmp) = fresh_store();
    // Good SHA-256 hex.
    store
        .session_add_trust(
            1000,
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        )
        .unwrap();
    assert!(store.is_session_trusted(
        1000,
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    ));
    // Wrong length.
    let err = store.session_add_trust(1000, "short").unwrap_err();
    assert!(err.contains("length"));
    // Non-hex / uppercase.
    let err = store
        .session_add_trust(
            1000,
            "0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef",
        )
        .unwrap_err();
    assert!(err.contains("lowercase"));
}

#[test]
fn persistent_trust_add_then_list_roundtrips() {
    let (store, _tmp) = fresh_store();
    let hash_a = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    let hash_b = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210";
    store.persistent_add_trust(1000, hash_a).unwrap();
    store.persistent_add_trust(1000, hash_b).unwrap();
    let listed = store.list_persistent_trust(1000);
    assert_eq!(listed.len(), 2);
    // Sorted output → hash_a first (starts with 0…).
    assert_eq!(listed[0], hash_a);
    assert_eq!(listed[1], hash_b);
}

#[test]
fn persistent_trust_rejects_bad_shape() {
    let (store, _tmp) = fresh_store();
    let err = store.persistent_add_trust(1000, "short").unwrap_err();
    assert!(err.to_string().contains("length"));
    let err = store
        .persistent_add_trust(
            1000,
            "ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789",
        )
        .unwrap_err();
    assert!(err.to_string().contains("lowercase"));
}

#[test]
fn persistent_trust_round_trip_via_disk() {
    // Write via one store, read via a fresh store pointing at the
    // same data_root — verifies the file format parses cleanly.
    let tmp = tempfile::tempdir().unwrap();
    let path_root = tmp.path().to_path_buf();
    let hash = "deadbeef0000000000000000000000000000000000000000000000000000beef";
    {
        let store = TrustStore::new(path_root.clone());
        store.persistent_add_trust(1000, hash).unwrap();
    }
    let store = TrustStore::new(path_root);
    store.load_persistent(1000).unwrap();
    let listed = store.list_persistent_trust(1000);
    assert_eq!(listed, vec![hash.to_owned()]);
}

#[test]
fn persistent_trust_silently_skips_malformed_legacy_lines() {
    // A hand-edited commands.trusted.txt with one uppercase line
    // (a legacy entry someone uppercased) + one valid line + one
    // comment should load only the valid line. Silent skip is the
    // documented behaviour — surfacing the bad line would
    // lock the operator out of valid entries.
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("1000").join("commands.trusted.txt");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(
        &path,
        "# header comment\n\
         ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789  # legacy uppercase\n\
         0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  # good entry\n\
         truncated # bad shape\n",
    )
    .unwrap();
    let store = TrustStore::new(tmp.path().to_path_buf());
    store.load_persistent(1000).unwrap();
    let listed = store.list_persistent_trust(1000);
    assert_eq!(listed.len(), 1);
    assert_eq!(
        listed[0],
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    );
}

#[test]
fn persistent_trust_idempotent_re_add() {
    let (store, _tmp) = fresh_store();
    let hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    store.persistent_add_trust(1000, hash).unwrap();
    store.persistent_add_trust(1000, hash).unwrap();
    let listed = store.list_persistent_trust(1000);
    assert_eq!(listed.len(), 1);
}

#[test]
fn session_write_persists_trust_into_permanent_file() {
    // Banner `[a]llow always` populates session_trust; the operator
    // later runs `sudo atty-guard session write`; trust hashes
    // should land in the persistent commands.trusted.txt.
    let (store, _tmp) = fresh_store();
    let hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    store.session_add_trust(1000, hash).unwrap();
    let report = store.session_write(1000).unwrap();
    assert_eq!(report.trust_added, 1);
    // session cleared, persistent populated.
    let (_, _, _, session_trust) = store.session_summary(1000);
    assert!(session_trust.is_empty());
    let listed = store.list_persistent_trust(1000);
    assert_eq!(listed, vec![hash.to_owned()]);
}

#[test]
fn session_clear_drops_trust_set() {
    let (store, _tmp) = fresh_store();
    store
        .session_add_trust(
            1000,
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        )
        .unwrap();
    store.session_clear(1000);
    let (_, _, _, trust) = store.session_summary(1000);
    assert!(trust.is_empty());
}

#[test]
fn system_fetched_loads_when_perms_ok() {
    let tmp = tempfile::tempdir().unwrap();
    let users_dir = tmp.path().join("users");
    std::fs::create_dir_all(&users_dir).unwrap();
    let system_path = tmp.path().join("atoms.system.txt");
    std::fs::write(&system_path, "# header\nnc -e\nbash -i >&\n").unwrap();
    // Match our EUID so the perm check passes (test runs as the
    // cargo user, same UID for the file we just wrote).
    let store = TrustStore::new(users_dir);
    let n = store.reload_system_fetched().unwrap();
    assert_eq!(n, 2);
    let listed = store.list_system_fetched();
    // reload_system_fetched stores a pre-sorted snapshot; iterate
    // the Arc'd Vec directly without resorting.
    assert_eq!(listed.as_ref(), &vec!["bash -i >&".to_string(), "nc -e".to_string()]);
}

#[test]
fn system_fetched_refuses_world_writable() {
    let tmp = tempfile::tempdir().unwrap();
    let users_dir = tmp.path().join("users");
    std::fs::create_dir_all(&users_dir).unwrap();
    let system_path = tmp.path().join("atoms.system.txt");
    std::fs::write(&system_path, "nc -e\n").unwrap();
    // Set world-write — perm gate should refuse.
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&system_path, std::fs::Permissions::from_mode(0o666)).unwrap();
    let store = TrustStore::new(users_dir);
    let err = store.reload_system_fetched().unwrap_err();
    assert!(
        err.to_string().contains("group/world-write"),
        "expected perm error, got: {err}"
    );
    // In-memory list stays empty.
    assert!(store.list_system_fetched().is_empty());
}

#[test]
fn system_fetched_refuses_group_writable() {
    // Same perm-gate path as world-writable, but pinned separately
    // so a future change to the mask catches both cases.
    let tmp = tempfile::tempdir().unwrap();
    let users_dir = tmp.path().join("users");
    std::fs::create_dir_all(&users_dir).unwrap();
    let system_path = tmp.path().join("atoms.system.txt");
    std::fs::write(&system_path, "nc -e\n").unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&system_path, std::fs::Permissions::from_mode(0o620)).unwrap();
    let store = TrustStore::new(users_dir);
    let err = store.reload_system_fetched().unwrap_err();
    assert!(err.to_string().contains("group/world-write"));
    assert!(store.list_system_fetched().is_empty());
}

#[test]
fn system_fetched_empty_file_loads_zero_atoms() {
    // Empty / comment-only file should load cleanly with zero
    // atoms. Used as the "fresh install, fetch hasn't run yet"
    // shape — the file might exist (e.g. systemd's
    // StateDirectory= pre-creates it) but contain only the
    // generated header.
    let tmp = tempfile::tempdir().unwrap();
    let users_dir = tmp.path().join("users");
    std::fs::create_dir_all(&users_dir).unwrap();
    let system_path = tmp.path().join("atoms.system.txt");
    std::fs::write(&system_path, "# header only\n# more comment\n\n").unwrap();
    let store = TrustStore::new(users_dir);
    let n = store.reload_system_fetched().unwrap();
    assert_eq!(n, 0);
    assert!(store.list_system_fetched().is_empty());
}

#[test]
fn system_fetched_missing_file_is_ok() {
    // No atoms.system.txt yet — reload returns 0, no error. Matches
    // the "fresh install before any fetcher run" state.
    let tmp = tempfile::tempdir().unwrap();
    let users_dir = tmp.path().join("users");
    std::fs::create_dir_all(&users_dir).unwrap();
    let store = TrustStore::new(users_dir);
    let n = store.reload_system_fetched().unwrap();
    assert_eq!(n, 0);
    assert!(store.list_system_fetched().is_empty());
}

#[test]
fn civil_from_days_known_values() {
    // 1970-01-01 → epoch day 0.
    assert_eq!(civil_from_days(0), (1970, 1, 1));
    // Pre-epoch: 1969-12-31 → day -1.
    assert_eq!(civil_from_days(-1), (1969, 12, 31));
    // 2000-01-01 → 30 years + 7 leap days (1972/76/80/84/88/92/96)
    // since 1970-01-01 — confirm the year boundary is handled.
    let (y, m, d) = civil_from_days(10957);
    assert_eq!((y, m, d), (2000, 1, 1));
    // Sanity: leap-year Feb 29.
    let (y, m, d) = civil_from_days(11017); // 2000-03-01 is day 11017
    assert_eq!((y, m, d), (2000, 3, 1));
}

#[test]
fn write_includes_metadata_stamp() {
    let (store, _tmp) = fresh_store();
    store.persistent_add_atom(1000, "stamp test").unwrap();
    let path = store
        .data_root
        .join("1000")
        .join("atoms.user.txt");
    let content = std::fs::read_to_string(&path).unwrap();
    // Metadata format: `<atom> # added <YYYY-MM-DD> via atoms add`.
    assert!(content.contains("stamp test"));
    assert!(content.contains("# added"));
    assert!(content.contains("atoms add"));
    // Round-trip: parser strips the metadata cleanly.
    let parsed = read_atoms_file(&path).unwrap();
    assert_eq!(parsed.len(), 1);
    assert!(parsed.contains("stamp test"));
}

#[test]
fn concurrent_persistent_add_trust_preserves_all_hashes() {
    // GPT-review #024: thread-per-connection means two
    // persistent_add_trust calls for the same UID can race their
    // RMW cycles and lose hashes. Spawn N threads each adding a
    // distinct hash and assert the final file contains all N.
    // Pre-fix this would intermittently land at <N entries.
    let (store, _tmp) = fresh_store();
    let store = std::sync::Arc::new(store);
    let uid = 1000;
    const N: usize = 16;
    let mut handles = Vec::new();
    for i in 0..N {
        let s = store.clone();
        handles.push(std::thread::spawn(move || {
            // 64 lowercase hex chars; encode `i` into the prefix
            // so each thread's hash is distinct + validating.
            let hash = format!("{:064x}", i + 0x1000);
            s.persistent_add_trust(uid, &hash).unwrap();
        }));
    }
    for h in handles {
        h.join().unwrap();
    }
    let listed = store.list_persistent_trust(uid);
    assert_eq!(
        listed.len(),
        N,
        "concurrent persistent_add_trust lost updates: expected {N}, got {} — {listed:?}",
        listed.len(),
    );
}

#[test]
fn concurrent_persistent_add_atom_preserves_all_atoms() {
    // Companion to the trust-hash race test: atoms.user.txt
    // takes the same per-UID write lock, so concurrent adds
    // should likewise lose nothing.
    let (store, _tmp) = fresh_store();
    let store = std::sync::Arc::new(store);
    let uid = 1000;
    const N: usize = 16;
    let mut handles = Vec::new();
    for i in 0..N {
        let s = store.clone();
        handles.push(std::thread::spawn(move || {
            let atom = format!("test-atom-{i:03}-with-some-bytes");
            s.persistent_add_atom(uid, &atom).unwrap();
        }));
    }
    for h in handles {
        h.join().unwrap();
    }
    let listed = store.list_atoms(uid, ListScope::Persistent);
    assert_eq!(listed.len(), N, "lost atoms in concurrent add: {listed:?}");
}

#[test]
fn session_write_retains_cap_blocked_trust_for_retry() {
    // GPT-review #025: when commands.trusted.txt is at
    // PERSISTENT_TRUST_CAP, valid session trust hashes that can't
    // be persisted should stay in session_trust so the operator
    // can prune the file + re-run `session write`. Prior shape
    // dropped them on cleanup (only kept malformed hashes).
    use std::collections::HashSet;
    let (store, _tmp) = fresh_store();
    let uid = 1000;

    // Pre-fill the persistent file to exactly the cap.
    let pre_hashes: HashSet<String> = (0..PERSISTENT_TRUST_CAP)
        .map(|i| format!("{:064x}", i))
        .collect();
    let trust_path = store
        .data_root
        .join(uid.to_string())
        .join("commands.trusted.txt");
    ensure_parent_dir(&trust_path).unwrap();
    write_trust_file(&trust_path, &pre_hashes).unwrap();
    store.load_persistent(uid).unwrap();

    // Now add a fresh session trust hash that would push the
    // file past the cap.
    let extra =
        "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef".to_owned();
    store.session_add_trust(uid, &extra).unwrap();

    let report = store.session_write(uid).unwrap();
    assert_eq!(report.trust_added, 0, "no new persistence expected");
    assert_eq!(report.invalid.len(), 0, "hash is well-formed");
    assert_eq!(
        report.not_persisted.len(),
        1,
        "cap-full hash should land in not_persisted, got {report:?}"
    );
    assert!(report.not_persisted[0].1.contains("trust file full"));

    // Session must still contain the unpersisted hash so a future
    // retry can pick it up.
    let (_, _, _, session_trust) = store.session_summary(uid);
    assert!(
        session_trust.contains(&extra),
        "cap-blocked hash dropped from session — session_trust={session_trust:?}",
    );
}

#[test]
fn session_write_drops_persisted_trust_keeps_invalid() {
    // Pin the existing happy-path AND the malformed-hash retention
    // shape so the #025 fix doesn't accidentally re-introduce
    // the over-deletion bug.
    let (store, _tmp) = fresh_store();
    let uid = 1000;
    let good = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    let bad = "not-a-hash"; // fails validate_trust_hash
    store.session_add_trust(uid, good).unwrap();
    // session_add_trust validates shape; for the bad case we
    // bypass it by inserting directly into the session set.
    {
        let mut state = store.state.lock().unwrap();
        state
            .entry(uid)
            .or_default()
            .session_trust
            .insert(bad.to_owned());
    }
    let report = store.session_write(uid).unwrap();
    assert_eq!(report.trust_added, 1);
    assert_eq!(report.invalid.len(), 1, "malformed hash should be invalid");
    let (_, _, _, session_trust) = store.session_summary(uid);
    assert!(
        !session_trust.iter().any(|h| h == good),
        "persisted hash should clear from session",
    );
    assert!(
        session_trust.iter().any(|h| h == bad),
        "malformed hash should remain for review",
    );
}

#[test]
fn sweep_stale_tmp_files_unlinks_write_atomic_scratch() {
    // Set up a per-UID dir with a stale tmp file shaped like
    // write_atomic's output: `<file>.tmp.<pid>.<seq>`. Constructing
    // TrustStore::new should sweep it.
    let tmp = tempfile::tempdir().expect("tempdir");
    let data_root = tmp.path();
    let uid_dir = data_root.join("1000");
    std::fs::create_dir_all(&uid_dir).unwrap();
    let stale_tmp = uid_dir.join("atoms.user.txt.tmp.12345.0");
    let keep = uid_dir.join("atoms.user.txt");
    std::fs::write(&stale_tmp, b"crashed write").unwrap();
    std::fs::write(&keep, b"valid content").unwrap();
    let _ = TrustStore::new(data_root.to_path_buf());
    assert!(!stale_tmp.exists(), "stale tmp should be unlinked");
    assert!(keep.exists(), "real file must survive the sweep");
}

#[test]
fn sweep_stale_tmp_files_no_op_on_missing_root() {
    // TrustStore::new on a path that doesn't yet exist must not
    // crash — fresh installs use this path before any per-UID
    // dir has been created.
    let tmp = tempfile::tempdir().expect("tempdir");
    let absent = tmp.path().join("does-not-yet-exist");
    let _ = TrustStore::new(absent);
}

#[test]
fn write_locks_prune_drops_idle_entries_under_cap() {
    // #251 — acquire_write_lock prunes entries whose Arc isn't
    // held by any caller when the map exceeds SOFT_CAP. Stuff the
    // map past the cap with dropped Arcs, then one more acquire
    // → the prune fires and the map shrinks.
    let (store, _tmp) = fresh_store();
    // Drive the map past 1024 by acquiring + immediately dropping
    // for distinct UIDs. Each acquire drops the cloned Arc when
    // `lock` goes out of scope. The map keeps the strong ref.
    for uid in 0u32..1100 {
        let _lock = store.acquire_write_lock(uid);
    }
    let final_acquire = store.acquire_write_lock(9999);
    drop(final_acquire);
    let map = store.write_locks.lock().unwrap();
    // After the prune fires on the 1101st acquire (size > 1024),
    // entries with strong_count == 1 are dropped. The just-acquired
    // 9999 entry is also strong_count == 1 by the time we read here,
    // so the map size after the prune should be small (just the
    // freshly inserted entry, or empty if even that's been pruned
    // — depending on whether the prune runs before or after the
    // entry() insertion).
    assert!(
        map.len() <= 1100,
        "prune should have reduced map size: got {}",
        map.len()
    );
}
