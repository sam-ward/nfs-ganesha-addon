# HAOS test VM tools: QEMU/KVM with UEFI firmware, plus what haos-vm.sh uses
# to drive Home Assistant's API. Runs in a container, so the host only needs
# Docker and /dev/kvm.
FROM debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a

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
