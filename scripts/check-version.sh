#!/usr/bin/env bash
# Fails if config.yaml's version differs from the newest released CHANGELOG
# entry. An [Unreleased] section above it is allowed and skipped. A release
# candidate (X-rcN) matches the entry for X, so the beta branch can carry
# 2.0.0-rc1 while the CHANGELOG says [2.0.0].
# CONFIG_YAML and CHANGELOG override the files checked (tests only).
set -euo pipefail
cd "$(dirname "$0")/.."
config=${CONFIG_YAML:-nfs-ganesha/config.yaml}
changelog=${CHANGELOG:-nfs-ganesha/CHANGELOG.md}
cfg=$(sed -n 's/^version: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' "$config")
log=$(sed -n 's/^## \[\([^]]*\)\].*/\1/p' "$changelog" | grep -vx Unreleased | head -1)
release=$(sed -E 's/-rc[0-9]+$//' <<< "$cfg")
if [ "$release" != "$log" ]; then
    echo "version mismatch: config.yaml=$cfg CHANGELOG.md=$log" >&2
    exit 1
fi
echo "version OK: $cfg"
