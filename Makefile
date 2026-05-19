# atty — top-level build entry.
#
# Most targets shell out to `zig`. The `docker-*` targets let users
# build without installing Zig locally.

ZIG ?= zig
CARGO ?= cargo
PREFIX ?= $(HOME)/.local
OPT ?= ReleaseSafe

# atty-guard (Rust sidecar) build profile + Cargo features. Defaults
# match the release-artifact build: full classifier (ONNX SLM), live
# OSV.dev lookup for npm misses, and the atom fetcher. eBPF is opt-in
# — `make GUARD_FEATURES=tier2-onnx,osv-live,atoms-fetch,ebpf …`.
# eBPF additionally needs `libbpf-dev` on the build host AND
# `AmbientCapabilities=CAP_BPF` on the systemd-user unit at runtime.
GUARD_PROFILE ?= release
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

.PHONY: help build build-atty build-guard debug test test-atty test-guard itest e2e e2e-update run \
        install install-atty install-guard link link-atty link-guard unlink unlink-atty unlink-guard \
        clean clean-atty clean-guard docker docker-binary fmt fmt-atty fmt-guard reload-guard

help:
	@printf "atty — build targets\n\n"
	@printf "Build (default = both subprojects)\n"
	@printf "  build           Build everything (atty + atty-guard).\n"
	@printf "  build-atty      Build only atty → zig-out/bin/atty (ReleaseSafe).\n"
	@printf "  build-guard     Build only atty-guard → atty-guard/target/$(GUARD_PROFILE)/atty-guard.\n"
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
	@printf "  e2e-update      Refresh e2e goldens from current output.\n\n"
	@printf "Install (default = both subprojects)\n"
	@printf "  install         Copy atty binary to \$$PREFIX/bin AND run atty-guard installer.\n"
	@printf "  install-atty    Only copy zig-out/bin/atty to \$$PREFIX/bin (default: ~/.local/bin).\n"
	@printf "  install-guard   Only run atty-guard/contrib/install.sh (binary + systemd-user unit).\n\n"
	@printf "Link / unlink (default = both subprojects)\n"
	@printf "  link            Symlink BOTH \$$PREFIX/bin/atty and \$$PREFIX/bin/atty-guard.\n"
	@printf "  link-atty       Only symlink \$$PREFIX/bin/atty -> this clone's zig-out/bin/atty.\n"
	@printf "  link-guard      Only symlink \$$PREFIX/bin/atty-guard -> atty-guard/target/$(GUARD_PROFILE)/atty-guard.\n"
	@printf "  unlink          Remove BOTH symlinks (only if they're symlinks).\n"
	@printf "  unlink-atty     Only remove the atty symlink.\n"
	@printf "  unlink-guard    Only remove the atty-guard symlink.\n\n"
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
	@printf "           GUARD_PROFILE=$(GUARD_PROFILE)  GUARD_FEATURES=$(GUARD_FEATURES)\n"
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

run: build-atty
	./zig-out/bin/atty

# Meta install — atty binary + atty-guard binary + systemd-user unit.
# Run on a fresh clone to land a complete setup. Per-subproject
# variants (`install-atty` / `install-guard`) stay available when you
# only want one side.
#
# Recursive `$(MAKE)` calls instead of prerequisite-list serialise the
# two steps even under `make -j`: install-guard's contrib/install.sh
# does multi-step systemd-user setup (daemon-reload + enable + start)
# that races badly with concurrent installs.
install:
	$(MAKE) install-atty
	$(MAKE) install-guard

install-atty: build-atty
	install -d $(PREFIX)/bin
	install -m 0755 zig-out/bin/atty $(PREFIX)/bin/atty
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
	ln -sfn $(CURDIR)/zig-out/bin/atty $(PREFIX)/bin/atty
	@printf "→ linked %s/bin/atty → %s/zig-out/bin/atty\n" "$(PREFIX)" "$(CURDIR)"

# Meta unlink — both subprojects.
unlink: unlink-atty unlink-guard

# Remove the symlink (but never a real file — guarded by [ -L ]).
unlink-atty:
	@if [ -L "$(PREFIX)/bin/atty" ]; then \
	    rm "$(PREFIX)/bin/atty" && printf "→ removed %s/bin/atty\n" "$(PREFIX)"; \
	elif [ -e "$(PREFIX)/bin/atty" ]; then \
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
	cd atty-guard && $(CARGO) build --$(GUARD_PROFILE) --features $(GUARD_FEATURES)

test-guard:
	cd atty-guard && $(CARGO) test --quiet
	cd atty-guard && $(CARGO) test --features $(GUARD_FEATURES) --quiet

fmt-guard:
	cd atty-guard && $(CARGO) fmt

# Full install — binary into $(PREFIX)/bin AND systemd-user unit AND
# enable+start the service. Delegates to the canonical installer so
# the systemd policy stays in one place (atty-guard.service).
install-guard: build-guard
	@printf "→ %s will install + enable atty-guard.service (systemd-user)\n" "$@"
	atty-guard/contrib/install.sh

# Symlink the daemon binary the same way `make link` does for atty:
# source-of-truth is the cargo target dir, $(PREFIX)/bin is just a
# pointer. The daemon must be restarted (`make reload-guard`) for a
# newly-rebuilt binary to actually run — systemd-user resolves the
# symlink at ExecStart, not on every signal.
link-guard: build-guard
	install -d $(PREFIX)/bin
	ln -sfn $(CURDIR)/atty-guard/target/$(GUARD_PROFILE)/atty-guard $(PREFIX)/bin/atty-guard
	@printf "→ linked %s/bin/atty-guard → %s/atty-guard/target/%s/atty-guard\n" \
	    "$(PREFIX)" "$(CURDIR)" "$(GUARD_PROFILE)"
	@printf "  (run \`make reload-guard\` to pick up changes in a running daemon)\n"

unlink-guard:
	@if [ -L "$(PREFIX)/bin/atty-guard" ]; then \
	    rm "$(PREFIX)/bin/atty-guard" && printf "→ removed %s/bin/atty-guard\n" "$(PREFIX)"; \
	elif [ -e "$(PREFIX)/bin/atty-guard" ]; then \
	    printf "⚠ %s/bin/atty-guard is a real file, not a symlink — refusing to remove\n" "$(PREFIX)"; exit 1; \
	else \
	    printf "(nothing to unlink)\n"; \
	fi

# Restart the systemd-user unit. systemd-user resolves the symlink/path
# at ExecStart, so this is what makes a freshly-built binary actually run.
# When built with --features ebpf, the restart also unloads the old
# kernel-side BPF programs (libbpf-rs drops them on process exit) and
# the new daemon re-attaches them on startup.
reload-guard:
	@if ! command -v systemctl >/dev/null 2>&1; then \
	    printf "⚠ systemctl not on \$$PATH — start atty-guard yourself with the new binary\n"; \
	    exit 1; \
	fi
	@unit_path="$${XDG_CONFIG_HOME:-$$HOME/.config}/systemd/user/atty-guard.service"; \
	if [ ! -f "$$unit_path" ]; then \
	    printf "⚠ atty-guard.service not installed (%s) — run \`make install-guard\` first\n" "$$unit_path"; \
	    exit 1; \
	fi
	systemctl --user restart atty-guard.service
	@printf "→ atty-guard restarted (eBPF re-attached if built with --features ebpf)\n"
