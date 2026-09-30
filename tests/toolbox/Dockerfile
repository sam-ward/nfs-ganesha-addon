# Test toolbox: every tool `make lint|unit|functional` needs, so the host only
# needs Docker and make. CI uses the same image.
FROM hadolint/hadolint:v2.15.1-debian AS hadolint
FROM docker:29-cli AS docker-cli

FROM debian:trixie-slim

# nfs-common: mount.nfs4 for the functional tests (run in a privileged container).
# python3 comes with yamllint and is used to hold port 2049 in one test.
RUN apt-get update && apt-get install -y --no-install-recommends \
        bats \
        bats-assert \
        bats-support \
        jq \
        make \
        nfs-common \
        shellcheck \
        yamllint \
    && rm -rf /var/lib/apt/lists/*

COPY --from=hadolint /bin/hadolint /usr/local/bin/hadolint
COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker

# Where bats_load_library finds bats-support / bats-assert.
ENV BATS_LIB_PATH=/usr/lib/bats \
    IN_TOOLBOX=1
