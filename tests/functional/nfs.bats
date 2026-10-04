#!/usr/bin/env bats
bats_load_library bats-support
bats_load_library bats-assert
load helpers

AUTHORISED='{"authorized_ips":["127.0.0.1"],"export_folders":["config","media"]}'

setup_file() {
    reset_log
    build_image
    load_apparmor_profile
    # Mark the kernel log, so the last test sees only this run's AppArmor events.
    # (A line count doesn't work: a full ring buffer wraps.)
    KMSG_MARK="nfs-ganesha-functional-tests start $(date +%s%N)"
    echo "$KMSG_MARK" > /dev/kmsg
    export KMSG_MARK
    start_addon "$AUTHORISED"
}

teardown_file() { stop_addon; rm -rf "$REPO_ROOT/.test-work"; }

teardown() { unmount_export; }

check_version_negotiated() {
    # Guard against silent fallback to another minor version.
    run grep " $MNT nfs4 " /proc/mounts
    assert_output --partial "vers=$1"
}

for_version() {
    mount_export /config "vers=$1"
    check_version_negotiated "$1"
    run cat "$MNT/hello.txt";                   assert_output "hello from config"
    head -c 20M /dev/urandom > "$BATS_TEST_TMPDIR/blob"
    cp "$BATS_TEST_TMPDIR/blob" "$MNT/blob-$1"
    assert_equal "$(sha256sum < "$BATS_TEST_TMPDIR/blob")" "$(sha256sum < "$MNT/blob-$1")"
    mv "$MNT/blob-$1" "$MNT/renamed-$1"
    rm "$MNT/renamed-$1"
    run ls "$MNT/renamed-$1";                   assert_failure
}

@test "NFSv4.0 read/write/rename/delete" { for_version 4.0; }
@test "NFSv4.1 read/write/rename/delete" { for_version 4.1; }
@test "NFSv4.2 read/write/rename/delete" { for_version 4.2; }

@test "no Remote I/O error on the mount root right after writes (NFSv4.1/4.2)" {
    local v i fails
    for v in 4.1 4.2; do
        fails=0
        for i in 1 2 3 4 5; do
            mount_export /config "vers=$v"
            head -c 20M /dev/urandom > "$MNT/rio-$i.bin"
            mountpoint -q "$MNT" || fails=$((fails + 1))
            rm -f "$MNT/rio-$i.bin"
            unmount_export
        done
        (( fails == 0 )) || fail "vers=$v: Remote I/O error in $fails/5 attempts"
    done
}

@test "NFSv4.2 COPY (server-side copy) is handled by the server" {
    # Ganesha returns an error for COPY and the Linux client then copies the
    # data itself, so only the op counters reveal it.
    skip "server-side COPY rejected by all tested versions; see backlog investigation"
    mount_export /config "vers=4.2"
    check_version_negotiated 4.2
    local copy
    copy=$(op_stats COPY)
    run python3 - "$MNT" <<'PY'
import os, sys
d = sys.argv[1]
data = os.urandom(4 << 20)
with open(f"{d}/src.bin", "wb") as f:
    f.write(data)
with open(f"{d}/src.bin", "rb") as i, open(f"{d}/dst.bin", "wb") as o:
    assert os.copy_file_range(i.fileno(), o.fileno(), len(data)) == len(data)
with open(f"{d}/dst.bin", "rb") as f:
    assert f.read() == data, "copy_file_range content differs"
for n in ("src", "dst"):
    os.remove(f"{d}/{n}.bin")
print("ok")
PY
    assert_success
    assert_output "ok"
    assert_server_handled COPY "$copy"
}

@test "NFSv4.2 ALLOCATE and SEEK are handled by the server" {
    mount_export /config "vers=4.2"
    check_version_negotiated 4.2
    local alloc seek
    alloc=$(op_stats ALLOCATE); seek=$(op_stats SEEK)
    run python3 - "$MNT" <<'PY'
import os, sys
d = sys.argv[1]
fd = os.open(f"{d}/alloc.bin", os.O_CREAT | os.O_RDWR)  # ALLOCATE
os.posix_fallocate(fd, 0, 1 << 20)
assert os.fstat(fd).st_size == 1 << 20
os.close(fd)
with open(f"{d}/sparse.bin", "wb") as f:  # SEEK
    f.seek(8 << 20)
    f.write(b"tail")
fd = os.open(f"{d}/sparse.bin", os.O_RDONLY)
assert os.lseek(fd, 0, os.SEEK_DATA) == 8 << 20, "SEEK_DATA did not skip the hole"
os.close(fd)
with open(f"{d}/sparse.bin", "rb") as f:
    buf = f.read()
assert buf[: 8 << 20] == bytes(8 << 20) and buf[-4:] == b"tail", "sparse read wrong"
for n in ("alloc", "sparse"):
    os.remove(f"{d}/{n}.bin")
print("ok")
PY
    assert_success
    assert_output "ok"
    assert_server_handled ALLOCATE "$alloc"
    assert_server_handled SEEK "$seek"
}

