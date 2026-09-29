#!/usr/bin/env bash
# CLI flag checks.
#
#   1. self-test   the fixtures hold one violation per rule; the checker must
#                  find exactly those and nothing in the clean fixture
#   2. repository  tpg-fleet, and tpg-aks-infra when FLEET_SIBLING points at it
#                  or a sibling directory of that name exists
#   3. live CLIs   --against-cli, when the binaries are installed: every flag
#                  the repository uses must exist in that binary's own --help
#   4. zero defaults  check_zero_defaults.py: no jq or yq alternative falls back
#                  to true or a non-zero number (it would also replace an
#                  explicit false; design decision I22), in both repositories
#
# Usage: tests/cli-flags/run.sh [--against-cli]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
CHECK="${HERE}/check_cli_flags.py"
AGAINST=()
[[ "${1:-}" != "--against-cli" ]] || AGAINST=(--against-cli)

echo "== self-test: planted violations in tests/cli-flags/fixtures"
python3 "$CHECK" "${HERE}/fixtures" --expect-only \
  --expect helm4-list-all \
  --expect helm4-atomic \
  --expect helm4-force \
  --expect helm4-create-pods \
  --expect helm4-post-renderer-path \
  --expect helm4-registry-login-path \
  --expect kubectl-export \
  --expect kubectl-run-generator \
  --expect kubectl-delete-cascade-bool \
  --expect kubectl-rollout-status-watch-false \
  --expect argo-submit-instanceid-flag

echo
echo "== tpg-fleet"
scan=("$ROOT/bootstrap" "$ROOT/charts" "$ROOT/clusters" "$ROOT/docs" "$ROOT/monitoring"
      "$ROOT/platform" "$ROOT/scripts" "$ROOT/vault" "$ROOT/workflows" "$ROOT/README.md")
python3 "$CHECK" "${scan[@]}" "${AGAINST[@]}"

INFRA="${FLEET_SIBLING:-$(cd "$ROOT/.." && pwd)/tpg-aks-infra}"
if [[ -d "$INFRA" ]]; then
  echo
  echo "== tpg-aks-infra (${INFRA})"
  python3 "$CHECK" "$INFRA/scripts" "$INFRA/docs" "$INFRA/argo" "$INFRA/README.md" "${AGAINST[@]}"
else
  echo
  echo "-- tpg-aks-infra not found next to this repository; set FLEET_SIBLING to scan it"
fi

echo
echo "== zero defaults of jq and yq alternatives (a true or non-zero fallback)"
ZD="${HERE}/check_zero_defaults.py"
python3 "$ZD" --expect 2 "${HERE}/fixtures/zero-defaults.sh"
if python3 "$ZD" "${scan[@]}" "$ROOT/tests"; then echo "tpg-fleet: none"; else exit 1; fi
if [[ -d "$INFRA" ]]; then
  if python3 "$ZD" "$INFRA/scripts" "$INFRA/docs" "$INFRA/terraform" "$INFRA/tests" "$INFRA/argo" "$INFRA/inventory" "$INFRA/README.md" "$INFRA/Makefile"; then
    echo "tpg-aks-infra: none"
  else exit 1; fi
fi
echo
echo "cli-flags: all checks passed"
