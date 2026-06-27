# atty — top-level build entry.
#
# Most targets shell out to `zig`. The `docker-*` targets let users
# build without installing Zig locally.

ZIG ?= zig
CARGO ?= cargo
PREFIX ?= $(HOME)/.local
OPT ?= ReleaseSafe

# atty-guard (Rust sidecar) Cargo features. Defaults match the
# release-artifact build: full classifier (ONNX SLM), live OSV.dev
# lookup for npm misses, and the atom fetcher. eBPF is opt-in —
# `make GUARD_FEATURES=tier2-onnx,osv-live,atoms-fetch,ebpf …`.
# eBPF additionally needs `libbpf-dev` on the build host AND
# `AmbientCapabilities=CAP_BPF` on the system unit at runtime.
GUARD_FEATURES ?= tier2-onnx,osv-live,atoms-fetch

# Default target picks the path that builds reliably on the host:
#   • Linux  → x86_64-linux-musl. CI uses this too; it sidesteps the
#     Arch gcc-16 crt1.o SFrame-reloc issue (R_X86_64_PC64) that
#     Zig 0.16's linker can't handle when linking against the
#     system libc. Musl ships its own crt, so the failure mode
#     doesn't apply.
#   • Anything else (Darwin, BSD, …) → native, since libutil-less
#     PTY work compiles fine there and we don't have a canned
#     cross-target that's strictly better.
# Override with `make TARGET=… <goal>` (e.g. aarch64-linux-musl).
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Linux)
TARGET ?= x86_64-linux-musl
else
TARGET ?= native
endif

# `make CONFIG=path/to/mine.zig build` to use an out-of-tree config.
ifdef CONFIG
ZIG_CONFIG_ARG := -Dconfig=$(CONFIG)
endif

# Centralise the installed-binary path so install / link / register-
# shell agree on what to touch.
ATTY_BIN := $(PREFIX)/bin/atty

.PHONY: help build build-atty build-guard debug test test-atty test-guard itest e2e e2e-update integration-test integration-test-full run \
        install install-atty install-guard link link-atty link-guard unlink unlink-atty unlink-guard \
        register-shell unregister-shell \
        clean clean-atty clean-guard docker docker-binary fmt fmt-atty fmt-guard reload-guard \
        sandbox sandbox-rebuild sandbox-base-image sandbox-onnx sandbox-onnx-image sandbox-ebpf sandbox-ebpf-image

