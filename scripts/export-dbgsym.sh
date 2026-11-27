#!/bin/bash
# Exports the Ganesha debug symbols (dbgsym packages) for an image built from
# nfs-ganesha/Dockerfile, and checks they belong to that exact image.
#
# Usage: scripts/export-dbgsym.sh IMAGE OUTDIR
#
# Builds the Dockerfile's dbgsym stage, which comes from the build cache when
# IMAGE was just built with the same builder. Since a rebuild needn't produce
# identical binaries, it then checks that every ELF file the image installs
# from Ganesha's packages has its build ID in the exported packages, and fails
# otherwise. Needs docker buildx, readelf and dpkg-deb.
set -euo pipefail

IMAGE=$1
OUT=$2
CONTEXT="$(cd "$(dirname "$0")/../nfs-ganesha" && pwd)"

docker buildx build --quiet --target dbgsym --output "type=local,dest=$OUT" "$CONTEXT" > /dev/null

ids=$(for deb in "$OUT"/*.deb; do dpkg-deb --field "$deb" Build-Ids; done | tr ' ' '\n')

tmp=$(mktemp -d)
cid=$(docker create "$IMAGE")
trap 'rm -rf "$tmp"; docker rm "$cid" > /dev/null' EXIT

# shellcheck disable=SC2016  # expanded by the image's shell
files=$(docker run --rm --entrypoint sh "$IMAGE" -c '
    dpkg -L nfs-ganesha nfs-ganesha-vfs | while read -r f; do
        if [ -f "$f" ] && [ ! -L "$f" ] && head -c 4 "$f" | grep -q ELF; then echo "$f"; fi
    done')
[ -n "$files" ] || { echo "No Ganesha ELF files found in $IMAGE" >&2; exit 1; }

missing=0
for f in $files; do
    docker cp --quiet "$cid:$f" "$tmp/elf"
    id=$(readelf --notes "$tmp/elf" | sed -n 's/^ *Build ID: //p')
    if grep -qxF "$id" <<< "$ids"; then
        echo "ok      $f $id"
    else
        echo "MISSING $f ${id:-(no build ID)}"
        missing=1
    fi
done
if [ "$missing" = 1 ]; then
    echo "The exported debug symbols don't match $IMAGE (was the dbgsym stage rebuilt?)" >&2
    exit 1
fi
ls -l "$OUT"
