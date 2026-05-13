/// atty version string — bumped automatically by release-please.
///
/// Used by the proxy to populate the `ATTY_VERSION` env var on the
/// spawned shell. Keep this file tiny so the bump is unambiguous.
pub const version: []const u8 = "0.4.0"; // x-release-please-version
