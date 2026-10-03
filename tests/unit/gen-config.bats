#!/usr/bin/env bats
bats_require_minimum_version 1.5.0   # for run --separate-stderr
bats_load_library bats-support
bats_load_library bats-assert

GEN="$BATS_TEST_DIRNAME/../../nfs-ganesha/gen-config.sh"
MIGRATE="$BATS_TEST_DIRNAME/../../nfs-ganesha/migrate-options.sh"
CONFIG_YAML="$BATS_TEST_DIRNAME/../../nfs-ganesha/config.yaml"

setup() {
    ROOT="$BATS_TEST_TMPDIR/root"
    # The folders as the Supervisor mounts them (config.yaml map).
    mkdir -p "$ROOT"/{homeassistant,ssl,local_apps,app_configs,backup,share,media}
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
    # 7 folders plus the /addons and /addon_configs legacy aliases.
    # Top-level (4-space indent) Access_Type in each EXPORT must be None.
    assert_equal "$(grep -c '^EXPORT$' <<< "$output")" 9
    assert_equal "$(grep -c '^    Access_Type = None;$' <<< "$output")" 9
    # RW only appears at CLIENT depth (8 spaces), once per export.
    assert_equal "$(grep -c 'Access_Type = RW;' <<< "$output")" 9
    assert_equal "$(grep -c '^        Access_Type = RW;$' <<< "$output")" 9
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

@test "Ganesha 6 io_flusher: failure is tolerated as a safety net" {
    run --separate-stderr gen default
    assert_output --partial 'Allow_Set_Io_Flusher_Fail = true;'
}

@test "config.yaml grants exactly the capabilities the add-on needs" {
    run python3 -c 'import sys, yaml; print(" ".join(sorted(yaml.safe_load(open(sys.argv[1]))["privileged"])))' "$CONFIG_YAML"
    assert_output "DAC_READ_SEARCH SYS_RESOURCE"
}

@test "config.yaml leaves AppArmor enabled" {
    run python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1])).get("apparmor", True))' "$CONFIG_YAML"
    assert_output "True"
}

@test "log_level missing (upgraded install) defaults to WARN with 1.2.0 muting" {
    run --separate-stderr gen single-ip
    assert_output --partial 'Default_Log_Level = WARN;'
    assert_output --partial 'TIRPC = FATAL;'
}

@test "log_level WARN keeps component muting" {
    run --separate-stderr gen warn
    assert_output --partial 'Default_Log_Level = WARN;'
    assert_output --partial 'DISPATCH = FATAL;'
}

@test "log_level FULL_DEBUG drops muting so nothing is hidden" {
    run --separate-stderr gen debug
    assert_output --partial 'Default_Log_Level = FULL_DEBUG;'
    refute_output --partial 'COMPONENTS'
}

# Runs the generator on inline JSON options (for cases without a golden file).
# $2, if given, names a network-info fixture (tests/unit/fixtures/network/).
gen_json() {
    printf '%s' "$1" > "$BATS_TEST_TMPDIR/options.json"
    bash "$GEN" "$BATS_TEST_TMPDIR/options.json" "$ROOT" \
        ${2:+"$BATS_TEST_DIRNAME/fixtures/network/$2.json"}
}

@test "missing folder is skipped with a warning, others still exported" {
    rmdir "$ROOT/media"
    run --separate-stderr gen_json '{"authorized_ips":["192.168.1.0/24"],"export_folders":["config","media"]}'
    assert_success
    assert_equal "$(grep -c '^EXPORT$' <<< "$output")" 1
    assert_output --partial 'Pseudo = "/config";'
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
    assert_output --partial 'Path = "/homeassistant";'
    refute_output --partial 'Pseudo = "/";'
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
    assert_equal "$(grep -o 'Export_Id = [0-9]*' <<< "$output" | awk '{print $3}' | tr '\n' ' ')" "10 11 12 13 14 15 16 17 18 "
}


# --- authorized_ips "auto" (HA's primary LAN subnet) ---

AUTO='{"authorized_ips":["auto"],"export_folders":["config"]}'

@test "auto: wired primary interface resolves to its network" {
    run --separate-stderr gen_json "$AUTO" wired
    assert_success
    assert_output --partial 'Clients = 192.168.1.0/24;'
    [[ "$stderr" == *'authorized_ips "auto" -> 192.168.1.0/24 (primary interface end0, from Supervisor)'* ]]
}

@test "auto: non-octet prefix (/22) gives the right network" {
    run --separate-stderr gen_json "$AUTO" wifi
    assert_output --partial 'Clients = 10.0.4.0/22;'
}

@test "auto: only the primary interface is used" {
    run --separate-stderr gen_json "$AUTO" multi
    assert_output --partial 'Clients = 172.16.0.0/16;'
    refute_output --partial '192.168.50'
}

@test "auto: Supervisor v2 field names are understood" {
    run --separate-stderr gen_json "$AUTO" v2-shape
    assert_output --partial 'Clients = 192.168.1.0/24;'
}

@test "auto: routing-table fallback is understood and named in the log" {
    run --separate-stderr gen_json "$AUTO" fallback
    assert_output --partial 'Clients = 192.168.20.0/24;'
    [[ "$stderr" == *'(primary interface eth0, from routing table)'* ]]
}

@test "auto: combined with explicit entries, both are listed" {
    run --separate-stderr gen_json '{"authorized_ips":["auto","10.20.0.0/24"],"export_folders":["config"]}' wired
    assert_output --partial 'Clients = 192.168.1.0/24,10.20.0.0/24;'
}

