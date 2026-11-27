#!/usr/bin/env bash
# Checks run by publish.yml before it pushes images; prints config.yaml's
# version on success.
#
#   release-check.sh tag <tag>   A version tag: it must match config.yaml's
#                                version, and a final release (not -rcN) needs
#                                a dated CHANGELOG entry, since users read it
#                                before updating.
#   release-check.sh dry-run     A manual push: refused if the version has
#                                already been released (a v<version> tag in
#                                EXISTING_TAGS, one per line), so a dry run
#                                can't overwrite a release's images.
#
# CONFIG_YAML and CHANGELOG override the files checked (tests only).
set -euo pipefail
cd "$(dirname "$0")/.."
config=${CONFIG_YAML:-nfs-ganesha/config.yaml}
changelog=${CHANGELOG:-nfs-ganesha/CHANGELOG.md}
version=$(sed -n 's/^version: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' "$config")

case "${1:-}" in
    tag)
        if [ "${2#v}" != "$version" ]; then
            echo "Tag $2 doesn't match config.yaml's version $version" >&2
            exit 1
        fi
        if [[ ! "$version" =~ -rc[0-9]+$ ]] \
            && ! grep -qE "^## \[${version//./\\.}\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$" "$changelog"; then
            echo "The CHANGELOG entry for $version has no release date (## [$version] - YYYY-MM-DD)" >&2
            exit 1
        fi
        ;;
    dry-run)
        if grep -qxF "v$version" <<< "${EXISTING_TAGS:-}"; then
            echo "$version is already released (tag v$version); dry runs need a throwaway version" >&2
            exit 1
        fi
        ;;
    *)
        echo "usage: $0 tag <tag> | dry-run" >&2
        exit 2
        ;;
esac
echo "$version"