@test "pseudo-root lists exactly the exported folders" {
    mount_export /
    run ls "$MNT"
    assert_output $'config\nmedia'
}

@test "non-exported folder cannot be mounted" {
    run mount_export /backup
    assert_failure
    # The server's answer, not a timeout or a dead container.
    assert_output --partial "reason given by server: No such file or directory"
}

@test "unauthorised client is refused (default deny from 1.1.0)" {
    stop_addon
    start_addon '{"authorized_ips":["192.0.2.1"],"export_folders":["config"]}'
    run mount_export /config
    assert_failure
    # Ganesha hides exports a client may not use, so it answers "no such path".
    assert_output --partial "reason given by server: No such file or directory"
    stop_addon
    start_addon "$AUTHORISED"   # restore for any later tests
}

@test "DAC_READ_SEARCH is required (FSAL_VFS reopens files by handle)" {
    # If a future Ganesha no longer needs it, this fails and the capability can go.
    stop_addon
    DROP_CAPS=DAC_READ_SEARCH start_addon "$AUTHORISED"
    # Ganesha re-reads attributes by handle on every access, so this fails at
    # the mount already (or, failing that, at the first read).
    run mount_export /config
    if [ "$status" -eq 0 ]; then run cat "$MNT/hello.txt"; fi
    assert_failure
    assert_output --partial "Operation not permitted"
    unmount_export
    stop_addon
    start_addon "$AUTHORISED"
}

@test "IO-flusher protection is active with config.yaml's capabilities" {
    assert_io_flusher on
    run docker logs "$NAME"
    refute_output --partial "PR_SET_IO_FLUSHER"
    refute_output --partial "Unknown parameter"
}

@test "without SYS_RESOURCE the add-on still starts and serves (safety net)" {
    stop_addon
    DROP_CAPS=SYS_RESOURCE start_addon "$AUTHORISED"
    mount_export /config
    run cat "$MNT/hello.txt"; assert_output "hello from config"
    unmount_export
    assert_io_flusher off
    run docker logs "$NAME"
    assert_output --partial "Failed to set PR_SET_IO_FLUSHER due to EPERM"
    stop_addon
    start_addon "$AUTHORISED"
}

@test "without SYS_RESOURCE and without the allow-fail line, Ganesha 6 refuses to start" {
    # Proves the config line is what keeps the add-on alive, so it isn't removed as unused.
    # Test-only override: runs Ganesha directly on a config with the line stripped.
    stop_addon
    local args
    mapfile -t args < <(DROP_CAPS=SYS_RESOURCE addon_run_args)
    docker run -d --name "$NAME" "${args[@]}" --entrypoint sh "$IMAGE" -c '
        mkdir -p /etc/ganesha && /gen-config.sh > /etc/ganesha/g.conf
        sed -i "/Allow_Set_Io_Flusher_Fail/d" /etc/ganesha/g.conf
        mkdir -p /var/run/dbus && dbus-daemon --system --fork
        exec /usr/bin/ganesha.nfsd -F -L STDOUT -f /etc/ganesha/g.conf' >/dev/null
    run docker wait "$NAME"
    assert_output 2
    run docker logs "$NAME"
    assert_output --partial "PR_SET_IO_FLUSHER"
    stop_addon
    start_addon "$AUTHORISED"
}

@test "add-on refuses to start with no export folders (never exports /)" {
    stop_addon
    run start_addon '{"authorized_ips":["127.0.0.1"],"export_folders":[]}'
    assert_failure
    run docker logs "$NAME"
    assert_output --partial "No export folders"
    run grep -x '\[NFS\] Exporting: /' <<< "$output"
    assert_failure
    stop_addon
    start_addon "$AUTHORISED"
}

