#!/usr/bin/env bats
bats_load_library bats-support
bats_load_library bats-assert

CHECK="$BATS_TEST_DIRNAME/../../scripts/check-version.sh"

# Runs check-version.sh on a config.yaml version and a CHANGELOG's headings.
check() {  # <config version> <heading>...
    printf 'version: "%s"\n' "$1" > "$BATS_TEST_TMPDIR/config.yaml"
    shift
    printf '## [%s]\n' "$@" > "$BATS_TEST_TMPDIR/CHANGELOG.md"
    CONFIG_YAML="$BATS_TEST_TMPDIR/config.yaml" CHANGELOG="$BATS_TEST_TMPDIR/CHANGELOG.md" bash "$CHECK"
}

@test "matching versions pass" {
    run check 1.2.1 1.2.1 1.2.0
    assert_success
}

@test "a mismatch fails" {
    run check 1.3.0 1.2.1
    assert_failure
    assert_output --partial "version mismatch"
}

@test "an [Unreleased] heading above the newest release is skipped" {
    run check 1.2.1 Unreleased 1.2.1
    assert_success
}

@test "a release candidate matches its release's heading" {
    run check 2.0.0-rc1 2.0.0 1.2.1
    assert_success
    run check 2.0.0-rc12 2.0.0
    assert_success
}

@test "a release candidate doesn't match an older release" {
    run check 2.0.0-rc1 1.2.1
    assert_failure
}

@test "only -rcN suffixes count as release candidates" {
    run check 2.0.0-beta 2.0.0
    assert_failure
    run check 2.0.0-rc 2.0.0
    assert_failure
}
