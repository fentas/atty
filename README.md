<h3 align="center">
	<img width="240" alt="atty" src="./logo.svg">
</h3>

<p align="center">
	<a href="https://github.com/fentas/atty/stargazers">
		<img alt="Stargazers" src="https://img.shields.io/github/stars/fentas/atty?style=for-the-badge&logo=starship&color=C9CBFF&logoColor=D9E0EE&labelColor=302D41"></a>
	<a href="https://github.com/fentas/atty/releases/latest">
		<img alt="Latest release" src="https://img.shields.io/github/v/release/fentas/atty?style=for-the-badge&logo=github&color=F2CDCD&logoColor=D9E0EE&labelColor=302D41"/></a>
	<a href="https://github.com/fentas/atty/actions/workflows/ci.yml">
		<img alt="CI" src="https://img.shields.io/github/actions/workflow/status/fentas/atty/ci.yml?style=for-the-badge&logo=github&logoColor=D9E0EE&labelColor=302D41&color=A6E3A1&label=ci"></a>
	<a href="https://atty.sh">
		<img alt="atty.sh" src="https://img.shields.io/badge/site-atty.sh-89DCEB?style=for-the-badge&logo=googlechrome&logoColor=D9E0EE&labelColor=302D41"></a>
	<a href="https://ziglang.org/">
		<img alt="Zig 0.13" src="https://img.shields.io/badge/zig-0.13.0-F2CDCD?style=for-the-badge&logo=zig&logoColor=D9E0EE&labelColor=302D41"></a>
</p>

&nbsp;

<p align="left">

`atty` is a **Suckless-style PTY proxy** in Zig. It sits between your terminal emulator (Ghostty, Alacritty, kitty…) and your shell, and composes its middleware **at compile time** instead of loading plugins at runtime. Edit `src/config.zig`, recompile — that is the entire configuration model.

Features:

- **Comptime module dispatch** — `inline for` over your config tuple; disabled modules contribute *zero bytes* to the binary
- **Atuin autosuggestions** — fish-style dim/italic ghost text from your shell history, via an async worker thread
- **Dangerous-command guardrail** — swallows Enter on `rm -rf /`, `dd if=…`, `… | sh`, fork bombs, and friends, then waits for a confirm
- **Five hooks per module**: `attach` / `detach` / `onInput` / `onOutput` / `provideGhostText` / `onTick` — implement what you need, the rest is statically dropped
- **Single static binary** — musl-linked, no libutil, no runtime deps; `ghcr.io/fentas/atty:latest` is ~14 MB
- **Zero-allocation hot path** — per-keystroke dispatch does no heap traffic; Atuin lookups happen on a worker thread

</p>

&nbsp;

### 🐚 What it looks like

```text
$ git checkout featu re/auth-refactor                     ← dim italic ghost text
                    ^^^^^^^^^^^^^^^^^

$ rm -rf /home/work/
! atty guardrail: rm -rf on a root-ish path
        line: rm -rf /home/work/
        press Enter again to confirm, any other key to cancel.
```

