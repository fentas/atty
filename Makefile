# atty — top-level build entry.
#
# Most targets shell out to `zig`. The `docker-*` targets let users
# build without installing Zig locally.

ZIG ?= zig
PREFIX ?= $(HOME)/.local
OPT ?= ReleaseSafe

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

.PHONY: help build debug test itest e2e e2e-update run install link unlink clean docker docker-binary fmt

help:
	@printf "atty — build targets\n\n"
	@printf "  build           Compile zig-out/bin/atty (ReleaseSafe).\n"
	@printf "  debug           Compile in Debug mode.\n"
	@printf "  test            Run unit tests.\n"
	@printf "  itest           Run integration tests (real PTY).\n"
	@printf "  e2e             Run end-to-end scenarios under tests/e2e/.\n"
	@printf "  e2e-update      Refresh goldens from current output.\n"
	@printf "  run             Build and run.\n"
	@printf "  install         Copy zig-out/bin/atty to \$$PREFIX/bin (default: ~/.local/bin).\n"
	@printf "  link            Symlink \$$PREFIX/bin/atty -> this clone's zig-out/bin/atty.\n"
	@printf "                  Rebuilds in this tree update the installed binary live.\n"
	@printf "  unlink          Remove the symlink at \$$PREFIX/bin/atty (only if it's a symlink).\n"
	@printf "  docker          Build the Docker runtime image (atty:latest).\n"
	@printf "  docker-binary   Build the binary in Docker, copy to ./dist/atty.\n"
	@printf "  fmt             zig fmt on src/.\n"
	@printf "  clean           Remove build artifacts.\n\n"
	@printf "Variables: ZIG=$(ZIG)  PREFIX=$(PREFIX)  TARGET=$(TARGET)  OPT=$(OPT)\n"
	@printf "           CONFIG=<path>   custom config.zig location\n"

build:
	$(ZIG) build -Doptimize=$(OPT) -Dtarget=$(TARGET) $(ZIG_CONFIG_ARG)

debug:
	$(ZIG) build -Doptimize=Debug -Dtarget=$(TARGET) $(ZIG_CONFIG_ARG)

test:
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

run: build
	./zig-out/bin/atty

install: build
	install -d $(PREFIX)/bin
	install -m 0755 zig-out/bin/atty $(PREFIX)/bin/atty
	@printf "→ installed to %s/bin/atty\n" "$(PREFIX)"

# Symlink the installed binary at $(PREFIX)/bin/atty to this clone's
# zig-out/bin/atty. Same model as get.sh: source is the truth, install
# dir is just a pointer. Re-running `make build` (or `zig build`) here
# updates the live binary with no extra step.
link: build
	install -d $(PREFIX)/bin
	ln -sfn $(CURDIR)/zig-out/bin/atty $(PREFIX)/bin/atty
	@printf "→ linked %s/bin/atty → %s/zig-out/bin/atty\n" "$(PREFIX)" "$(CURDIR)"

# Remove the symlink (but never a real file — guarded by [ -L ]).
unlink:
	@if [ -L "$(PREFIX)/bin/atty" ]; then \
	    rm "$(PREFIX)/bin/atty" && printf "→ removed %s/bin/atty\n" "$(PREFIX)"; \
	elif [ -e "$(PREFIX)/bin/atty" ]; then \
	    printf "⚠ %s/bin/atty is a real file, not a symlink — refusing to remove\n" "$(PREFIX)"; exit 1; \
	else \
	    printf "(nothing to unlink)\n"; \
	fi

fmt:
	$(ZIG) fmt src/ build.zig

clean:
	rm -rf zig-out .zig-cache dist

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
