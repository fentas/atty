---
layout: default
title: Architecture
---

# atty — Architecture

## Module layout

```
src/
├── main.zig                  # CLI entry: arg parsing → proxy.run
├── root.zig                  # library entry: re-exports for `@import("atty")`
├── config.zig                # user-editable Suckless-style config
├── proxy.zig                 # poll() loop, signal handling, ghost-text scheduling
├── module.zig                # shared types: Action, Context, Error
├── dispatch.zig              # Dispatcher(modules) — comptime walker
├── pty.zig                   # posix_openpt / grantpt / unlockpt / fork+exec child
├── terminal.zig              # cfmakeraw-equivalent termios guard for our stdin
├── line_state.zig            # best-effort user-input buffer model
├── ansi.zig                  # SGR/CSI helpers + escape stripping
├── ghost.zig                 # ghost-text overlay state machine
├── modules/
│   ├── atuin.zig             # async Atuin module
│   └── guardrail.zig         # dangerous-command confirmation module
├── unit_tests.zig            # entry for `zig build test`
└── test/
    └── integration.zig       # PTY round-trip tests (`zig build itest`)
```

## Comptime composition

The dispatch loop is unrolled at compile time:

```zig
inline for (config.modules, 0..) |M, i| {
    if (comptime @hasDecl(M, "onInput")) {
        switch (try M.onInput(rts[i], ctx, current)) {
            .forward => {},
            .swallow => return .swallow,
            .replace => |b| { current = b; final_action = .{ .replace = b }; },
        }
    }
}
```

Each iteration is a separate, type-checked code path. Modules that
don't declare `onInput` contribute zero bytes to this function.
Removing a module from `config.modules` eliminates *every* call path
through that module — verify with `nm zig-out/bin/atty | grep modulename`.

The `Runtimes` tuple is a heterogeneous tuple of *pointers* to each
module's runtime, built via `std.meta.Tuple`. Pointers (rather than
values) for two reasons:

1. Stable heap addresses let modules hold long-lived self-references
   (the Atuin worker thread captures `*Shared`).
2. Zig's strict "no comptime-var pointer at runtime" check
   fires when dispatch takes `&tuple[i]` on a value tuple. Pointers
   sidestep this.

`attachAll` heap-allocates one Runtime per module at startup;
`detachAll` frees them in order on shutdown.

## Data flow

```
                            ┌───────────────────────┐
       (user keyboard) ───▶ │ stdin (poll fd 0)     │
                            └───────────────────────┘
                                       │
                                       ▼
                    ┌──────────────────────────────────────┐
                    │  Dispatcher.dispatchInput             │
                    │  ───────────────────────              │
                    │  guardrail.onInput → atuin.onInput    │
                    │                                       │
                    │  short-circuits on .swallow           │
                    └──────────────────────────────────────┘
                                       │
              ┌────────────────────────┴───────────────────────┐
              │ Action.forward / .replace                       │
              │   → write(master, …)                            │
              │ Action.swallow                                  │
              │   → do nothing (keystroke eaten)                │
              └─────────────────────────────────────────────────┘

      (shell stdout) ◀────  ┌──────────────────────────┐ ◀── read(master)
                            │ dispatchOutput            │
                            │ (observe-only; no mutation)
                            └──────────────────────────┘
                                       │
                                       ▼
                            write(stdout, output)
                                       │
                                       ▼
                            renderGhost() — gatherGhostText,
                            render dim/italic after the cursor
                            (or clear if no module wants one)

      (poll() timeout) ───▶ dispatchTick(elapsed_ms)
                            (TTL expiry, status indicators)
```

## Why a low-level PTY dance?

We use `posix_openpt(3)` → `grantpt(3)` → `unlockpt(3)` → `ptsname(3)`
instead of `openpty(3)` / `forkpty(3)` from `libutil`. Three reasons:

1. **Smaller link surface.** Only libc, no libutil.
2. **Explicit lifecycle.** We own the master fd from the moment it's
   allocated; the slave fd lives only inside the child between
   `setsid()`/`ioctl(TIOCSCTTY)` and `dup2()`.
3. **No BSD-isms.** `openpty` allocates a name buffer for the caller;
   we don't need that.

## Termios raw mode

We put **our** stdin into raw mode but leave the **child's** terminal
alone — the kernel sets up a fresh termios on the slave, and the
shell configures it however it wants (canonical for prompts, raw for
`vim`, etc.).

