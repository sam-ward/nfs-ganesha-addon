# Container + mount lifecycle for functional tests. Runs inside the privileged
# toolbox container (root, host network, docker.sock); host port 2049 must be free.
IMAGE=${IMAGE:-nfs-ganesha-addon:test}
NAME=nfs-ganesha-functional
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
# Add-on container logs for every test, kept after the run (CI uploads it on failure).
LOG_DIR="$REPO_ROOT/.test-logs"
ADDON_LOG="$LOG_DIR/addon.log"
# Files we create run as root in the toolbox; hand them back to the repo's owner.
REPO_OWNER="$(stat -c %u:%g "$REPO_ROOT")"

build_image() {
    [ "${SKIP_BUILD:-0}" = 1 ] || docker build -q -t "$IMAGE" "$REPO_ROOT/nfs-ganesha" >/dev/null
}

reset_log() {
    mkdir -p "$LOG_DIR"
    : > "$ADDON_LOG"
    chown -R "$REPO_OWNER" "$LOG_DIR"
}

start_addon() {
    # WORK is bind-mounted into the add-on container by the *host* daemon, so it
    # must be under the repo (same path on host and in the toolbox). Gitignored.
    # Exported: bats only passes exported variables from setup_file to tests.
    export WORK="$REPO_ROOT/.test-work"
    export MNT="$BATS_FILE_TMPDIR/mnt"
    mkdir -p "$WORK"/{data,config,media} "$MNT"
    echo "$1" > "$WORK/data/options.json"
    echo "hello from config" > "$WORK/config/hello.txt"
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    # Capabilities mirror config.yaml's privileged list. Never use --privileged here.
    docker run -d --name "$NAME" --network host \
        --cap-add SYS_ADMIN --cap-add DAC_READ_SEARCH \
        --security-opt apparmor=unconfined \
        -v "$WORK/data:/data" -v "$WORK/config:/config" -v "$WORK/media:/media" \
        "$IMAGE" >/dev/null
    for _ in $(seq 1 30); do
        if bash -c 'exec 3<>/dev/tcp/127.0.0.1/2049' 2>/dev/null; then return 0; fi
        if [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" != true ]; then break; fi
        sleep 1
    done
    docker logs "$NAME" >&3 2>&1 || true
    echo "add-on did not open port 2049" >&3
    return 1
}

stop_addon() {
    unmount_export
    { echo "=== ${BATS_TEST_NAME:-file teardown}"; docker logs "$NAME" 2>&1; } >> "$ADDON_LOG" || true
    chown "$REPO_OWNER" "$ADDON_LOG" 2>/dev/null || true
    docker rm -f "$NAME" >/dev/null 2>&1 || true
}

mount_export() {
    mount -t nfs4 -o "soft,timeo=50,retrans=2${2:+,$2}" "127.0.0.1:$1" "$MNT"
}

unmount_export() {
    if mountpoint -q "${MNT:-/nonexistent}"; then umount -f "$MNT" || umount -l "$MNT"; fi
}