help:
	@printf "atty — build targets\n\n"
	@printf "Build (default = both subprojects)\n"
	@printf "  build           Build everything (atty + atty-guard).\n"
	@printf "  build-atty      Build only atty → zig-out/bin/atty (ReleaseSafe).\n"
	@printf "  build-guard     Build only atty-guard → atty-guard/target/release/atty-guard.\n"
	@printf "                  Features: $(GUARD_FEATURES).\n"
	@printf "  debug           atty in Debug mode.\n"
	@printf "                  Run with ATTY_TRACE=1 for diagnostic stderr logs\n"
	@printf "                  (categories: input,keymap,csiu,dispatch,forward,\n"
	@printf "                   altscreen,paint,cursor; comma-sep or '1'/'all').\n\n"
	@printf "Test\n"
	@printf "  test            Run both atty + atty-guard unit tests.\n"
	@printf "  test-atty       Run only atty unit tests.\n"
	@printf "  test-guard      Run only atty-guard unit tests (default + feature-on).\n"
	@printf "  itest           Run atty integration tests (real PTY).\n"
	@printf "  e2e             Run end-to-end scenarios under tests/e2e/.\n"
	@printf "  e2e-update      Refresh e2e goldens from current output.\n"
	@printf "  integration-test       Run atty ↔ guard ↔ SLM integration tests (no external deps).\n"
	@printf "  integration-test-full  Same + Ollama / ONNX / atom-fetcher scenarios (skip when deps absent).\n\n"
	@printf "Install (default = both subprojects)\n"
	@printf "  install         Copy atty binary to \$$PREFIX/bin AND run atty-guard installer.\n"
	@printf "  install-atty    Only copy zig-out/bin/atty to \$$PREFIX/bin (default: ~/.local/bin).\n"
	@printf "  install-guard   Only build + run atty-guard/contrib/install.sh.\n"
	@printf "                  Requires sudo. Creates the atty user/group, installs the system\n"
	@printf "                  unit to /etc/systemd/system/, enables + starts atty-guard.service.\n\n"
	@printf "Link / unlink (default = both subprojects)\n"
	@printf "  link            Symlink BOTH \$$PREFIX/bin/atty and \$$PREFIX/bin/atty-guard.\n"
	@printf "  link-atty       Only symlink \$$PREFIX/bin/atty -> this clone's zig-out/bin/atty.\n"
	@printf "  link-guard      Only symlink \$$PREFIX/bin/atty-guard -> atty-guard/target/release/atty-guard.\n"
	@printf "  unlink          Remove BOTH symlinks (only if they're symlinks).\n"
	@printf "  unlink-atty     Only remove the atty symlink.\n"
	@printf "  unlink-guard    Only remove the atty-guard symlink.\n\n"
	@printf "Shell registration\n"
	@printf "  register-shell  Append \$$PREFIX/bin/atty to /etc/shells (needs sudo;\n"
	@printf "                  idempotent). DE/WM \"new-terminal-window\" helpers that\n"
	@printf "                  inherit cwd by walking the focused process and matching\n"
	@printf "                  /proc/<pid>/exe against /etc/shells (omarchy's\n"
	@printf "                  omarchy-cmd-terminal-cwd, several i3/Sway scripts) will\n"
	@printf "                  then honour atty as the focused shell and read its cwd.\n"
	@printf "  unregister-shell Remove that line again. Idempotent.\n\n"
	@printf "Run / reload\n"
	@printf "  run             Build atty and run.\n"
	@printf "  reload-guard    systemctl --user restart atty-guard (re-attaches eBPF when built\n"
	@printf "                  with --features ebpf; otherwise just restarts the daemon).\n\n"
	@printf "Misc\n"
	@printf "  fmt             zig fmt src/ + cargo fmt atty-guard.\n"
	@printf "  fmt-atty        Only zig fmt.\n"
	@printf "  fmt-guard       Only cargo fmt atty-guard.\n"
	@printf "  docker          Build the Docker runtime image (atty:latest).\n"
	@printf "  docker-binary   Build the binary in Docker, copy to ./dist/atty.\n"
	@printf "  clean           Remove ALL build artifacts (both subprojects).\n"
	@printf "  clean-atty      Only remove zig-out, .zig-cache, dist.\n"
	@printf "  clean-guard     Only remove atty-guard/target.\n\n"
	@printf "Variables: ZIG=$(ZIG)  CARGO=$(CARGO)  PREFIX=$(PREFIX)  TARGET=$(TARGET)  OPT=$(OPT)\n"
	@printf "           GUARD_FEATURES=$(GUARD_FEATURES)\n"
	@printf "           CONFIG=<path>   custom config.zig location\n"

# Default build target builds BOTH subprojects so a fresh clone +
# `make` lands a complete installable set. The per-subproject targets
# stay available for fast iteration on one side at a time.
build: build-atty build-guard

build-atty:
	$(ZIG) build -Doptimize=$(OPT) -Dtarget=$(TARGET) $(ZIG_CONFIG_ARG)

debug:
	$(ZIG) build -Doptimize=Debug -Dtarget=$(TARGET) $(ZIG_CONFIG_ARG)

test: test-atty test-guard

test-atty:
	$(ZIG) build test -Dtarget=$(TARGET) --summary all

itest:
	$(ZIG) build itest -Dtarget=$(TARGET) --summary all

# End-to-end: spawn atty under a controlled PTY, drive .e2e scripts,
# diff a rendered terminal grid against goldens in tests/e2e/<name>/golden/.
e2e:
	$(ZIG) build e2e -Dtarget=$(TARGET)

# Refresh goldens to match current output. Review the diff before committing.
e2e-update:
	$(ZIG) build e2e -Dtarget=$(TARGET) -- --update

