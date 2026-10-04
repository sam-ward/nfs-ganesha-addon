# Test toolbox: every tool `make lint|unit|functional` needs, so the host only
# needs Docker and make. CI uses the same image.
FROM hadolint/hadolint:v2.15.1-debian@sha256:9a3944b7fddcb947d1ffd90829ac1a6e5c30479223358f249d8b96c7d0019e27 AS hadolint
FROM docker:29-cli@sha256:b1805116a6a86cc591b5d5f60a910a0715cdcc9d18d866ad68b1457ead25c35c AS docker-cli

FROM debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a

# nfs-common: mount.nfs4 for the functional tests (run in a privileged container).
# python3 comes with yamllint and is used to hold port 2049 in one test.
# apparmor: apparmor_parser loads the add-on's custom profile for the tests.
RUN apt-get update && apt-get install -y --no-install-recommends \
        apparmor \
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
