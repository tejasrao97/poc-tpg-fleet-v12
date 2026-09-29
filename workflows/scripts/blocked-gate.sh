#!/usr/bin/env bash
# blocked-gate.sh WORKFLOW_NAME
# tpg-day0, tpg-create-instance and tpg-network-policy: exit 1 when any pre-check (precheck.<cluster>)
# or instance result (result.<cluster>.<instance>) of this run is BLOCKED, so the
# workflow ends Failed even though the clusters that passed were deployed
# (design decision D61). The report lists what was blocked and why.
WF="$1"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh
data="$(run_records)"
blocked="$(jq -r 'to_entries[] | select(.key | startswith("precheck.") or startswith("result."))
  | (.value | fromjson) as $v | select($v.status == "BLOCKED")
  | "\(.key | sub("^(precheck|result)\\."; "")) \($v.reason)"' <<<"$data")"
if [[ -n "$blocked" ]]; then
  log "BLOCKED targets (the workflow fails; the other targets ran):"
  printf '  %s\n' "$blocked" >&2
  exit 1
fi
log "no target was BLOCKED"