A live, animated demo lives on [atty.sh](https://atty.sh).

&nbsp;

### 🚀 Install

```bash
# Option 1 — pre-built binary (no toolchain on your host)
curl -fsSL https://github.com/fentas/atty/releases/latest/download/atty-linux-x86_64 \
    -o /usr/local/bin/atty && chmod +x /usr/local/bin/atty

# Option 2 — build inside Docker, drop the binary in ./dist
./scripts/install.sh

# Option 3 — pull the OCI image
docker pull ghcr.io/fentas/atty:latest
```

Then make it your terminal's startup command. Ghostty (`~/.config/ghostty/config`):

```
command = /usr/local/bin/atty
```

Or invoke ad-hoc:

```bash
atty                    # spawns $SHELL through the proxy
atty --shell /bin/bash  # different shell
atty -- -c 'echo hi'    # passthrough args after `--`
```

&nbsp;

### 🛠 Configure

`atty` has no runtime config file. Edit [`src/config.zig`](src/config.zig), recompile, done.

```zig
const atty = @import("atty");

pub const Guardrail = atty.modules.guardrail.configure(.{
    // .rules = &.{
    //     .{ .name = "git-force",
    //        .kind = .{ .substring = "git push --force" },
    //        .reason = "force-pushing to a shared branch" },
    // },
});

pub const Atuin = atty.modules.atuin.configure(.{
    .backend           = .subprocess,
    .search_mode       = .prefix,
    .filter_mode       = .global,
    .suggestion_ttl_ms = 5_000,
});

pub const modules          = .{ Guardrail, Atuin };  // order = priority
pub const tick_interval_ms : i32 = 100;
```

To track a config outside the repo:

```bash
make CONFIG=/path/to/mine.zig build
# or
zig build -Dconfig=/path/to/mine.zig
```

&nbsp;

### ✍️ Writing a module

A module is a Zig type — typically returned from `configure(comptime cfg) type` — with some subset of these decls:

| Hook                 | Called when                                | Hot path |
|----------------------|--------------------------------------------|----------|
| `attach(allocator)`  | once at startup                            | no       |
| `detach(rt)`         | once at shutdown                           | no       |
| `onInput`            | every keystroke from the user              | **yes**  |
| `onOutput`           | every chunk from the shell                 | **yes**  |
| `provideGhostText`   | when atty wants to render an overlay       | yes      |
| `onTick`             | on poll() timeout (default 100 ms)         | no       |

Minimal example — uppercase every keystroke:

```zig
pub fn configure(comptime _: Config) type {
    return struct {
        pub const Runtime = struct { buf: [256]u8 = undefined };
        pub fn attach(_: std.mem.Allocator) !Runtime { return .{}; }
        pub fn detach(_: *Runtime) void {}
        pub fn onInput(rt: *Runtime, _: *m.Context, in: []const u8) m.Error!m.Action {
            for (in, 0..) |b, i| rt.buf[i] = std.ascii.toUpper(b);
            return .{ .replace = rt.buf[0..in.len] };
        }
    };
}
```

Full walkthrough: [docs/modules.md](docs/modules.md) or [atty.sh/modules](https://atty.sh/modules/).

&nbsp;

### 🐳 Using Docker

```bash
# Run atty inside a container
docker run --rm -it ghcr.io/fentas/atty:latest

# Copy the binary out of the image
docker create --name atty-tmp ghcr.io/fentas/atty:latest && \
  docker cp atty-tmp:/usr/local/bin/atty ./atty && \
  docker rm atty-tmp
```

Or use it as a base layer in your own image:

```dockerfile
FROM alpine:3.20
COPY --from=ghcr.io/fentas/atty:latest /usr/local/bin/atty /usr/local/bin/atty
ENTRYPOINT ["atty"]
```

The image is multi-arch (`linux/amd64`, `linux/arm64`) and the binary is musl-static.

&nbsp;

### 📦 Built-in modules

| Module                                                | Hook surface                              | Purpose                                                                |
|-------------------------------------------------------|-------------------------------------------|------------------------------------------------------------------------|
| [`atuin`](src/modules/atuin.zig)                      | `onInput`, `provideGhostText`, `onTick`   | Fish-style autosuggestions from your Atuin history                     |
| [`guardrail`](src/modules/guardrail.zig)              | `onInput`                                 | Confirm-on-Enter for `rm -rf /`, `dd`, `mkfs`, fork bombs, curl-pipe-sh |

Add your own under `src/modules/` and wire it into `config.modules`. Reference docs: [atty.sh/providers](https://atty.sh/providers/).

&nbsp;

### 🧪 Build from source

```bash
mise use zig@0.13.0           # any other Zig 0.13.0 install also works
zig build                     # → ./zig-out/bin/atty
zig build test --summary all  # 33 unit tests
zig build itest --summary all # PTY round-trip integration test
```

Or via Make:

```bash
make build         # ReleaseSafe
make test itest
make install       # → ~/.local/bin/atty
make docker        # local image
make docker-binary # build in docker, copy binary to ./dist/atty
```

`make help` lists every target.

&nbsp;

### 🎯 Roadmap

- [ ] OSC 133 prompt-marker awareness (drop guesswork from the line-state model)
- [ ] Atuin daemon socket backend (replace the subprocess fallback once IPC stabilises)
- [ ] Bracketed-paste detection (suppress ghost text during a paste burst)
- [ ] Ring buffer for `onOutput` parsers that span read boundaries
- [ ] BSD / macOS support (currently Linux-only; PTY dance needs `ioctl(TIOCPTYGRANT)` glue on Darwin)

&nbsp;

### 🤝 Contributing

PRs welcome. The flow is **feat/fix conventional-commit PR → release-please opens a release PR → merging the release PR cuts a tag and ships binaries**. Details and PR-title rules in [CONTRIBUTING.md](CONTRIBUTING.md).

Before pushing: `make fmt && make test`.

&nbsp;

### 📜 License

Pending. (`atty` is currently unlicensed — that will change before `v1.0.0`; until then, treat the source as "all rights reserved" and contact the maintainers for any use beyond reading.)

&nbsp;

### ❤️ Gratitude

- [Atuin](https://github.com/atuinsh/atuin) — the history daemon this proxies for.
- [Suckless](https://suckless.org) — for the *config.h, recompile, ship* aesthetic this whole project apes.
- [Ghostty](https://ghostty.org), [Alacritty](https://alacritty.org), [kitty](https://sw.kovidgoyal.net/kitty/) — the terminal emulators atty plays in front of.
- [Zig](https://ziglang.org) — for making `inline for` + `@hasDecl` a viable plugin model.
- Inspiration on the README treatment and conventional-commit release flow lifted from [fentas/b](https://github.com/fentas/b).

&nbsp;

<p align="center">Copyright &copy; 2026-present <a href="https://github.com/fentas" target="_blank">fentas</a></p>
<p align="center"><a href="https://atty.sh"><img src="https://img.shields.io/static/v1.svg?style=for-the-badge&label=atty&message=.sh&logoColor=d9e0ee&colorA=302d41&colorB=89dceb"/></a></p>