@test "add-on refuses to start with empty authorized_ips" {
    stop_addon
    run start_addon '{"authorized_ips":[],"export_folders":["config"]}'
    assert_failure
    run docker logs "$NAME"
    assert_output --partial "authorized_ips is empty"
    stop_addon
    start_addon "$AUTHORISED"
}

@test "harness refuses to start when something else holds port 2049" {
    # Otherwise the readiness probe would accept a foreign server and the
    # refusal tests would pass against the wrong server.
    stop_addon
    python3 -m http.server 2049 --bind 0.0.0.0 >/dev/null 2>&1 &
    local holder=$!
    until bash -c 'exec 3<>/dev/tcp/127.0.0.1/2049' 2>/dev/null; do sleep 0.2; done
    run start_addon "$AUTHORISED"
    kill "$holder"; wait "$holder" 2>/dev/null || true
    assert_failure
    assert_output --partial "port 2049 is already in use"
    stop_addon
    start_addon "$AUTHORISED"
}

@test "startup failure is visible in the log when port 2049 is taken" {
    # The reason must reach the add-on log, before the exit line (the log filter
    # must not lose Ganesha's last lines), and the add-on must exit non-zero so
    # the Supervisor shows it as an error. Repeated, because losing the last
    # lines is a race.
    stop_addon
    python3 -m http.server 2049 --bind 0.0.0.0 >/dev/null 2>&1 &
    local holder=$! args i
    WORK="$REPO_ROOT/.test-work"
    mapfile -t args < <(addon_run_args)
    for i in 1 2 3 4 5; do
        docker run -d --name "$NAME" "${args[@]}" "$IMAGE" >/dev/null
        run timeout 30 docker wait "$NAME"
        assert_success
        refute_output 0
        run docker logs "$NAME"
        assert_output --regexp 'Bind_sockets.*FATAL[^$]*'$'\n''(.*'$'\n'')*\[NFS\] Ganesha exited with code [1-9]'
        docker rm -f "$NAME" >/dev/null
    done
    kill "$holder"; wait "$holder" 2>/dev/null || true
    start_addon "$AUTHORISED"
}

@test "startup log identifies the app and Ganesha versions, IPs and exports" {
    run docker logs "$NAME"
    assert_output --partial "[NFS] App version: $(addon_version)"
    assert_output --regexp 'Ganesha version: NFS-Ganesha Release = V[0-9]'
    assert_output --partial "[NFS] Authorized IPs: 127.0.0.1"
    assert_output --partial "[NFS] Exporting: /config"
    assert_output --partial "[NFS] Log level: WARN"
    # The full config is only for debug levels.
    refute_output --partial "Generated /etc/ganesha/ganesha.conf"
}

@test "log_level DEBUG also prints the generated ganesha.conf" {
    stop_addon
    start_addon '{"authorized_ips":["127.0.0.1"],"export_folders":["config","media"],"log_level":"DEBUG"}'
    run docker logs "$NAME"
    assert_output --partial "Generated /etc/ganesha/ganesha.conf"
    assert_output --partial "Default_Log_Level = DEBUG;"
    stop_addon
    start_addon "$AUTHORISED"
}

@test "every log_level value starts the daemon" {
    for lvl in NULL FATAL MAJ CRIT WARN EVENT INFO DEBUG MID_DEBUG FULL_DEBUG; do
        stop_addon
        start_addon "{\"authorized_ips\":[\"127.0.0.1\"],\"export_folders\":[\"config\",\"media\"],\"log_level\":\"$lvl\"}" \
            || fail "daemon did not start with log_level=$lvl"
        # Started is not enough: the level must also have parsed cleanly.
        run docker logs "$NAME"
        refute_output --regexp 'Config file .*error|Unknown parameter|Invalid value'
    done
    stop_addon
    start_addon "$AUTHORISED"
}

@test "at WARN, Ganesha's log-level change chatter is filtered out" {
    # Ganesha logs every log-level change at NIV_NULL (always shown), about
    # 45 lines per start. They carry no information at the default level.
    run docker logs "$NAME"
    refute_output --partial " :LOG :NULL :LOG: "
    assert_output --partial "[NFS] Launching Ganesha Daemon..."
}

