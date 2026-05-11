# atty — top-level build entry.
#
# Most targets shell out to `zig`. The `docker-*` targets let users
# build without installing Zig locally.

ZIG ?= zig
PREFIX ?= $(HOME)/.local
TARGET ?= native
OPT ?= ReleaseSafe

# `make CONFIG=path/to/mine.zig build` to use an out-of-tree config.
ifdef CONFIG
ZIG_CONFIG_ARG := -Dconfig=$(CONFIG)
endif

.PHONY: help build debug test itest run install clean docker docker-binary fmt

help:
	@printf "atty — build targets\n\n"
	@printf "  build           Compile zig-out/bin/atty (ReleaseSafe).\n"
	@printf "  debug           Compile in Debug mode.\n"
	@printf "  test            Run unit tests.\n"
	@printf "  itest           Run integration tests (real PTY).\n"
	@printf "  run             Build and run.\n"
	@printf "  install         Install to \$$PREFIX/bin (default: ~/.local/bin).\n"
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
	$(ZIG) build test --summary all

itest:
	$(ZIG) build itest --summary all

run: build
	./zig-out/bin/atty

install: build
	install -d $(PREFIX)/bin
	install -m 0755 zig-out/bin/atty $(PREFIX)/bin/atty
	@printf "→ installed to %s/bin/atty\n" "$(PREFIX)"

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
