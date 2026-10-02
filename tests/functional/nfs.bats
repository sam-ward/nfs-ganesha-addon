#!/usr/bin/env bats
bats_load_library bats-support
bats_load_library bats-assert
load helpers

AUTHORISED='{"authorized_ips":["127.0.0.1"],"export_folders":["config","media"]}'

setup_file() {
    reset_log
    build_image
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

@test "NFSv4.2 COPY (server-side copy) is handled by the server" {
    # Ganesha 4.3 (bookworm) returns an error for COPY and the Linux client then
    # copies the data itself, so only the op counters reveal it.
    skip "Ganesha 4.3 rejects COPY; re-check on 6.x in the PR #4 work"
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
    mount_export /config
    run cat "$MNT/hello.txt"
    assert_failure
    assert_output --partial "Operation not permitted"
    unmount_export
    stop_addon
    start_addon "$AUTHORISED"
}

@test "IO-flusher protection is active with config.yaml's capabilities" {
    skip "Ganesha 4.3 never calls PR_SET_IO_FLUSHER; enabled by the trixie upgrade"
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
    stop_addon
    start_addon "$AUTHORISED"
}

@test "without SYS_RESOURCE and without the allow-fail line, Ganesha 6 refuses to start" {
    skip "Ganesha 4.3 never calls PR_SET_IO_FLUSHER; enabled by the trixie upgrade"
    # Proves the config line is what keeps the add-on alive, so it isn't removed as unused.
    # Test-only override: runs Ganesha directly on a config with the line stripped.
    stop_addon
    local args
    mapfile -t args < <(DROP_CAPS=SYS_RESOURCE addon_run_args)
    docker run -d --name "$NAME" "${args[@]}" --entrypoint sh "$IMAGE" -c '
        /gen-config.sh > /tmp/g.conf && sed -i "/Allow_Set_Io_Flusher_Fail/d" /tmp/g.conf
        mkdir -p /var/run/dbus && dbus-daemon --system --fork
        exec /usr/bin/ganesha.nfsd -F -L /dev/stdout -f /tmp/g.conf' >/dev/null
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
    # 1.2.0 tails Ganesha's log file and kills the tail as soon as Ganesha exits,
    # so the reason never reaches the add-on log ("Ganesha exited" only).
    skip "enabled by log/exit-code change in PR #4 work"
    stop_addon
    python3 -m http.server 2049 --bind 0.0.0.0 >/dev/null 2>&1 &
    local holder=$!
    WORK="$REPO_ROOT/.test-work"
    local args
    mapfile -t args < <(addon_run_args)
    docker run -d --name "$NAME" "${args[@]}" "$IMAGE" >/dev/null
    sleep 10
    run docker logs "$NAME"
    kill "$holder"
    assert_output --regexp '[Aa]ddress already in use|bind'
    stop_addon
    start_addon "$AUTHORISED"
}