# Integration suite: end-to-end scenarios that boot a real atty-guard
# daemon (+ optionally talk to Ollama and pull atom corpora over the
# network). Lives in `tests/integration/`. See its README for the
# scenario matrix.
integration-test:
	tests/integration/run.sh quick

integration-test-full:
	tests/integration/run.sh full

run: build-atty
	./zig-out/bin/atty

# Meta install — atty binary + atty-guard binary + system unit.
# Run on a fresh clone to land a complete setup. Per-subproject
# variants (`install-atty` / `install-guard`) stay available when you
# only want one side. install-guard requires sudo.
#
# Recursive `$(MAKE)` calls instead of prerequisite-list serialise the
# two steps even under `make -j`: install-guard's contrib/install.sh
# does multi-step systemd setup (user creation, daemon-reload, enable,
# start) that races badly with concurrent installs.
install:
	$(MAKE) install-atty
	$(MAKE) install-guard

install-atty: build-atty
	install -d $(PREFIX)/bin
	install -m 0755 zig-out/bin/atty $(ATTY_BIN)
	@printf "→ installed to %s/bin/atty\n" "$(PREFIX)"

# Meta link — symlink BOTH binaries from this clone. Source-of-truth
# stays in the cargo/zig output dirs; $(PREFIX)/bin just points at them
# so `make build && make reload-guard` picks up changes live.
link: link-atty link-guard

# Symlink the installed binary at $(PREFIX)/bin/atty to this clone's
# zig-out/bin/atty. Same model as get.sh: source is the truth, install
# dir is just a pointer. Re-running `make build` (or `zig build`) here
# updates the live binary with no extra step.
link-atty: build-atty
	install -d $(PREFIX)/bin
	ln -sfn $(CURDIR)/zig-out/bin/atty $(ATTY_BIN)
	@printf "→ linked %s/bin/atty → %s/zig-out/bin/atty\n" "$(PREFIX)" "$(CURDIR)"

# Register atty as a recognised "shell" so cwd-inheriting "new
# terminal window" keybinds in DE/WM scripts (omarchy's
# `omarchy-cmd-terminal-cwd`, several i3 / Sway helpers, gnome-shell
# extensions) honour atty as the focused process's exe.
#
# Background: those scripts walk the focused terminal's process tree
# looking for a `/proc/<pid>/exe` listed in `/etc/shells`, then read
# THAT pid's `/proc/<pid>/cwd` to spawn the new window. When atty
# wraps bash via `exec atty bash` (the default integration), atty
# itself becomes the terminal's direct child — and atty isn't in
# `/etc/shells`, so the script falls through to `$HOME`.
#
# Idempotent — checks first, only appends if absent. Asks sudo
# unless run as root. Targets the binary at $(PREFIX)/bin/atty so a
# `make link` or `make install-atty` ahead of this picks up the
# right path (symlinks are resolved via `readlink -f`).
register-shell:
	@target="$$(readlink -f $(ATTY_BIN) 2>/dev/null || true)"; \
	if [ -z "$$target" ]; then \
	    printf "→ %s not installed — run \`make link\` or \`make install-atty\` first\n" "$(ATTY_BIN)"; exit 1; \
	fi; \
	if [ ! -x "$$target" ]; then \
	    printf "→ %s is not executable — refusing to register\n" "$$target"; exit 1; \
	fi; \
	if [ ! -f /etc/shells ]; then \
	    printf "→ /etc/shells does not exist — refusing to create it (touch it yourself if your distro needs one)\n"; exit 1; \
	fi; \
	if grep -qsxF "$$target" /etc/shells; then \
	    printf "→ %s already in /etc/shells\n" "$$target"; \
	else \
	    printf "→ registering %s in /etc/shells (needs sudo)…\n" "$$target"; \
	    printf '%s\n' "$$target" | sudo tee -a /etc/shells > /dev/null && \
	    printf "✓ %s added to /etc/shells\n" "$$target"; \
	fi

