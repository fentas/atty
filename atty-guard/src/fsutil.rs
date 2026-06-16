//! Small filesystem-durability helpers shared by the atomic-write
//! paths (trust_store, atom_drift, atom_fetcher, cli_client). The
//! pattern is always: write tmp → `f.sync_all()` (content durable) →
//! rename → `fsync_parent_dir` (the rename itself durable).

use std::path::Path;

/// fsync the directory that contains `path` so a rename INTO it survives
/// a crash / power loss — `sync_all` on the file makes the bytes durable,
/// but the directory entry (the new name) needs its own fsync to persist.
///
/// Best-effort: callers invoke this AFTER the write+rename already
/// succeeded, so a parent that can't be opened or synced (rare — e.g. a
/// revoked dir handle) isn't worth failing a completed operation over.
pub fn fsync_parent_dir(path: &Path) {
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    if let Ok(dir) = std::fs::File::open(parent) {
        let _ = dir.sync_all();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fsync_parent_dir_succeeds_for_a_real_file() {
        // Best-effort contract: never panics; syncs the containing dir
        // for a normal path. We can't observe the fsync directly, but a
        // valid parent must not error the process.
        let tmp = tempfile::tempdir().unwrap();
        let file = tmp.path().join("atoms.user.txt");
        std::fs::write(&file, b"x").unwrap();
        fsync_parent_dir(&file); // must not panic
    }

    #[test]
    fn fsync_parent_dir_is_noop_for_a_bare_filename() {
        // A path with no directory component falls back to "." and must
        // still not panic (the open may fail; that's swallowed).
        fsync_parent_dir(Path::new("just-a-name"));
    }
}
