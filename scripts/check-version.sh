#!/usr/bin/env bash
# Fails if config.yaml's version differs from the newest CHANGELOG entry.
set -euo pipefail
cd "$(dirname "$0")/.."
cfg=$(sed -n 's/^version: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' nfs-ganesha/config.yaml)
log=$(sed -n 's/^## \[\([^]]*\)\].*/\1/p' nfs-ganesha/CHANGELOG.md | head -1)
if [ "$cfg" != "$log" ]; then
    echo "version mismatch: config.yaml=$cfg CHANGELOG.md=$log" >&2
    exit 1
fi
echo "version OK: $cfg"
