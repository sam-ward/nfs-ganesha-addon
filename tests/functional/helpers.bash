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

# The add-on version in config.yaml. The Supervisor passes it to the build as BUILD_VERSION.
addon_version() {
    python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["version"])' \
        "$REPO_ROOT/nfs-ganesha/config.yaml"
}

build_image() {
    [ "${SKIP_BUILD:-0}" = 1 ] || docker build -q --build-arg "BUILD_VERSION=$(addon_version)" \
        -t "$IMAGE" "$REPO_ROOT/nfs-ganesha" >/dev/null
}

reset_log() {
    mkdir -p "$LOG_DIR"
    : > "$ADDON_LOG"
    chown -R "$REPO_OWNER" "$LOG_DIR"
}

# Capabilities config.yaml grants the add-on: the single source of truth.
addon_caps() {
    python3 -c 'import sys, yaml; print("\n".join(yaml.safe_load(open(sys.argv[1]))["privileged"]))' \
        "$REPO_ROOT/nfs-ganesha/config.yaml"
}

# The add-on's custom AppArmor profile. The Supervisor loads it under the
# add-on's slug; the tests load it under this name.
AA_FILE="$REPO_ROOT/nfs-ganesha/apparmor.txt"
AA_PROFILE=nfs_ganesha_test

# Loads AA_FILE (if present) into the host kernel as AA_PROFILE, renaming the
# profile as the Supervisor does. AA_COMPLAIN=1 loads it in complain mode,
# which logs what it would deny instead of denying it.
load_apparmor_profile() {
    [ -f "$AA_FILE" ] || return 0
    [ -d /sys/kernel/security/apparmor ] || mount -t securityfs securityfs /sys/kernel/security
    sed -E "s/^profile [^ ]+/profile $AA_PROFILE/" "$AA_FILE" > "$BATS_FILE_TMPDIR/apparmor.txt"
    # Compile for this kernel's features, as HAOS does. Debian's parser.conf pins
    # an older feature set, which mismatches newer kernels (e.g. unix sockets).
    apparmor_parser --replace ${AA_COMPLAIN:+--complain} \
        --policy-features /sys/kernel/security/apparmor/features \
        "$BATS_FILE_TMPDIR/apparmor.txt"
}

# AppArmor as config.yaml sets it: unconfined only if it says `apparmor: false`;
# otherwise the custom profile if there is one, else Docker's default profile.
addon_apparmor_enabled() {
    python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1])).get("apparmor", True))' \
        "$REPO_ROOT/nfs-ganesha/config.yaml"
}

# docker run arguments for the add-on, minus any capability named in $DROP_CAPS.
addon_run_args() {
    local cap
    printf '%s\n' --network host
    if [ "$(addon_apparmor_enabled)" != True ]; then
        printf '%s\n' --security-opt apparmor=unconfined
    elif [ -f "$AA_FILE" ]; then
        printf '%s\n' --security-opt "apparmor=$AA_PROFILE"
    fi
    for cap in $(addon_caps); do
        [[ " ${DROP_CAPS:-} " == *" $cap "* ]] || printf '%s\n' --cap-add "$cap"
    done
    # Mounted where the Supervisor mounts config.yaml's map entries.
    printf '%s\n' -v "$WORK/data:/data" -v "$WORK/config:/homeassistant" -v "$WORK/media:/media" \
        -v "$WORK/local_apps:/local_apps"
    # Test-only: NETWORK_INFO_OVERRIDE replaces the network info "auto" resolves
    # from, AUTO_RESOLVE_TIMEOUT shortens how long it waits for it, and
    # SUPERVISOR_API/SUPERVISOR_TOKEN point the add-on at a mock Supervisor.
    local var
    for var in NETWORK_INFO_OVERRIDE AUTO_RESOLVE_TIMEOUT SUPERVISOR_API SUPERVISOR_TOKEN; do
        [ -z "${!var:-}" ] || printf '%s\n' -e "$var=${!var}"
    done
}

