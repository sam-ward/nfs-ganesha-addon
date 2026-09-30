#!/usr/bin/env bats
bats_require_minimum_version 1.5.0   # for run --separate-stderr
bats_load_library bats-support
bats_load_library bats-assert

GEN="$BATS_TEST_DIRNAME/../../nfs-ganesha/gen-config.sh"

setup() {
    ROOT="$BATS_TEST_TMPDIR/root"
    mkdir -p "$ROOT"/{config,ssl,addons,addon_configs,backup,share,media}
}

gen() { bash "$GEN" "$BATS_TEST_DIRNAME/fixtures/$1.json" "$ROOT"; }

@test "golden: output matches pre-refactor run.sh for every fixture" {
    for f in "$BATS_TEST_DIRNAME"/fixtures/*.json; do
        n=$(basename "$f" .json)
        run --separate-stderr gen "$n"
        assert_success
        diff -u "$BATS_TEST_DIRNAME/golden/$n.conf" <(printf '%s\n' "$output") \
            || fail "golden mismatch for $n"
    done
}

@test "security: every EXPORT denies by default and grants RW only inside CLIENT" {
    run --separate-stderr gen default
    # Top-level (4-space indent) Access_Type in each EXPORT must be None.
    assert_equal "$(grep -c '^EXPORT$' <<< "$output")" 7
    assert_equal "$(grep -c '^    Access_Type = None;$' <<< "$output")" 7
    # RW only appears at CLIENT depth (8 spaces), once per export.
    assert_equal "$(grep -c 'Access_Type = RW;' <<< "$output")" 7
    assert_equal "$(grep -c '^        Access_Type = RW;$' <<< "$output")" 7
}

@test "security: CLIENT list is exactly authorized_ips" {
    run --separate-stderr gen single-ip
    assert_equal "$(grep -c 'Clients = 192.168.1.50;' <<< "$output")" 2
    refute_output --partial 'Clients = *'
}

@test "protocol: NFSv4 only, NLM and RQUOTA off" {
    run --separate-stderr gen default
    assert_output --partial 'NFS_Protocols = 4;'
    assert_output --partial 'Enable_NLM = false;'
    assert_output --partial 'Enable_RQUOTA = false;'
    refute_output --regexp 'Protocols = [^4]'
}

# Runs the generator on inline JSON options (for cases without a golden file).
gen_json() {
    printf '%s' "$1" > "$BATS_TEST_TMPDIR/options.json"
    bash "$GEN" "$BATS_TEST_TMPDIR/options.json" "$ROOT"
}

@test "missing folder is skipped with a warning, others still exported" {
    rmdir "$ROOT/media"
    run --separate-stderr gen_json '{"authorized_ips":["192.168.1.0/24"],"export_folders":["config","media"]}'
    assert_success
    assert_equal "$(grep -c '^EXPORT$' <<< "$output")" 1
    assert_output --partial 'Path = "/config";'
    [[ "$stderr" == *"/media does not exist"* ]]
}

@test "security: empty export_folders refuses to start instead of exporting /" {
    run --separate-stderr gen_json '{"authorized_ips":["192.168.1.0/24"],"export_folders":[]}'
    assert_failure
    refute_output --partial 'Path = "/";'
    [[ "$stderr" == *"No export folders"* ]]
}

@test "security: empty folder names are never exported as /" {
    run --separate-stderr gen_json '{"authorized_ips":["192.168.1.0/24"],"export_folders":["","config"]}'
    assert_success
    refute_output --partial 'Path = "/";'
    assert_equal "$(grep -c '^EXPORT$' <<< "$output")" 1
    assert_output --partial 'Path = "/config";'
}

@test "security: folder names outside the allowed list are rejected" {
    run --separate-stderr gen_json '{"authorized_ips":["192.168.1.0/24"],"export_folders":["../etc","config"]}'
    assert_success
    refute_output --partial 'etc'
    assert_equal "$(grep -c '^EXPORT$' <<< "$output")" 1
    [[ "$stderr" == *"Unknown export folder"* ]]
}

@test "no existing folders refuses to start" {
    rmdir "$ROOT/media"
    run --separate-stderr gen_json '{"authorized_ips":["192.168.1.0/24"],"export_folders":["media"]}'
    assert_failure
    [[ "$stderr" == *"No export folders"* ]]
}

@test "security: empty authorized_ips refuses to start" {
    run --separate-stderr gen_json '{"authorized_ips":[],"export_folders":["config"]}'
    assert_failure
    refute_output --partial 'Clients = ;'
    [[ "$stderr" == *"authorized_ips"* ]]
}

@test "blank authorized_ips entries are dropped" {
    run --separate-stderr gen_json '{"authorized_ips":["", " 10.0.0.5 ", "192.168.1.0/24"],"export_folders":["config"]}'
    assert_success
    assert_output --partial 'Clients = 10.0.0.5,192.168.1.0/24;'
}

@test "security: only blank authorized_ips refuses to start" {
    run --separate-stderr gen_json '{"authorized_ips":["", "  "],"export_folders":["config"]}'
    assert_failure
    [[ "$stderr" == *"authorized_ips"* ]]
}

@test "export ids are unique and sequential from 10" {
    run --separate-stderr gen default
    assert_equal "$(grep -o 'Export_Id = [0-9]*' <<< "$output" | awk '{print $3}' | tr '\n' ' ')" "10 11 12 13 14 15 16 "
}