@test "auto: duplicates are removed" {
    run --separate-stderr gen_json '{"authorized_ips":["192.168.1.0/24","auto"],"export_folders":["config"]}' wired
    assert_output --partial 'Clients = 192.168.1.0/24;'
}

@test "security: auto with a disconnected primary interface refuses to start" {
    run --separate-stderr gen_json "$AUTO" primary-disconnected
    assert_failure
    [[ "$stderr" == *'authorized_ips "auto" could not be resolved'* ]]
}

@test "security: auto with no IPv4 address refuses to start" {
    run --separate-stderr gen_json "$AUTO" no-ipv4
    assert_failure
    [[ "$stderr" == *'could not be resolved'* ]]
}

@test "security: auto never resolves to an overly broad network (/0-/7)" {
    run --separate-stderr gen_json "$AUTO" too-broad
    assert_failure
    [[ "$stderr" == *'could not be resolved'* ]]
}

@test "security: auto with no network info refuses to start" {
    run --separate-stderr gen_json "$AUTO"
    assert_failure
    [[ "$stderr" == *'could not be resolved'* ]]
    refute_output --partial 'Clients'
}

@test "explicit-only authorized_ips ignore network info" {
    run --separate-stderr gen_json '{"authorized_ips":["10.9.9.9"],"export_folders":["config"]}' wired
    assert_output --partial 'Clients = 10.9.9.9;'
    refute_output --partial '192.168.1.0/24'
}

@test "config.yaml defaults for new installs: auto, and share/media/backup only" {
    run python3 -c 'import sys, json, yaml; o = yaml.safe_load(open(sys.argv[1]))["options"]; print(json.dumps([o["authorized_ips"], o["export_folders"]]))' "$CONFIG_YAML"
    assert_output '[["auto"], ["share", "media", "backup"]]'
}

# --- Folder mappings (as the Samba add-on: new map names, legacy aliases) ---

# Prints "Path -> Pseudo" for each EXPORT, in order.
exports() { awk -F'"' '/^    Path = /{p=$2} /^    Pseudo = /{print p " -> " $2}' <<< "$output"; }

@test "folders: config is served from /homeassistant but still mounted as /config" {
    run --separate-stderr gen_json '{"authorized_ips":["192.168.1.0/24"],"export_folders":["config"]}'
    assert_success
    assert_equal "$(exports)" "/homeassistant -> /config"
}

@test "folders: local_apps and app_configs also answer on their legacy paths" {
    run --separate-stderr gen_json '{"authorized_ips":["192.168.1.0/24"],"export_folders":["local_apps","app_configs"]}'
    assert_equal "$(exports)" "$(printf '%s\n' \
        '/local_apps -> /local_apps' '/app_configs -> /app_configs' \
        '/local_apps -> /addons' '/app_configs -> /addon_configs')"
    [[ "$stderr" == *'/addons is a legacy path for /local_apps'* ]]
}

@test "folders: legacy option names give the same exports as the new ones" {
    run --separate-stderr gen_json '{"authorized_ips":["192.168.1.0/24"],"export_folders":["addons","addon_configs"]}'
    assert_equal "$(exports)" "$(printf '%s\n' \
        '/local_apps -> /local_apps' '/app_configs -> /app_configs' \
        '/local_apps -> /addons' '/app_configs -> /addon_configs')"
}

@test "folders: a folder listed under both names is exported once" {
    run --separate-stderr gen_json '{"authorized_ips":["192.168.1.0/24"],"export_folders":["addons","local_apps"]}'
    assert_equal "$(exports)" "$(printf '%s\n' '/local_apps -> /local_apps' '/local_apps -> /addons')"
}

@test "folders: aliases come after the primary exports, so primary export ids don't move" {
    run --separate-stderr gen_json '{"authorized_ips":["192.168.1.0/24"],"export_folders":["local_apps","share"]}'
    assert_output --regexp 'Export_Id = 10;[^}]*Pseudo = "/local_apps"'
    assert_output --regexp 'Export_Id = 11;[^}]*Pseudo = "/share"'
    assert_output --regexp 'Export_Id = 12;[^}]*Pseudo = "/addons"'
}

@test "config.yaml maps folders with the current Supervisor names" {
    run python3 -c 'import sys, yaml; print(" ".join(sorted(yaml.safe_load(open(sys.argv[1]))["map"])))' "$CONFIG_YAML"
    assert_output "all_app_configs:rw backup:rw homeassistant_config:rw local_apps:rw media:rw share:rw ssl:rw"
}

# --- Migrating saved options (migrate-options.sh) ---

@test "migrate: legacy folder names are renamed, everything else kept" {
    run bash "$MIGRATE" <<< '{"authorized_ips":["10.0.0.0/8"],"export_folders":["addons","config","addon_configs"],"log_level":"WARN"}'
    assert_success
    assert_output '{"options":{"authorized_ips":["10.0.0.0/8"],"export_folders":["local_apps","config","app_configs"],"log_level":"WARN"}}'
}

@test "migrate: a folder listed under both names ends up once" {
    run bash "$MIGRATE" <<< '{"authorized_ips":["auto"],"export_folders":["addons","local_apps","share"]}'
    assert_output '{"options":{"authorized_ips":["auto"],"export_folders":["local_apps","share"]}}'
}

@test "migrate: nothing to do prints nothing" {
    run bash "$MIGRATE" <<< '{"authorized_ips":["auto"],"export_folders":["share","media"]}'
    assert_success
    assert_output ""
    run bash "$MIGRATE" <<< '{"authorized_ips":["auto"]}'
    assert_success
    assert_output ""
}
