#!/usr/bin/env bash
# fleet-commit.sh WORKFLOW_NAME PLANNED_FLEET_JSON BASE_FLEET_JSON
# tpg-day0 and tpg-create-instance, after the pre-check (design decision D61):
# write the planned clusters/fleet.yaml entries of every cluster whose
# pre-check is PASSED or MANAGED, and nothing for a BLOCKED cluster. The plan
# (fleet-day0.sh) started from BASE_FLEET_JSON; a cluster whose entry in Git
# changed since then is not overwritten (FLEET_CHANGED_DURING_RUN).
# The plans carry the tpg-settings CA bundle as CA_PLACEHOLDER (lib.sh plan_json);
# HEAD is compared in the same form and the bundle is restored when written.
# dryRun=true: log the change and push nothing. Otherwise commit with
# PUSH_MODE (direct | pr). Records result.git.
WF="$1"; PLANNED="$2"; BASE="$3"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh
export PUSH_MODE="${P_PUSH_MODE:-direct}" PR_TIMEOUT_SECONDS="${P_PR_TIMEOUT:-3600}"
result_guard result.git

REPO="$WORK/repo"
F="$REPO/$FLEET_REL"
git_clone "$REPO"
cp "$F" "$WORK/fleet.before.yaml"
printf '%s' "$PLANNED" > "$WORK/planned.json"
printf '%s' "$BASE" > "$WORK/base.json"
CA_BUNDLE="$(setting backupCaBundle 2>/dev/null || true)"
plan_json "$F" "$CA_BUNDLE" > "$WORK/head.json"

written=(); skipped=(); changed=()
for c in $(jq -r '(.clusters // {}) | keys[]' "$WORK/planned.json"); do
  if jq -e --arg c "$c" '(.clusters[$c] // null) == ($b[0].clusters[$c] // null)' \
       --slurpfile b "$WORK/base.json" "$WORK/planned.json" >/dev/null; then
    continue   # the plan changes nothing for this cluster
  fi
  s="$(record_status "precheck.${c}")"
  if [[ "$s" != "PASSED" && "$s" != "MANAGED" ]]; then
    skipped+=("${c} (pre-check ${s:-not run})")
    continue
  fi
  if ! jq -e --arg c "$c" '(.clusters[$c] // null) == ($h[0].clusters[$c] // null)' \
       --slurpfile h "$WORK/head.json" "$WORK/base.json" >/dev/null; then
    changed+=("$c")
    continue
  fi
  C="$c" P="$WORK/planned.json" yq -i '.clusters[strenv(C)] = (load(strenv(P)) | .clusters[strenv(C)])' "$F"
  written+=("$c")
done
if ! plan_restore "$F" "$CA_BUNDLE"; then
  record result.git FAILED CA_BUNDLE_MISSING "the plan uses the CA bundle of ConfigMap argo/tpg-settings and backupCaBundle is empty; nothing was written"
  exit 1
fi
# The plan travels as JSON: write clusters/fleet.yaml back in block YAML (the
# whole file, so entries copied as JSON by an earlier version are converted too;
# nothing is reformatted when no cluster is written)
[[ "${#written[@]}" -eq 0 ]] || fleet_yaml_style "$F"
# tpg-create-instance: the patch files the written entries reference (Round 14;
# stored under their name plus a UID by fleet-day0.sh, contents from patchFiles)
if ! patch_materialize "$REPO" > "$WORK/stored-files.txt"; then
  # an entry would name a patch file the commit does not carry: the chart could not render it
  record result.git FAILED UNEXPECTED_ERROR "a patch file the plan stored has no contents in patchFiles; nothing was committed"
  exit 1
fi
mapfile -t stored < "$WORK/stored-files.txt"

plan_note="$(run_data plan.git | jq -r '.detail // ""' 2>/dev/null || true)"
note="${plan_note}$( [[ "${#skipped[@]}" -eq 0 ]] || printf '; not written (pre-check): %s' "$(IFS=,; echo "${skipped[*]}")")"
if [[ "${#changed[@]}" -gt 0 ]]; then
  record result.git FAILED FLEET_CHANGED_DURING_RUN \
    "clusters/fleet.yaml changed in Git for $(IFS=,; echo "${changed[*]}") while this run was planning; run the workflow again${note:+; ${note}}"
  exit 1
fi
changes="$(diff -u "$WORK/fleet.before.yaml" "$F" | tail -n +3 || true)"
[[ "${#stored[@]}" -eq 0 ]] || changes="${changes}"$'\n'"$(printf '+ new patch file %s\n' "${stored[@]}")"
if [[ -z "$changes" ]]; then
  record result.git SUCCEEDED NO_CHANGE "clusters/fleet.yaml already declares these inputs${note:+; ${note}}"
  exit 0
fi
log "clusters/fleet.yaml changes:"
printf '%s\n' "$changes" >&2
if [[ "${P_DRY_RUN:-false}" == "true" ]]; then
  record result.git SUCCEEDED DRY_RUN "$(grep -c '^[+-]' <<<"$changes") changed lines for $(IFS=,; echo "${written[*]}"), not pushed${note:+; ${note}}"
  exit 0
fi
git_commit_push "$REPO" "${FLEET_COMMIT_PREFIX:-day0}: $(IFS=' '; echo "${written[*]}") (${WF})" "$FLEET_REL" ${stored[@]+"${stored[@]}"} \
  || { record result.git FAILED GIT_PUSH_FAILED "pushMode=${PUSH_MODE}"; exit 1; }
appset_refresh tpg-operator
appset_refresh tpg-instances
record_entry revision SET "" "${PUSHED_REVISION:-}"
record result.git SUCCEEDED "" "pushMode=${PUSH_MODE} ${PUSHED_REVISION:0:12} $(cat /tmp/pull-request 2>/dev/null || true)${note:+; ${note}}"
