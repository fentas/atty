# V2-B build helper for the kernel-side BPF program.
#
# Generates `atty_guard.bpf.o` from `atty_guard.bpf.c`. The Rust
# userspace loader (added in a follow-up under `--features ebpf`)
# loads this .o at runtime via libbpf-rs.
#
# Prerequisites:
#   - clang ≥ 14 (BPF CO-RE support).
#   - libbpf-dev (or libbpf-devel; the BPF helper headers).
#   - bpftool, for generating vmlinux.h.
#   - Kernel ≥ 5.7 (LSM hooks via eBPF — verify with
#     `bpftool feature` or check `/sys/kernel/btf/vmlinux`).
#
# Build:
#   make vmlinux.h    # one-time, regenerate when the kernel updates
#   make
#
# The output `.o` is consumed by `atty-guard --enable-ebpf` (lands
# with the V2-B follow-up; this PR is design + skeleton only).

ARCH ?= $(shell uname -m | sed 's/x86_64/x86/' | sed 's/aarch64/arm64/')

CLANG ?= clang
BPFTOOL ?= bpftool

CFLAGS = -O2 -g -Wall -target bpf -D__TARGET_ARCH_$(ARCH) \
         -I/usr/include/bpf

.PHONY: all clean vmlinux.h

all: atty_guard.bpf.o

atty_guard.bpf.o: atty_guard.bpf.c vmlinux.h
	$(CLANG) $(CFLAGS) -c $< -o $@

vmlinux.h:
	$(BPFTOOL) btf dump file /sys/kernel/btf/vmlinux format c > $@

clean:
	rm -f atty_guard.bpf.o
