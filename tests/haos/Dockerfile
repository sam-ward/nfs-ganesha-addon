# HAOS test VM tools: QEMU/KVM with UEFI firmware, plus what haos-vm.sh uses
# to drive Home Assistant's API. Runs in a container, so the host only needs
# Docker and /dev/kvm.
FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        jq \
        ovmf \
        python3 \
        qemu-system-x86 \
        qemu-utils \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*