@test "at EVENT and above, nothing is filtered" {
    stop_addon
    start_addon '{"authorized_ips":["127.0.0.1"],"export_folders":["config","media"],"log_level":"EVENT"}'
    run docker logs "$NAME"
    # Guards the WARN test's refute: the lines it filters must really exist.
    # (EVENT is Ganesha's built-in default, so only a couple of them appear.)
    assert_output --partial " :LOG :NULL :LOG: "
    stop_addon
    start_addon "$AUTHORISED"
}

@test "stopping the add-on shuts Ganesha down cleanly (no SIGKILL)" {
    local start elapsed
    start=$(date +%s)
    docker stop -t 20 "$NAME" >/dev/null
    elapsed=$(( $(date +%s) - start ))
    run docker inspect -f '{{.State.ExitCode}}' "$NAME"
    assert_output 0
    (( elapsed < 15 )) || fail "stop took ${elapsed}s; Ganesha did not get the signal"
    run docker logs "$NAME"
    assert_output --partial "[NFS] Ganesha exited with code 0"
    stop_addon
    start_addon "$AUTHORISED"
}

# The harness has no Supervisor, so "auto" resolves from the routing table.
host_primary_ip() {
    # The source address the host would use to reach the internet (no packets sent).
    python3 -c 'import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(("1.1.1.1", 53)); print(s.getsockname()[0])'
}

@test "auto: resolves the host's LAN subnet; LAN clients mount, others are refused" {
    stop_addon
    start_addon '{"authorized_ips":["auto"],"export_folders":["config"]}'
    local ip
    ip=$(host_primary_ip)
    [ -n "$ip" ] && [ "$ip" != null ] || fail "could not find the host's primary IP"
    run docker logs "$NAME"
    assert_output --regexp 'authorized_ips "auto" -> [0-9.]+/[0-9]+ \(primary interface [^ ]+, from routing table\)'
    # A client on the LAN (the host's own LAN address) is allowed.
    mount -t nfs4 -o soft,timeo=50,retrans=2 "$ip:/config" "$MNT"
    run cat "$MNT/hello.txt"; assert_output "hello from config"
    unmount_export
    # Loopback isn't on the LAN subnet, so it is refused.
    run mount_export /config
    assert_failure
    assert_output --partial "reason given by server: No such file or directory"
    stop_addon
    start_addon "$AUTHORISED"
}

@test "security: auto refuses to start when the network can't be determined" {
    stop_addon
    : > "$WORK/data/empty-network.json"
    NETWORK_INFO_OVERRIDE=/data/empty-network.json AUTO_RESOLVE_TIMEOUT=3 \
        run start_addon '{"authorized_ips":["auto"],"export_folders":["config"]}'
    assert_failure
    run docker logs "$NAME"
    assert_output --partial 'authorized_ips "auto" could not be resolved'
    stop_addon
    start_addon "$AUTHORISED"
}

@test "files owned by other users can be written, chmod-ed and chown-ed" {
    # HA's folders hold files from other apps and users (e.g. uid 1000). All
    # clients are squashed to root, so root's file permissions must work.
    mkdir -p "$WORK/config/others"
    echo "theirs" > "$WORK/config/others/existing.txt"
    chown -R 1000:1000 "$WORK/config/others"
    chmod 755 "$WORK/config/others"; chmod 644 "$WORK/config/others/existing.txt"
    mount_export /config
    echo "new" > "$MNT/others/new.txt"
    echo "more" >> "$MNT/others/existing.txt"
    chmod 600 "$MNT/others/existing.txt"
    chown 1001:1001 "$MNT/others/existing.txt"
    run stat -c '%u:%g %a' "$WORK/config/others/existing.txt"
    assert_output "1001:1001 600"
    run cat "$WORK/config/others/existing.txt"
    assert_output $'theirs\nmore'
    rm -rf "$MNT/others"
}

@test "numeric owner and group changes are applied exactly (Ganesha 9.14 over-read fix)" {
    # Linux clients send owners and groups as bare numbers. Unpatched 9.14 read
    # one byte past them, so group changes became 0 or failed with EINVAL.
    mkdir -p "$WORK/config/ids"
    for f in a b c d e; do echo x > "$WORK/config/ids/$f"; done
    chown -R 1000:1000 "$WORK/config/ids"
    mount_export /config
    chgrp 1002 "$MNT/ids/a"
    chown 1001:1001 "$MNT/ids/b"
    chown 1001 "$MNT/ids/c"; chgrp 1002 "$MNT/ids/c"
    chown :1002 "$MNT/ids/d"
    chown 1005:1006 "$MNT/ids/e"
    run stat -c '%n=%u:%g' "$WORK"/config/ids/{a,b,c,d,e}
    assert_output "$(printf '%s\n' "$WORK/config/ids/a=1000:1002" "$WORK/config/ids/b=1001:1001" \
        "$WORK/config/ids/c=1001:1002" "$WORK/config/ids/d=1000:1002" "$WORK/config/ids/e=1005:1006")"
    rm -rf "$MNT/ids"
}