# Inverse of `register-shell` — removes the atty entry. Idempotent.
# Uses a `grep -vxF` rewrite instead of `sed` so paths containing `\`
# or `|` are handled losslessly: sed's `\|...|d` address treats those
# as regex metacharacters (silent no-op on `\`, loud error on `|`).
unregister-shell:
	@target="$$(readlink -f $(ATTY_BIN) 2>/dev/null || true)"; \
	if [ -z "$$target" ]; then \
	    printf "→ %s not installed — nothing to unregister\n" "$(ATTY_BIN)"; exit 0; \
	fi; \
	if [ ! -f /etc/shells ]; then \
	    printf "→ /etc/shells does not exist — nothing to unregister\n"; exit 0; \
	fi; \
	if ! grep -qsxF "$$target" /etc/shells; then \
	    printf "→ %s not in /etc/shells\n" "$$target"; \
	else \
	    printf "→ removing %s from /etc/shells (needs sudo)…\n" "$$target"; \
	    grep -vxF "$$target" /etc/shells | sudo tee /etc/shells.new > /dev/null && \
	    sudo mv /etc/shells.new /etc/shells && \
	    printf "✓ %s removed from /etc/shells\n" "$$target"; \
	fi

# Meta unlink — both subprojects.
unlink: unlink-atty unlink-guard

# Remove the symlink (but never a real file — guarded by [ -L ]).
unlink-atty:
	@if [ -L "$(ATTY_BIN)" ]; then \
	    rm "$(ATTY_BIN)" && printf "→ removed %s\n" "$(ATTY_BIN)"; \
	elif [ -e "$(ATTY_BIN)" ]; then \
	    printf "⚠ %s/bin/atty is a real file, not a symlink — refusing to remove\n" "$(PREFIX)"; exit 1; \
	else \
	    printf "(nothing to unlink)\n"; \
	fi

fmt: fmt-atty fmt-guard

fmt-atty:
	$(ZIG) fmt src/ build.zig

clean: clean-atty clean-guard

clean-atty:
	rm -rf zig-out .zig-cache dist

clean-guard:
	cd atty-guard && $(CARGO) clean --quiet

docker:
	docker build -t atty:latest .

# Build inside Docker but emit the artifact onto the host. Useful when
# you want the binary but don't want Zig on your machine.
docker-binary:
	docker build -t atty:builder --target builder .
	mkdir -p dist
	docker run --rm -v "$$(pwd)/dist":/out atty:builder \
	    cp /src/zig-out/bin/atty /out/atty
	@printf "→ ./dist/atty (%s)\n" "$$(file dist/atty | cut -d: -f2-)"

# ---------------------------------------------------------------------------
# atty-guard — Rust sidecar daemon (V2 security guard backend).
#
# Same shape as the atty targets above: build/install/link/unlink, plus
# `reload-guard` for the daemon-restart half (which also re-attaches eBPF
# when built with --features ebpf). Default features are the user-facing
# release set; eBPF stays opt-in to avoid the libbpf-dev / CAP_BPF
# requirements at build/runtime.
# ---------------------------------------------------------------------------
build-guard:
	cd atty-guard && $(CARGO) build --release --features $(GUARD_FEATURES)

test-guard:
	cd atty-guard && $(CARGO) test --quiet
	cd atty-guard && $(CARGO) test --features $(GUARD_FEATURES) --quiet

fmt-guard:
	cd atty-guard && $(CARGO) fmt

# Full install — binary into /usr/local/bin, system unit into
# /etc/systemd/system/, creates the atty user/group, enables + starts
# the service. Delegates to contrib/install.sh (which re-execs under
# sudo) so the systemd policy stays in one place.
#
# When GUARD_FEATURES contains `ebpf`, also passes --with-ebpf so the
# installer compiles + installs the kernel BPF object to
# /usr/lib/atty-guard/atty_guard.bpf.o and drops in
# /etc/systemd/system/atty-guard.service.d/ebpf.conf with
# CAP_BPF + CAP_PERFMON + CAP_MAC_ADMIN + SystemCallFilter widening +
# --enable-ebpf on ExecStart. The installer verifies the binary
# supports the feature (--print-features) AND that the host has the
# build prerequisites (kernel BTF at /sys/kernel/btf/vmlinux, clang,
# bpftool); it hard-fails — no silent fallback — if any are missing.
install-guard: build-guard
	@printf "→ %s will install + enable atty-guard.service (system daemon — requires sudo)\n" "$@"
	@if echo "$(GUARD_FEATURES)" | tr ',' '\n' | grep -qx ebpf; then \
	    printf "→ GUARD_FEATURES contains 'ebpf' — installing eBPF drop-in\n"; \
	    atty-guard/contrib/install.sh --with-ebpf; \
	else \
	    atty-guard/contrib/install.sh; \
	fi

