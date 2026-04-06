#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: scripts/test-workflows-act.sh [ci|release|all] [--full]

Runs GitHub workflows locally with act.

Modes:
  ci       Run CI workflow checks.
  release  Run release workflow checks.
  all      Run both CI and release checks (default).

Flags:
  --full   Run heavier jobs too:
           - CI: build matrix job
           - Release: build matrix job (publishes if credentials work)

Environment variables for --full release testing:
  GITHUB_TOKEN  GitHub token used by docker/login-action.
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_docker() {
  if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon is not running or not reachable." >&2
    exit 1
  fi
}

mode="all"
full="false"

for arg in "$@"; do
  case "$arg" in
    ci|release|all)
      mode="$arg"
      ;;
    --full)
      full="true"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      usage
      exit 1
      ;;
  esac
done

require_cmd act
require_cmd docker
require_docker

run_ci() {
  echo "==> Running CI workflow (addon-check)"
  act pull_request \
    -W "$ROOT_DIR/.github/workflows/addon-ci.yml" \
    --job addon-check \
    --container-architecture linux/amd64

  if [[ "$full" == "true" ]]; then
    echo "==> Running CI workflow build matrix"
    act pull_request \
      -W "$ROOT_DIR/.github/workflows/addon-ci.yml" \
      --job build \
      --container-architecture linux/amd64
  fi
}

run_release() {
  echo "==> Running release workflow dry-run on current HEAD push context"
  act push \
    -W "$ROOT_DIR/.github/workflows/addon-release.yml" \
    --dryrun \
    --container-architecture linux/amd64

  if [[ "$full" == "true" ]]; then
    if [[ -z "${GITHUB_TOKEN:-}" ]]; then
      echo "GITHUB_TOKEN is required for --full release testing." >&2
      exit 1
    fi

    echo "==> Running release workflow publish matrix"
    act push \
      -W "$ROOT_DIR/.github/workflows/addon-release.yml" \
      --job build \
      --container-architecture linux/amd64 \
      -s GITHUB_TOKEN="$GITHUB_TOKEN"
  fi
}

case "$mode" in
  ci)
    run_ci
    ;;
  release)
    run_release
    ;;
  all)
    run_ci
    run_release
    ;;
esac

echo "==> act workflow testing complete"