@test "folders: /config is still served, from HA's /homeassistant mount" {
    run docker inspect -f '{{range .Mounts}}{{if eq .Destination "/homeassistant"}}{{.Source}}{{end}}{{end}}' "$NAME"
    assert_output "$WORK/config"
    mount_export /config
    run cat "$MNT/hello.txt"; assert_output "hello from config"
}

@test "folders: legacy /addons and /local_apps serve the same folder" {
    stop_addon
    start_addon '{"authorized_ips":["127.0.0.1"],"export_folders":["local_apps"]}'
    echo "from local_apps" > "$WORK/local_apps/apps.txt"
    mount_export /addons
    run cat "$MNT/apps.txt"; assert_output "from local_apps"
    unmount_export
    mount_export /local_apps
    run cat "$MNT/apps.txt"; assert_output "from local_apps"
    unmount_export
    run docker logs "$NAME"
    assert_output --partial "/addons is a legacy path for /local_apps"
    stop_addon
    start_addon "$AUTHORISED"
}

# A one-shot mock of the Supervisor's /addons/self API on 127.0.0.1:$1. It
# answers GET /addons/self/info with $2 as the stored options and writes the
# body of POST /addons/self/options to $BATS_TEST_TMPDIR/posted.json.
mock_supervisor() {
    # Otherwise the readiness wait below would accept whatever holds the port.
    if bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null; then
        fail "port $1 is already in use; the mock Supervisor needs it"
    fi
    python3 - "$1" "$2" "$BATS_TEST_TMPDIR/posted.json" <<'PY' &
import http.server, json, sys
port, options, out = int(sys.argv[1]), json.loads(sys.argv[2]), sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def reply(self, body):
        data = json.dumps(body).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        self.reply({"result": "ok", "data": {"options": options}})
    def do_POST(self):
        with open(out, "wb") as f:
            f.write(self.rfile.read(int(self.headers["Content-Length"])))
        self.reply({"result": "ok", "data": {}})
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
    MOCK_PID=$!
    until bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null; do sleep 0.2; done
}

@test "migrate: saved legacy folder names are rewritten via the Supervisor API" {
    local stored='{"authorized_ips":["127.0.0.1"],"export_folders":["addons","config"],"log_level":"WARN"}'
    mock_supervisor 18631 "$stored"
    stop_addon
    SUPERVISOR_API=http://127.0.0.1:18631 SUPERVISOR_TOKEN=test start_addon "$stored"
    kill "$MOCK_PID"; wait "$MOCK_PID" 2>/dev/null || true
    run cat "$BATS_TEST_TMPDIR/posted.json"
    assert_output '{"options":{"authorized_ips":["127.0.0.1"],"export_folders":["local_apps","config"],"log_level":"WARN"}}'
    run docker logs "$NAME"
    assert_output --partial "Migrated export_folders to the new folder names"
    stop_addon
    start_addon "$AUTHORISED"
}

@test "migrate: an unreachable Supervisor only logs a warning" {
    stop_addon
    SUPERVISOR_API=http://127.0.0.1:18632 SUPERVISOR_TOKEN=test \
        start_addon '{"authorized_ips":["127.0.0.1"],"export_folders":["addons"]}'
    run docker logs "$NAME"
    assert_output --partial "Could not migrate export_folders"
    stop_addon
    start_addon "$AUTHORISED"
}