start_addon() {
    # WORK is bind-mounted into the add-on container by the *host* daemon, so it
    # must be under the repo (same path on host and in the toolbox). Gitignored.
    # Exported: bats only passes exported variables from setup_file to tests.
    export WORK="$REPO_ROOT/.test-work"
    export MNT="$BATS_FILE_TMPDIR/mnt"
    mkdir -p "$WORK"/{data,config,media,local_apps} "$MNT"
    echo "$1" > "$WORK/data/options.json"
    echo "hello from config" > "$WORK/config/hello.txt"
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    # The readiness probe below can't tell servers apart, so the port must be free.
    if bash -c 'exec 3<>/dev/tcp/127.0.0.1/2049' 2>/dev/null; then
        echo "port 2049 is already in use on this host (kernel nfsd or another container?)" >&2
        return 1
    fi
    # Capabilities and AppArmor come from config.yaml. Never use --privileged here.
    local args
    mapfile -t args < <(addon_run_args)
    docker run -d --name "$NAME" "${args[@]}" "$IMAGE" >/dev/null
    for _ in $(seq 1 30); do
        if [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" != true ]; then break; fi
        if bash -c 'exec 3<>/dev/tcp/127.0.0.1/2049' 2>/dev/null; then return 0; fi
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
    if grep -q " $MNT " /proc/mounts; then
        echo "a previous mount is still on $MNT" >&2
        return 1
    fi
    mount -t nfs4 -o "soft,timeo=50,retrans=2${2:+,$2}" "127.0.0.1:$1" "$MNT"
}

# Prints "<calls> <errors>" for an NFS operation on the current mount, from the
# kernel's per-op counters. Proves an operation reached the server, and that
# the server didn't reject it (the client falls back silently when it does).
op_stats() {
    awk -v mnt="$MNT" -v op="$1:" '
        $0 ~ "mounted on " mnt " " { f = 1; next }
        /^device / { f = 0 }
        f && $1 == op { print $2, $10; found = 1; exit }
        END { if (!found) print 0, 0 }' /proc/self/mountstats
}

# Asserts op_stats for $1 rose by at least one call, with no new errors.
assert_server_handled() {
    local before=$2 after
    after=$(op_stats "$1")
    read -r b_calls b_errs <<< "$before"
    read -r a_calls a_errs <<< "$after"
    (( a_calls > b_calls )) || fail "$1 never reached the server (calls $b_calls -> $a_calls)"
    (( a_errs == b_errs )) || fail "server returned an error for $1 (errors $b_errs -> $a_errs); client fell back"
}

# Checks /proc/mounts rather than `mountpoint`, which stats the mount and so
# fails (EREMOTEIO) when the server mishandles the request; removes stacked mounts too.
unmount_export() {
    while grep -q " ${MNT:-/nonexistent} " /proc/mounts; do
        umount -f "$MNT" 2>/dev/null || umount -l "$MNT" || return 1
    done
}

# The add-on's processes are inspected from the host's /proc (the toolbox runs
# with --pid host): a docker exec would run under the add-on's AppArmor profile.

# Host PID of the add-on's ganesha.nfsd (found by the container id in its cgroup).
ganesha_pid() {
    local id p
    id=$(docker inspect -f '{{.Id}}' "$NAME")
    for p in /proc/[0-9]*; do
        [ "$(cat "$p/comm" 2>/dev/null)" = ganesha.nfsd ] && grep -q "$id" "$p/cgroup" 2>/dev/null \
            && { echo "${p#/proc/}"; return 0; }
    done
    return 0
}

# ganesha.nfsd's kernel process flags (/proc/<pid>/stat field 9), decimal.
ganesha_flags() {
    local pid
    pid=$(ganesha_pid)
    [ -z "$pid" ] || cut -d" " -f9 "/proc/$pid/stat"
}

# PR_SET_IO_FLUSHER sets PF_MEMALLOC_NOIO (bit 19) and PF_LOCAL_THROTTLE (bit 20).
assert_io_flusher() {
    local f on
    f=$(ganesha_flags)
    [ -n "$f" ] || fail "ganesha.nfsd is not running"
    on=$(( (f >> 19 & 1) && (f >> 20 & 1) ))
    if [ "$1" = on ]; then
        (( on )) || fail "IO-flusher flags not set (flags=$(printf '0x%08x' "$f"))"
    else
        (( ! on )) || fail "IO-flusher flags unexpectedly set (flags=$(printf '0x%08x' "$f"))"
    fi
}