| Group | Flag           | Off because…                                          |
|-------|----------------|-------------------------------------------------------|
| iflag | IGNBRK/BRKINT  | Don't translate breaks; the shell sees raw bytes.     |
| iflag | ICRNL/INLCR    | CR ≠ LF. Conflating them breaks heredocs and editors. |
| iflag | IXON           | No XON/XOFF flow control on a local TTY.              |
| oflag | OPOST          | No \n → \r\n on our own writes; we already emit \r\n. |
| lflag | ECHO/ECHONL    | The shell echoes; doubling would show every key twice.|
| lflag | ICANON         | We want per-keystroke wakeups, not line buffering.    |
| lflag | ISIG           | Ctrl-C is a literal 0x03 to forward; not our SIGINT.  |
| cflag | CSIZE=CS8      | 8-bit clean.                                          |
| cc    | VMIN=1 VTIME=0 | read() blocks until ≥1 byte; no inter-byte timer.     |

A `defer raw.deinit()` restores the original termios on every exit
path including panics — critical, because a crashed atty must not
leave the user's terminal echoless.

## Signal handling

We use the **self-pipe trick**: signal handlers do one
async-signal-safe `write(pipe, &sig, 1)`. The main loop reads from the
pipe inside `poll()` and dispatches:

- **SIGWINCH** — query our stdout's winsize via `TIOCGWINSZ`,
  propagate to the master via `TIOCSWINSZ`. The kernel auto-delivers
  SIGWINCH to the foreground process group inside the PTY, so the
  shell and any full-screen apps (vim, less) all see the resize.
- **SIGCHLD** — `waitpid(child, …, WNOHANG)` to detect child exit and
  drop out of the loop.

Portable (signalfd is Linux-only) and obviously correct.

## Ghost-text rendering

Constraints:
- The shell owns the line; we must never leave dim bytes that the
  shell can scribble over.
- The cursor is always controlled by the shell.

Strategy: before every byte we write to stdout (whether forwarding
shell output OR the user typing), we *clear* any existing overlay
first. After every dispatch where the suggestion might have changed,
we *render-or-clear* the current best suggestion.

`Ghost.show` is idempotent: if the same text is already rendered we
emit nothing — that matters because the proxy re-renders on every
tick (default 100 ms), and naive re-paints would flicker.

| Sequence       | Meaning                                              |
|----------------|------------------------------------------------------|
| ESC 7          | DECSC — save cursor + attributes                     |
| ESC 8          | DECRC — restore cursor + attributes                  |
| CSI 2 m        | SGR dim (≈ 50% intensity in most terminals)          |
| CSI 3 m        | SGR italic (secondary cue; ignored gracefully)       |
| CSI 0 m        | SGR reset                                            |
| CSI K          | EL — erase to end of line                            |

## Line-state model

Approximates what the user has typed, *not* what the shell currently
thinks the line is. We handle:

- Printable ASCII → append
- 0x7F / 0x08 → backspace
- 0x15 → kill line
- 0x17 → kill previous word
- 0x03 / 0x04 → clear
- 0x0D / 0x0A → submit + clear

Anything else (arrow keys, ESC sequences, tab, ctrl-R, vi mode) flips
an `uncertain` flag. While uncertain, providers suppress ghost text
until the next newline. **Stale suggestions are worse than no
suggestions** — this is the safety invariant.

## Concurrency

The proxy is single-threaded except that each module may own a
background worker thread.

The Atuin module uses a one-slot mailbox:

```
main thread          shared (mutex)              worker thread
───────────          ──────────────              ─────────────
on keystroke ─────▶  req_buf  ───────────────▶  read latest
                     req_gen ↑                   run lookup
                                                 res_buf  ◀──── write result
                     res_gen ↑
provideGhostText ◀── read res_buf
```

Coalescing falls out naturally: each new keystroke overwrites the
pending request, so the worker only ever sees the most recent state.
No queue, no backpressure.

## Future work

- **OSC 133** prompt-marker awareness — the shell can emit `OSC 133 ; A`
  before each prompt; using that, we could throw away half of our
  line-state guesswork.
- **Atuin daemon socket** — once Atuin's IPC stabilises, swap the
  subprocess backend for a long-lived Unix socket.
- **Bracketed-paste detection** — suppress ghost text during a paste
  burst.
- **PTY ring buffer** — needed only if a future module wants to
  parse fragmented ANSI sequences in `onOutput` (e.g. an OSC 133
  parser); core path doesn't need it.