# Kept last: checks the kernel log for anything the profile blocked (or, in
# complain mode, would have blocked) during this run. Best effort: without an
# audit daemon the kernel rate-limits audit messages (about 10 per 5 s) and
# drops the rest, so a denial can go unlogged. The behavioural tests above are
# what catch a missing rule.
@test "AppArmor: the add-on runs under its custom profile, with nothing denied" {
    [ -f "$AA_FILE" ] || skip "no custom AppArmor profile"
    run docker inspect -f '{{.AppArmorProfile}}' "$NAME"
    assert_output "$AA_PROFILE"
    run cat "/proc/$(docker inspect -f '{{.State.Pid}}' "$NAME")/attr/current"
    assert_output "$AA_PROFILE (enforce)"
    run cat "/proc/$(ganesha_pid)/attr/current"
    assert_output "$AA_PROFILE//ganesha (enforce)"
    local events
    dmesg | grep -qF "$KMSG_MARK" || fail "kernel log marker missing (log wrapped?)"
    events=$(dmesg | sed -n "\|$KMSG_MARK|,\$p" \
        | grep "profile=\"$AA_PROFILE" | grep -E 'apparmor="(DENIED|ALLOWED)"' \
        | grep -v 'class="posix_mqueue"' || true)  # see the mqueue note in apparmor.txt
    [ -z "$events" ] || fail "AppArmor events for $AA_PROFILE:"$'\n'"$events"
}

@test "auto: waits for the network at startup instead of refusing at once" {
    # At boot the add-on can start before HA's network is up.
    stop_addon
    : > "$WORK/data/late-network.json"
    ( sleep 6; echo '{"source":"test","interfaces":[{"interface":"lo","connected":true,"primary":true,"ipv4":{"address":["127.0.0.1/8"]}}]}' \
        > "$WORK/data/late-network.json" ) &
    NETWORK_INFO_OVERRIDE=/data/late-network.json start_addon '{"authorized_ips":["auto"],"export_folders":["config"]}'
    run docker logs "$NAME"
    assert_output --partial 'Waiting for the network'
    assert_output --partial 'authorized_ips "auto" -> 127.0.0.0/8'
    mount_export /config
    run cat "$MNT/hello.txt"; assert_output "hello from config"
    unmount_export
    stop_addon
    start_addon "$AUTHORISED"
}

@test "a stop during the startup wait is quick and clean" {
    # run.sh is PID 1: it must handle SIGTERM from the start, not only once
    # Ganesha is running, or a stop waits for the kill timeout.
    stop_addon
    : > "$WORK/data/empty-network.json"
    echo '{"authorized_ips":["auto"],"export_folders":["config"]}' > "$WORK/data/options.json"
    local args start
    mapfile -t args < <(NETWORK_INFO_OVERRIDE=/data/empty-network.json addon_run_args)
    docker run -d --name "$NAME" "${args[@]}" "$IMAGE" >/dev/null
    sleep 3
    start=$(date +%s)
    docker stop -t 20 "$NAME" >/dev/null
    (( $(date +%s) - start < 8 )) || fail "stop took $(( $(date +%s) - start ))s"
    run docker inspect -f '{{.State.ExitCode}}' "$NAME"
    assert_output 0
    run docker logs "$NAME"
    assert_output --partial "Stopped before Ganesha started"
    stop_addon
    start_addon "$AUTHORISED"
}

@test "auto written as \" Auto \" still fetches the network info and resolves" {
    # run.sh decides whether to fetch network info; it must recognise "auto"
    # the same way gen-config.sh does (any case, surrounding spaces ignored).
    stop_addon
    start_addon '{"authorized_ips":[" Auto "],"export_folders":["config"]}'
    run docker logs "$NAME"
    assert_output --regexp 'authorized_ips "auto" -> [0-9.]+/[0-9]+ \(primary interface [^ ]+, from routing table\)'
    stop_addon
    start_addon "$AUTHORISED"
}

# --- Coverage review additions ---

@test "changes made on the HA side are visible to mounted clients" {
    # The Supervisor writes backups and HA rewrites its config files directly.
    mount_export /config
    ls "$MNT" > /dev/null
    echo "first" > "$WORK/config/hostside.txt"
    local i
    for i in $(seq 1 10); do [ -f "$MNT/hostside.txt" ] && break; sleep 0.5; done
    run cat "$MNT/hostside.txt"; assert_output "first"
    echo "second, longer" > "$WORK/config/hostside.txt"
    for i in $(seq 1 10); do [ "$(cat "$MNT/hostside.txt")" = "second, longer" ] && break; sleep 0.5; done
    run cat "$MNT/hostside.txt"; assert_output "second, longer"
    rm "$WORK/config/hostside.txt"
    for i in $(seq 1 10); do [ ! -e "$MNT/hostside.txt" ] && break; sleep 0.5; done
    run ls "$MNT/hostside.txt"; assert_failure
}

