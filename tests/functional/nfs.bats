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

@test "NFSv4.2 server-side copy, allocate and sparse seek" {
    mount_export /config "vers=4.2"
    check_version_negotiated 4.2
    run python3 - "$MNT" <<'PY'
import os, sys
d = sys.argv[1]
data = os.urandom(4 << 20)
with open(f"{d}/src.bin", "wb") as f:
    f.write(data)
with open(f"{d}/src.bin", "rb") as i, open(f"{d}/dst.bin", "wb") as o:  # COPY
    assert os.copy_file_range(i.fileno(), o.fileno(), len(data)) == len(data)
with open(f"{d}/dst.bin", "rb") as f:
    assert f.read() == data, "copy_file_range content differs"
fd = os.open(f"{d}/alloc.bin", os.O_CREAT | os.O_RDWR)  # ALLOCATE
os.posix_fallocate(fd, 0, 1 << 20)
assert os.fstat(fd).st_size == 1 << 20
os.close(fd)
with open(f"{d}/sparse.bin", "wb") as f:  # SEEK / READ_PLUS
    f.seek(8 << 20)
    f.write(b"tail")
fd = os.open(f"{d}/sparse.bin", os.O_RDONLY)
assert os.lseek(fd, 0, os.SEEK_DATA) == 8 << 20, "SEEK_DATA did not skip the hole"
os.close(fd)
with open(f"{d}/sparse.bin", "rb") as f:
    buf = f.read()
assert buf[: 8 << 20] == bytes(8 << 20) and buf[-4:] == b"tail", "sparse read wrong"
for n in ("src", "dst", "alloc", "sparse"):
    os.remove(f"{d}/{n}.bin")
print("ok")
PY
    assert_success
    assert_output "ok"
}

@test "pseudo-root lists exactly the exported folders" {
    mount_export /
    run ls "$MNT"
    assert_output $'config\nmedia'
}

@test "non-exported folder cannot be mounted" {
    run mount_export /backup
    assert_failure
}

@test "unauthorised client is refused (default deny from 1.1.0)" {
    stop_addon
    start_addon '{"authorized_ips":["192.0.2.1"],"export_folders":["config"]}'
    run mount_export /config
    assert_failure
    stop_addon
    start_addon "$AUTHORISED"   # restore for any later tests
}

@test "startup failure is visible in the log when port 2049 is taken" {
    # 1.2.0 tails Ganesha's log file and kills the tail as soon as Ganesha exits,
    # so the reason never reaches the add-on log ("Ganesha exited" only).
    skip "enabled by log/exit-code change in PR #4 work"
    stop_addon
    python3 -m http.server 2049 --bind 0.0.0.0 >/dev/null 2>&1 &
    local holder=$!
    WORK="$REPO_ROOT/.test-work"
    docker run -d --name "$NAME" --network host --cap-add SYS_ADMIN --cap-add DAC_READ_SEARCH \
        --security-opt apparmor=unconfined -v "$WORK/data:/data" -v "$WORK/config:/config" \
        -v "$WORK/media:/media" "$IMAGE" >/dev/null
    sleep 10
    run docker logs "$NAME"
    kill "$holder"
    assert_output --regexp '[Aa]ddress already in use|bind'
    stop_addon
    start_addon "$AUTHORISED"
}