# Symlink the daemon binary the same way `make link` does for atty:
# source-of-truth is the cargo target dir, $(PREFIX)/bin is just a
# pointer. The daemon must be restarted (`make reload-guard`) for a
# newly-rebuilt binary to actually run — systemd resolves the symlink
# at ExecStart, not on every signal.
link-guard: build-guard
	install -d $(PREFIX)/bin
	ln -sfn $(CURDIR)/atty-guard/target/release/atty-guard $(PREFIX)/bin/atty-guard
	@printf "→ linked %s/bin/atty-guard → %s/atty-guard/target/%s/atty-guard\n" \
	    "$(PREFIX)" "$(CURDIR)" "release"
	@printf "  (run \`make reload-guard\` to pick up changes in a running daemon)\n"

unlink-guard:
	@if [ -L "$(PREFIX)/bin/atty-guard" ]; then \
	    rm "$(PREFIX)/bin/atty-guard" && printf "→ removed %s/bin/atty-guard\n" "$(PREFIX)"; \
	elif [ -e "$(PREFIX)/bin/atty-guard" ]; then \
	    printf "⚠ %s/bin/atty-guard is a real file, not a symlink — refusing to remove\n" "$(PREFIX)"; exit 1; \
	else \
	    printf "(nothing to unlink)\n"; \
	fi

# Restart the systemd unit (system-daemon, post-#140) — needed when
# you rebuild the binary so the new image actually runs. When built
# with --features ebpf the restart also unloads the old kernel-side
# BPF programs (libbpf-rs drops them on process exit) and the new
# daemon re-attaches them on startup. Falls back to the legacy
# systemd-user path for installs that haven't migrated yet.
reload-guard:
	@if ! command -v systemctl >/dev/null 2>&1; then \
	    printf "⚠ systemctl not on \$$PATH — start atty-guard yourself with the new binary\n"; \
	    exit 1; \
	fi
	@sys_unit=/etc/systemd/system/atty-guard.service; \
	user_unit="$${XDG_CONFIG_HOME:-$$HOME/.config}/systemd/user/atty-guard.service"; \
	if [ -f "$$sys_unit" ]; then \
	    sudo systemctl restart atty-guard.service && \
	    printf "→ atty-guard restarted (system daemon; eBPF re-attached if built with --features ebpf)\n"; \
	elif [ -f "$$user_unit" ]; then \
	    systemctl --user restart atty-guard.service && \
	    printf "→ atty-guard restarted (systemd-user — legacy install; consider running \`sudo make install-guard\` to migrate)\n"; \
	else \
	    printf "⚠ atty-guard.service not installed at %s or %s — run \`sudo make install-guard\` first\n" "$$sys_unit" "$$user_unit"; \
	    exit 1; \
	fi

# ─────────────────────────────────────────────────────────────────
# Sandbox tests (#329) — end-to-end scenarios in a docker container
# with real atty + atty-guard binaries. Catches what unit tests
# can't: cross-UID gates, sudo-mediated CLI, install-script
# integration, daemon lifecycle. See tests/sandbox/README.md.
# ─────────────────────────────────────────────────────────────────
# atty-guard is built inside the container (see
# tests/sandbox/Dockerfile.base) so the runtime libc matches the
# build libc. atty is built by the runner with the sandbox config
# (security_guard daemon enabled at the production socket path)
# so the developer's src/config.zig stays untouched.
sandbox:
	@command -v docker >/dev/null 2>&1 || { \
	    printf "⚠ docker not on \$$PATH — install docker to run sandbox tests\n"; \
	    exit 1; \
	}
	@command -v python3 >/dev/null 2>&1 || { \
	    printf "⚠ python3 not on \$$PATH — sandbox runner needs python3\n"; \
	    exit 1; \
	}
	python3 tests/sandbox/runner.py

