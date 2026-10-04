#!/usr/bin/env bash
# Checks the installed add-on on the HAOS test VM (tests/haos/haos-vm.sh):
# what the Supervisor reports, the add-on's log, AppArmor events in the host
# kernel log, and NFS from this machine through the VM's forwarded port.
#
#   [NFS_EXPORT=/share] haos-checks.sh SLUG [EXPECT_VERSION]
#
# NFS_EXPORT (default /config) is the export the NFS checks use; reading
# configuration.yaml is only checked on /config.
# Prints PASS/FAIL per check and exits non-zero if any failed.
set -uo pipefail

SLUG=$1
EXPECT_VERSION=${2:-}
VM="$(dirname "$0")/haos-vm.sh"
FAILED=0

pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; FAILED=1; }
check() {  # <description> <command...>: PASS if the command succeeds
    local what=$1; shift
    if "$@" > /dev/null 2>&1; then pass "$what"; else fail "$what"; fi
}
jqr() { docker run --rm -i nfs-ganesha-addon-haos jq -r "$@"; }

INFO=$("$VM" api GET "addons/$SLUG/info")
# The Supervisor's log endpoint returns plain text, which the API helper can't
# relay, so read the container log on the HAOS console.
LOG=$(WAIT=4 "$VM" console "docker logs app_$SLUG 2>&1 | tail -200")

# --- What the Supervisor reports ---
[ -z "$EXPECT_VERSION" ] || check "version is $EXPECT_VERSION" \
    test "$(jqr .version <<< "$INFO")" = "$EXPECT_VERSION"
check "add-on is started" test "$(jqr .state <<< "$INFO")" = started
check "security rating is 4" test "$(jqr .rating <<< "$INFO")" = 4
check "AppArmor uses the custom profile" test "$(jqr .apparmor <<< "$INFO")" = profile
check "privileges are exactly DAC_READ_SEARCH and SYS_RESOURCE" \
    test "$(jqr '.privileged | sort | join(" ")' <<< "$INFO")" = "DAC_READ_SEARCH SYS_RESOURCE"
check "Supervisor API access (hassio_api) is granted" test "$(jqr .hassio_api <<< "$INFO")" = true

# --- The add-on's log ---
check "log shows the app version" grep -q "^\[NFS\] App version: $(jqr .version <<< "$INFO")" <<< "$LOG"
check "log shows the Ganesha version" grep -q "Ganesha version: NFS-Ganesha Release = V9" <<< "$LOG"
check "log has no ERROR lines" bash -c '! grep -q "\[ERROR\]"' <<< "$LOG"
check "log has no Ganesha CRIT/MAJ/FATAL lines" bash -c '! grep -qE ":(CRIT|MAJ|FATAL) "' <<< "$LOG"
check "IO-flusher protection active (no EPERM warning)" bash -c '! grep -q PR_SET_IO_FLUSHER' <<< "$LOG"

# --- AppArmor on HAOS's own kernel and parser ---
KERNEL=$("$VM" console "journalctl -k --no-pager -o cat | grep 'profile=\"$SLUG' | grep -E 'DENIED|ALLOWED' | grep -v posix_mqueue | tail -20")
if grep -qE 'apparmor="(DENIED|ALLOWED)"' <<< "$KERNEL"; then
    fail "no AppArmor denials for $SLUG in the host kernel log"
    grep -E 'apparmor=' <<< "$KERNEL" | sed 's/^/      /'
else
    pass "no AppArmor denials for $SLUG in the host kernel log"
fi

# --- NFS from this machine (the VM sees the client as 10.0.2.2) ---
NFS=$(docker run --rm --privileged --network host -e "E=${NFS_EXPORT:-/config}" --entrypoint bash nfs-ganesha-addon-toolbox -c '
    m=/m; mkdir -p $m; o="port=12049,soft,timeo=50,retrans=2"
    r() { if eval "$2" > /dev/null 2>&1; then echo "PASS  NFS: $1"; else echo "FAIL  NFS: $1"; fi; }
    for v in 4.0 4.1 4.2; do
        if mount -t nfs4 -o "$o,vers=$v" "127.0.0.1:$E" $m; then
            [ "$E" != /config ] || r "vers=$v read configuration.yaml" "test -s $m/configuration.yaml"
            r "vers=$v write, rename, delete" "head -c 5M /dev/urandom > $m/.nfs-check && mv $m/.nfs-check $m/.nfs-check2 && rm $m/.nfs-check2"
            umount $m
        else echo "FAIL  NFS: vers=$v mount $E"; fi
    done
    mount -t nfs4 -o "$o" "127.0.0.1:$E" $m || { echo "FAIL  NFS: mount for ownership checks"; exit; }
    mkdir -p $m/.ids; for f in a b c d e; do echo x > $m/.ids/$f; done; chown -R 1000:1000 $m/.ids
    chgrp 1002 $m/.ids/a; chown 1001:1001 $m/.ids/b; chown 1001 $m/.ids/c; chgrp 1002 $m/.ids/c
    chown :1002 $m/.ids/d; chown 1005:1006 $m/.ids/e 2>/dev/null
    got=$(stat -c %u:%g $m/.ids/a $m/.ids/b $m/.ids/c $m/.ids/d $m/.ids/e | tr "\n" " ")
    r "numeric owner/group changes ($got)" "[ \"$got\" = \"1000:1002 1001:1001 1001:1002 1000:1002 1005:1006 \" ]"
    r "chmod and write on another user'\''s file" "chmod 600 $m/.ids/b && echo y >> $m/.ids/b"
    r "symlink and hard link" "ln -s a $m/.ids/sl && ln $m/.ids/a $m/.ids/hl && test \"\$(readlink $m/.ids/sl)\" = a"
    rm -rf $m/.ids; umount $m
    if mount -t nfs4 -o "$o" 127.0.0.1:/ $m; then echo "INFO  NFS: pseudo-root lists: $(ls $m | tr "\n" " ")"; umount $m; fi')
echo "$NFS"
grep -q '^FAIL' <<< "$NFS" && FAILED=1

exit "$FAILED"