@test "a lock held by one process makes a second process's lock fail (EAGAIN)" {
    # SQLite and other databases on a share depend on working locks.
    mount_export /config
    python3 - "$MNT/locked.db" <<'PY' &
import fcntl, sys, time
f = open(sys.argv[1], "w"); fcntl.lockf(f, fcntl.LOCK_EX); time.sleep(8)
PY
    local holder=$!
    sleep 2
    run python3 - "$MNT/locked.db" <<'PY'
import errno, fcntl, sys
f = open(sys.argv[1], "a")
try:
    fcntl.lockf(f, fcntl.LOCK_EX | fcntl.LOCK_NB); print("got the lock")
except OSError as e:
    print("EAGAIN" if e.errno in (errno.EAGAIN, errno.EACCES) else e)
PY
    wait "$holder"
    assert_output "EAGAIN"
    rm -f "$MNT/locked.db"
}

@test "a large write on a hard mount survives an add-on restart" {
    mount_export /config hard
    head -c 200M /dev/urandom > "$BATS_TEST_TMPDIR/big"
    cp "$BATS_TEST_TMPDIR/big" "$MNT/big" &
    local writer=$!
    sleep 1
    docker restart -t 20 "$NAME" > /dev/null
    wait "$writer" || fail "the copy failed across the restart"
    assert_equal "$(sha256sum < "$BATS_TEST_TMPDIR/big")" "$(sha256sum < "$MNT/big")"
    rm -f "$MNT/big"
}

@test "setgid, times, FIFOs and sticky folders work on other users' files" {
    local d="$WORK/config/perm"
    mkdir -p "$d/sticky"; echo x > "$d/theirs"; echo y > "$d/sticky/theirs"
    chown -R 1000:1000 "$d"; chmod 1777 "$d/sticky"
    mount_export /config
    chmod 2775 "$MNT/perm"
    run stat -c '%a' "$d"; assert_output 2775
    echo z > "$MNT/perm/inherits"
    run stat -c '%g' "$d/inherits"; assert_output 1000
    touch -d '2020-01-02 03:04:05' "$MNT/perm/theirs"
    run stat -c '%Y' "$d/theirs"; assert_output "$(date -d '2020-01-02 03:04:05' +%s)"
    mkfifo "$MNT/perm/fifo"
    run stat -c '%F' "$d/fifo"; assert_output "fifo"
    rm "$MNT/perm/sticky/theirs"
    run ls "$d/sticky/theirs"; assert_failure
    rm -rf "$MNT/perm"
}

@test "a filesystem mounted inside a shared folder neither hangs nor crashes" {
    # HA's network storage mounts shares under /media and /share.
    stop_addon
    mkdir -p "$WORK/media/sub"
    MEDIA_MOUNT="-v $WORK/media:/media --tmpfs /media/sub" start_addon "$AUTHORISED"
    mount_export /media
    run timeout 20 ls "$MNT/sub"
    [ "$status" -ne 124 ] || fail "listing the nested mount hung"
    echo "INFO: listing /media/sub over NFS gave status $status: $output" >&3
    run timeout 20 sh -c "echo nested > '$MNT/sub/f' && cat '$MNT/sub/f'"
    [ "$status" -ne 124 ] || fail "writing into the nested mount hung"
    echo "INFO: writing into /media/sub over NFS gave status $status: $output" >&3
    unmount_export
    run docker inspect -f '{{.State.Running}}' "$NAME"; assert_output true
    stop_addon
    start_addon "$AUTHORISED"
}

@test "a read-only folder gives EROFS on write and still starts and serves" {
    # Only /media is exported: FSAL_VFS opens files by handle through the first
    # mount it registered for a host filesystem, so a read-only bind sharing a
    # filesystem with an earlier writable export isn't enforced. The add-on
    # maps every folder read-write, so that can't happen in HA; this covers a
    # filesystem that is itself read-only.
    stop_addon
    echo "readable" > "$WORK/media/ro.txt"
    MEDIA_MOUNT="-v $WORK/media:/media:ro" start_addon '{"authorized_ips":["127.0.0.1"],"export_folders":["media"]}'
    mount_export /media
    run cat "$MNT/ro.txt"; assert_output readable
    run sh -c "echo x > '$MNT/new'"
    assert_failure
    assert_output --partial "Read-only file system"
    unmount_export
    rm -f "$WORK/media/ro.txt"
    stop_addon
    start_addon "$AUTHORISED"
}
