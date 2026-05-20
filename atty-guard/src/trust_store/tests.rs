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
