#!/usr/bin/env bats
bats_load_library bats-support
bats_load_library bats-assert

CHECK="$BATS_TEST_DIRNAME/../../scripts/release-check.sh"

# Runs release-check.sh on a config.yaml version and a CHANGELOG heading line.
check() {  # <config version> <changelog heading line> <args...>
    printf 'version: "%s"\n' "$1" > "$BATS_TEST_TMPDIR/config.yaml"
    printf '# Changelog\n\n%s\n - an entry\n' "$2" > "$BATS_TEST_TMPDIR/CHANGELOG.md"
    shift 2
    CONFIG_YAML="$BATS_TEST_TMPDIR/config.yaml" CHANGELOG="$BATS_TEST_TMPDIR/CHANGELOG.md" bash "$CHECK" "$@"
}

@test "tag: a final release with a dated CHANGELOG entry passes and prints the version" {
    run check 2.0.0 "## [2.0.0] - 2026-10-20" tag v2.0.0
    assert_success
    assert_output "2.0.0"
}

@test "tag: the tag must match config.yaml's version" {
    run check 2.0.0 "## [2.0.0] - 2026-10-20" tag v2.0.1
    assert_failure
    assert_output --partial "doesn't match"
}

@test "tag: a final release with the placeholder date is refused" {
    run check 2.0.0 "## [2.0.0] - YYYY-MM-DD" tag v2.0.0
    assert_failure
    assert_output --partial "release date"
    run check 2.0.0 "## [2.0.0]" tag v2.0.0
    assert_failure
}

@test "tag: a release candidate may keep the placeholder date" {
    run check 2.0.0-rc1 "## [2.0.0] - YYYY-MM-DD" tag v2.0.0-rc1
    assert_success
    assert_output "2.0.0-rc1"
}

@test "dry-run: refused when the version has already been released" {
    EXISTING_TAGS=$'v1.2.1\nv2.0.0' run check 2.0.0 "## [2.0.0] - 2026-10-20" dry-run
    assert_failure
    assert_output --partial "already released"
}

@test "dry-run: a version that was never tagged is allowed" {
    EXISTING_TAGS=$'v1.2.1\nv2.0.0' run check 0.0.0-publishtest "## [2.0.0] - YYYY-MM-DD" dry-run
    assert_success
    assert_output "0.0.0-publishtest"
}