# Force a full rebuild — drops the cached base image so a stale
# Ubuntu layer or apt mirror outage gets surfaced rather than
# silently reused.
sandbox-rebuild:
	-docker image rm atty-sandbox:base 2>/dev/null || true
	$(MAKE) sandbox

# Build only the base sandbox image (atty + atty-guard) without
# running any scenarios. Used by extending-image targets as a
# prereq so `sandbox-onnx-image` / `sandbox-ebpf-image` don't
# drag in the full base-suite run as a side effect.
sandbox-base-image:
	python3 tests/sandbox/runner.py --build-only

# Extension-image builds (sandbox-onnx-image / sandbox-ebpf-image)
# use the plain docker driver so they can read atty-sandbox:base
# from the LOCAL daemon (runner.py builds the base image with
# --load → ends up in local daemon). The buildx docker-container
# driver enables cache-to but can't see local images even with
# `docker-image://` named contexts — it always tries to pull from
# registry. Workaround would be a local registry sidecar (TODO if
# the extension-image build cost becomes a bottleneck). Base
# image still benefits from the buildx cache via runner.py.

# ── ONNX image (60-onnx-second-stage / 61-onnx-fbas-sized-buffer) ──
# Build the ONNX-baked sandbox image. Requires the operator to
# point at a hosted SecureBERT bundle via the *_URL / *_SHA256
# env vars; without them the build still succeeds but the model
# is NOT baked and scenarios 60/61 SKIP at runtime. See
# tests/sandbox/onnx-models.toml for the pin file format.
sandbox-onnx-image: sandbox-base-image
	DOCKER_BUILDKIT=1 docker build \
	    -t atty-sandbox:onnx \
	    -f tests/sandbox/Dockerfile.onnx \
	    --build-arg MODEL_URL="$$ONNX_MODEL_URL" \
	    --build-arg MODEL_SHA256="$$ONNX_MODEL_SHA256" \
	    --build-arg TOKENIZER_URL="$$ONNX_TOKENIZER_URL" \
	    --build-arg TOKENIZER_SHA256="$$ONNX_TOKENIZER_SHA256" \
	    tests/sandbox

sandbox-onnx: sandbox-onnx-image
	python3 tests/sandbox/runner.py --no-build 60-onnx-second-stage 61-onnx-fbas-sized-buffer

# ── eBPF image (51-ebpf-threat-map-roundtrip / 52-ebpf-af-alg-tracepoint) ──
# Extends atty-sandbox:base with atty-guard rebuilt --features
# ebpf + the compiled atty_guard.bpf.o. Requires the host
# kernel's BTF dump accessible at /sys/kernel/btf/vmlinux during
# build — otherwise .bpf.o isn't compiled and scenarios 51/52
# SKIP at runtime via lib/bpf.py's probe.
sandbox-ebpf-image: sandbox-base-image
	DOCKER_BUILDKIT=1 docker build \
	    -t atty-sandbox:ebpf \
	    -f tests/sandbox/Dockerfile.ebpf \
	    $(CURDIR)

sandbox-ebpf: sandbox-ebpf-image
	python3 tests/sandbox/runner.py --no-build \
	    51-ebpf-threat-map-roundtrip 52-ebpf-af-alg-tracepoint \
	    55-ebpf-ancestry-depth 56-ebpf-propagate-fork \
	    58-ebpf-detection-gap \
	    59-ebpf-profile-audit 60-ebpf-profile-session \
	    61-ebpf-profile-strict 62-ebpf-profile-strict-basename \
	    63-ebpf-profile-switch

# Tier-B per-mode overhead measurement (not a pass/fail gate — prints a
# ns/invocation table; see docs/benchmarking.md).
sandbox-ebpf-bench: sandbox-ebpf-image
	python3 tests/sandbox/runner.py --no-build 57-ebpf-overhead
