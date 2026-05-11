# Contributing to atty

Thanks for your interest. atty is small and opinionated; the
contribution model matches that.

## TL;DR

1. Pick a piece of work.
2. Open a PR. **PR title** must be a [conventional commit].
3. Merge with **Squash and merge** (we keep history linear).
4. Repeat. release-please opens / updates a release PR automatically.
5. When you (a maintainer) merge the release PR, a `vX.Y.Z` tag is
   created and the [release workflow] publishes binaries + a Docker
   image.

[conventional commit]: https://www.conventionalcommits.org/
[release workflow]: .github/workflows/release.yml

## PR title format

```
<type>: <short imperative summary, no trailing punctuation>
```

Allowed types — and what they do to the next release:

| Type        | Bumps     | Shows in CHANGELOG | Use for                           |
|-------------|-----------|--------------------|-----------------------------------|
| `feat`      | **minor** | yes                | a new module, new hook, new flag  |
| `fix`       | **patch** | yes                | bug fixes                         |
| `perf`      | patch     | yes                | speedups, allocation reductions   |
| `refactor`  | patch     | yes                | non-behavioural restructuring     |
| `docs`      | —         | yes                | README, /docs, code comments      |
| `test`      | —         | hidden             | unit / integration tests          |
| `build`     | —         | hidden             | build.zig, Dockerfile, Makefile   |
| `ci`        | —         | hidden             | .github/workflows                 |
| `chore`     | —         | hidden             | tidying, dep bumps, etc.          |
| `revert`    | —         | yes                | revert of an earlier commit       |
| `style`     | —         | hidden             | `zig fmt` and the like            |

### Breaking changes

Append `!` to the type or include a `BREAKING CHANGE:` line in the
body to force a **major** bump:

```
feat!: rename ctx.line to ctx.input

BREAKING CHANGE: existing modules calling ctx.line.current() must
update to ctx.input.current().
```

### Examples

✅
- `feat: add OSC 133 prompt-marker awareness`
- `fix: clear ghost overlay before SIGWINCH propagates`
- `perf: avoid per-keystroke allocation in Guardrail.check`
- `docs: add example for writing a custom module`
- `chore: bump zig to 0.16.0`

❌
- `Add OSC 133 support` (missing type)
- `feat: Added OSC 133 support.` (capitalised, past tense, trailing dot)
- `feat(stuff): change things` (vague subject; we don't gain by
  guessing what "stuff" means)

## Local checks

Before pushing, run the same checks CI runs:

```sh
make fmt          # zig fmt src/ build.zig
make test itest   # unit + integration tests
zig build         # final compile
```

CI runs `zig fmt --check`, so anything that wasn't formatted will
fail there.

## Architecture pointers

If you're adding behaviour:

- **A new module** — read [docs/modules.md](docs/modules.md), then
  drop a file under `src/modules/` and wire it into `src/config.zig`.
- **A core change** — read [docs/architecture.md](docs/architecture.md)
  first; it has the rationale for the proxy loop, ghost-text rendering,
  signal handling, and the comptime dispatcher.

Match the existing style (Zig 0.16 idioms; doc comments explaining
*why*, not what; no allocations in `onInput`).

## Release flow (maintainers)

1. Conventional-commit PRs accumulate on `main`.
2. The [release-please workflow] notices and maintains
   `chore(release): X.Y.Z`. Each push to `main` updates that PR's
   diff (CHANGELOG, version bump in `build.zig.zon`).
3. When the changes feel ready to ship, **merge the release PR**.
4. release-please pushes a `vX.Y.Z` tag.
5. The [release workflow] runs — cross-compiles musl binaries for
   x86_64 and aarch64, attaches them + checksums to the GitHub
   Release, and pushes a multi-arch image to
   `ghcr.io/fentas/atty:vX.Y.Z` (plus `latest`, `X.Y`, `X`).

[release-please workflow]: .github/workflows/release-please.yml

You shouldn't need to write CHANGELOG entries by hand; release-please
groups commits by type per the config in `release-please-config.json`.
If you need to influence wording in the changelog, edit the commit
message itself (before merge), not the changelog file.

## License

atty is [MIT licensed](LICENSE). By contributing you agree your
changes will be released under the same terms.
