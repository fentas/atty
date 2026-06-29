# harness — a composable TTY test framework ("Playwright for the terminal")

Drive a real terminal program under a PTY, assert on the **rendered screen**,
record the session, and inject faults — composed Suckless-style from a module
tuple in `config.zig`. Full docs: [`docs/harness.md`](../../docs/harness.md).

```sh
zig build harness        # build the configured binary
zig build run-harness    # run the example (drives bash, asserts on screen)
zig build test-harness   # run the unit tests
```

## Layout

| File | Role |
|---|---|
| `harness.zig` | `Harness(modules)` — the composed driver (engine + pump + lifecycle fan). `Harness(.{})` is the bare engine. |
| `module.zig` | the module contract (the `@hasDecl`-gated hook set) + `SessionInfo` + the clock. |
| `pty.zig` | open a PTY, fork, controlled-env `execvpe`. |
| `io.zig` | tiny runtime file helpers over `std.c` (0.16 has no `std.fs.cwd()`). |
| `config.def.zig` → `config.zig` | the dwm-style module-tuple template / gitignored override. |
| `modules/` | built-ins: `snapshotter`, `cast_recorder`, `fragment_injector`. |
| `main.zig` | the configured binary — the example scenario (driving bash). |

Depends only on the `vt` grid module (self-contained PTY; its own small
cast/snapshot bits). Add a module by writing a struct with the hook shape and
dropping it into the `modules` tuple — same contract as atty's proxy modules.
