#!/usr/bin/env bash
# patch-cluster.sh WORKFLOW_NAME CLUSTER TIMEOUT_SECONDS
# tpg-patch, one cluster, under the mutex tpg-cluster-<cluster> (Round 14, design
# decisions D78 and D79). patch-plan.sh has checked every cluster and recorded
# plan.<cluster> (the targets whose objects the patch changes).
#   1 A fresh clone of the fleet branch (BASE, its head commit): the checks, the
#     render, the server-side dry run and the diff of patch-plan.sh again (patch-lib.sh),
#     so a change on the fleet branch since the plan is seen. No difference any
#     more: NO_CHANGE, nothing is committed.
#   2 One commit: the stored patch files, clusters/fleet.yaml (current and previous)
#     and, for the operator, patches/operator/clusters/<cluster>.yaml.
#       pushMode=pr      on the branch tpg/patch/<workflow>/<cluster>, with a pull
#                        request into the fleet branch (its body carries the diff)
#       pushMode=direct  on the fleet branch
#   3 The Applications of the targets are synced at that commit, the operator first
#     (source 2 of the multi-source Application, where the fleet repository is), then
#     the instances (with prune), and verified: the operator pods and CRD, the
#     instance pods until Running, FerretDB and the Services.
#   4 pushMode=pr: the workflow waits for a person to merge the pull request
#     (prTimeoutSeconds). Merged: the Applications compare the new fleet branch head
#     with what was synced from the branch, the same objects, so they turn Synced
#     without a second sync (app_expect_synced checks it). Closed or not merged in
#     time: reverted (5), FAILED PR_NOT_MERGED.
#   5 A failed sync or check (or PR_NOT_MERGED) reverts:
#       pushMode=pr      the pull request is closed first, so nobody can merge it
#                        any more; each Application is synced back (at the fleet
#                        branch head of step 1 when it was Synced before this step,
#                        otherwise at the commit it was last synced at) and the
#                        branch deleted (its commit goes with it). A pull request a
#                        person merged before the failure is undone like direct:
#       pushMode=direct  a git revert of the commit (of the merge) is pushed, with
#                        every stored patch file clusters/fleet.yaml still names
#                        (another cluster of the run may use the same file), and
#                        the Applications are synced at it
#     then FAILED with the reason of the failure; later batches do not run.
# Records result.<cluster>.operator and result.<cluster>.<instance>.
WF="$1"; C="$2"; TIMEOUT="$3"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh
# shellcheck source=workflows/scripts/patch-lib.sh
source /scripts/patch-lib.sh
export PUSH_MODE="${P_PUSH_MODE:-direct}"
PR_TIMEOUT="${P_PR_TIMEOUT:-3600}"
result_guard "result.${C}"

plan="$(run_data "plan.${C}" | jq -r '.detail // empty')"
if [[ -z "$plan" ]]; then
  record "result.${C}" SKIPPED_NOT_PLANNED "" "no plan for ${C}: blocked or nothing to patch (see the pre-check)"
  exit 0
fi
use_cluster "$C" || { record "result.${C}" FAILED NOT_REGISTERED; exit 1; }
targets_of() {  # the target names of a plan JSON, operator first
  jq -r '(if .operator then ["operator"] else [] end) + .instances | .[]' <<<"$1"
}
key_of() { printf 'result.%s.%s' "$C" "$1"; }
fail_all() {  # fail_all REASON DETAIL [TARGETS...]: the targets (default: every target of the plan) FAILED
  local r="$1" d="$2" x
  shift 2
  # shellcheck disable=SC2046  # target names are DNS labels
  [[ $# -gt 0 ]] || set -- $(targets_of "$plan")
  for x in "$@"; do record "$(key_of "$x")" FAILED "$r" "$d"; done
}

# ---- 1 check, render and diff again on the fleet branch head
REPO="$WORK/repo"
git_clone "$REPO"
BASE_REV="$(setting fleetRevision)"
BASE="$(git -C "$REPO" rev-parse HEAD)"
inv="$(run_data inventory)"; [[ -n "$inv" ]] || inv="[]"
t="$(patch_targets "$C" "$inv" | jq -c --argjson p "$plan" '
  .operator = (if $p.operator then .operator else null end)
  | .instances = [.instances[] | select(.name as $i | $p.instances | index($i) != null)]')"
C_ERRS=()
patch_render_all "$C" "$t" before
patch_prepare "$C" "$t"
[[ "${#C_ERRS[@]}" -gt 0 ]] || patch_render_all "$C" "$t" after
[[ "${#C_ERRS[@]}" -gt 0 ]] || patch_dry_run "$C"
[[ "${#C_ERRS[@]}" -gt 0 ]] || patch_diff "$C"
if [[ "${#C_ERRS[@]}" -gt 0 ]]; then
  fail_all PATCH_REFUSED "on the fleet branch head ${BASE:0:12}: $(printf '%s; ' "${C_ERRS[@]}")"
  exit 1
fi
changed=("${PATCH_CHANGED[@]+"${PATCH_CHANGED[@]}"}")      # synced
hubonly=("${PATCH_HUB_ONLY[@]+"${PATCH_HUB_ONLY[@]}"}")     # committed only
all=("${changed[@]+"${changed[@]}"}" "${hubonly[@]+"${hubonly[@]}"}")
for x in $(targets_of "$plan"); do
  [[ " ${all[*]} " == *" ${x} "* ]] \
    || record "$(key_of "$x")" SUCCEEDED NO_CHANGE "the patch renders the objects that run (fleet branch ${BASE:0:12}): nothing to sync"
done
[[ "${#all[@]}" -gt 0 ]] || exit 0
# only the targets with a change are committed; only those with a change on the cluster are synced
ops=false; insts=()
for x in "${changed[@]+"${changed[@]}"}"; do if [[ "$x" == operator ]]; then ops=true; else insts+=("$x"); fi; done

# ---- 2 one commit
fleet_yaml_style "$REPO/$FLEET_REL"
git -C "$REPO" add -A -- "$FLEET_REL" "$PATCH_INSTANCE_DIR" "$PATCH_OPERATOR_DIR"
if git -C "$REPO" diff --cached --quiet; then
  for x in "${all[@]}"; do record "$(key_of "$x")" SUCCEEDED NO_CHANGE "nothing to commit"; done
  exit 0
fi
msg="patch ${C}: ${all[*]} (${WF})"
diff_text="$(git -C "$REPO" diff --cached --stat)"
OFF=(); bad=()
if [[ "$PUSH_MODE" == "pr" ]]; then
  # shellcheck disable=SC2016  # the backticks are Markdown, not a command
  body="$(printf 'Opened by Argo Workflow %s for cluster %s.\n\n**The change is synced to the cluster from this branch before the merge.** Merge this pull request to keep it: the Applications then compare the fleet branch with the same objects and stay Synced. Closing it, or not merging it within %ss, makes the workflow sync the cluster back and delete the branch.\n\nTargets: %s\n\n```\n%s\n```\n\nWhat the sync changes on the cluster (kubectl diff --server-side):\n\n```diff\n%s\n```\n' \
    "$WF" "$C" "$PR_TIMEOUT" "${all[*]}" "$diff_text" "$(head -c 50000 "$WORK/diff-${C}.txt")")"
  if ! pr_open "$REPO" "$msg" "$BASE_REV" "tpg/patch/${WF}/${C}" "$body"; then
    fail_all GIT_PUSH_FAILED "could not push the branch or open the pull request" "${all[@]}"; exit 1
  fi
  SHA="$PR_SHA"; OFF=(--off-branch)
else
  if ! git_commit_push "$REPO" "$msg" "$FLEET_REL" "$PATCH_INSTANCE_DIR" "$PATCH_OPERATOR_DIR"; then
    fail_all GIT_PUSH_FAILED "pushMode=direct" "${all[@]}"; exit 1
  fi
  SHA="$PUSHED_REVISION"
fi
record_entry "revision.${C}" SET "" "$SHA"

# ---- 3 sync and verify
# where each target goes back to on a revert (pushMode=pr): the fleet branch head
# when the Application matched it, else the commit it was last synced at
declare -A PREV=() DETAIL=()
back_to() {  # back_to APP [POSITION]
  local r=""
  [[ "$(app_sync_status "$1")" == "Synced" ]] || r="$(app_deployed_revision "$1" "${2:-0}")"
  printf '%s' "${r:-$BASE}"
}
[[ "$ops" != "true" ]] || PREV[operator]="$(back_to "tpg-${C}-operator" 2)"
for i in "${insts[@]+"${insts[@]}"}"; do PREV[$i]="$(back_to "tpg-${C}-${i}")"; done

sync_operator() {  # sync_operator REVISION [--off-branch]
  local rc=0
  appset_refresh tpg-operator
  app_sync_wait "tpg-${C}-operator" "$TIMEOUT" --revisions 2 "$1" --pods "$OPERATOR_NS" "" --ready-fn _operator_ready "${@:2}" || rc=$?
  return "$rc"
}
sync_instance() {  # sync_instance INSTANCE REVISION [--off-branch]: sync, then FerretDB and the Services
  local i="$1" rc=0
  DETAIL[$i]=""
  # --prune: a values patch that turns FerretDB or the operator backup schedules
  # off (D70, D71) removes those objects; the instance and its backup location
  # carry Prune=false and stay
  sync_instance_app "$C" "$i" "$TIMEOUT" "$2" --prune "${@:3}" || rc=$?
  [[ "$rc" -eq 0 ]] || return "$rc"
  ferret_follow "$i" "$TIMEOUT" || { SYNC_FAIL_REASON="$FERRET_REASON"; SYNC_FAIL_DETAIL="$FERRET_DETAIL"; return 1; }
  # a values patch may change the exposure (instance.exposure, D64)
  exposure_follow "$i" 300 || { SYNC_FAIL_REASON=EXPOSURE_NOT_APPLIED; SYNC_FAIL_DETAIL="$EXPOSURE_DETAIL"; return 1; }
  DETAIL[$i]="services: ${EXPOSURE_DETAIL}${FERRET_DETAIL:+; ${FERRET_DETAIL}}"
}

revert_in_git() {
  # revert_in_git COMMIT: push a revert of COMMIT (the parent-1 side of a merge) on
  # the fleet branch; stored patch files that clusters/fleet.yaml still names stay.
  # Sets PUSHED_REVISION; 1 when it cannot be reverted or pushed.
  local c="$1" m=()
  git -C "$REPO" fetch --quiet origin "$BASE_REV" || { log "git fetch of ${BASE_REV} failed"; return 1; }
  git -C "$REPO" checkout --quiet -B "$BASE_REV" "origin/${BASE_REV}" || { log "git checkout of ${BASE_REV} failed"; return 1; }
  [[ "$(git -C "$REPO" rev-list --parents -n 1 "$c" | wc -w)" -le 2 ]] || m=(-m 1)
  if ! git -C "$REPO" revert --no-commit "${m[@]+"${m[@]}"}" "$c" >/dev/null 2>"$WORK/revert.err"; then
    log "git revert of ${c:0:12} failed: $(tail -n 3 "$WORK/revert.err")"
    git -C "$REPO" revert --abort >/dev/null 2>&1 || true
    return 1
  fi
  patch_materialize "$REPO" >/dev/null || { log "the stored patch files could not be restored"; return 1; }
  git -C "$REPO" add -A -- "$FLEET_REL" "$PATCH_INSTANCE_DIR" "$PATCH_OPERATOR_DIR"
  git -C "$REPO" commit --quiet -m "Revert \"${msg}\"" -m "This reverts commit ${c}: ${reason_now}." || return 1
  git_push_head "$REPO"
}

sync_all_at() {  # sync_all_at REVISION [--off-branch]: every changed target; appends to note
  local x rc
  for x in "${changed[@]+"${changed[@]}"}"; do
    rc=0
    if [[ "$x" == operator ]]; then sync_operator "$1" "${@:2}" || rc=$?; else sync_instance "$x" "$1" "${@:2}" || rc=$?; fi
    [[ "$rc" -eq 0 ]] && note="${note}${x} synced at the revert ${1:0:12}; " \
      || note="${note}${x} NOT reverted (${SYNC_FAIL_REASON}: ${SYNC_FAIL_DETAIL}); "
  done
}

revert() {  # revert REASON DETAIL: undo the commit on the cluster and in Git (5)
  local reason="$1" detail="$2" x rc undo=""
  note=""; reason_now="$reason"
  if [[ "$PUSH_MODE" == "pr" ]]; then
    # closed first: a merge can no longer land while the cluster is synced back
    pr_close "$PR_NUMBER" "Closed by Argo Workflow ${WF}: ${reason}. The cluster is synced back and the branch deleted."
    if pr_merged "$PR_NUMBER"; then
      undo="${PR_MERGE_SHA:-}"
      note="pull request #${PR_NUMBER} was merged before the failure (${undo:0:12}); "
    else
      for x in "${changed[@]+"${changed[@]}"}"; do
        rc=0
        # the fleet branch may have moved on since (--off-branch)
        if [[ "$x" == operator ]]; then sync_operator "${PREV[$x]}" --off-branch || rc=$?; else sync_instance "$x" "${PREV[$x]}" --off-branch || rc=$?; fi
        [[ "$rc" -eq 0 ]] && note="${note}${x} back at ${PREV[$x]:0:12}; " \
          || note="${note}${x} NOT reverted (${SYNC_FAIL_REASON}: ${SYNC_FAIL_DETAIL}); "
      done
      note="${note}pull request #${PR_NUMBER} closed, "
    fi
    branch_delete "$REPO" "$PR_BRANCH"
    note="${note}branch ${PR_BRANCH} deleted"
  else
    undo="$SHA"
  fi
  if [[ -n "$undo" ]]; then
    if revert_in_git "$undo"; then
      note="${note}${note:+; }"
      sync_all_at "$PUSHED_REVISION"
      note="${note}revert commit ${PUSHED_REVISION:0:12} on ${BASE_REV}"
    else
      note="${note}${note:+; }the git revert of ${undo:0:12} could not be pushed: revert it by hand and run the workflow again"
    fi
  fi
  fail_all "$reason" "${detail} | reverted: ${note}" "${all[@]}"
  exit 1
}

if [[ "$ops" == "true" ]]; then
  rc=0; sync_operator "$SHA" "${OFF[@]+"${OFF[@]}"}" || rc=$?
  [[ "$rc" -eq 0 ]] || revert "$SYNC_FAIL_REASON" "operator: $SYNC_FAIL_DETAIL"
fi
for i in "${insts[@]+"${insts[@]}"}"; do
  busy="$(busy_operations "$i")"
  [[ -z "$busy" ]] || revert OPERATION_IN_PROGRESS "${i}: ${busy}is running; run tpg-patch again when it has finished"
  rc=0; sync_instance "$i" "$SHA" "${OFF[@]+"${OFF[@]}"}" || rc=$?
  [[ "$rc" -eq 0 ]] || revert "$SYNC_FAIL_REASON" "${i}: $SYNC_FAIL_DETAIL"
done

# ---- 4 the merge (pushMode=pr)
where="${SHA:0:12}"
if [[ "$PUSH_MODE" == "pr" ]]; then
  rc=0; pr_wait "$PR_NUMBER" "$PR_TIMEOUT" || rc=$?
  case "$rc" in
    0) ;;
    1) revert PR_NOT_MERGED "pull request #${PR_NUMBER} was closed without merging" ;;
    *) revert PR_NOT_MERGED "pull request #${PR_NUMBER} was not merged within ${PR_TIMEOUT}s" ;;
  esac
  appset_refresh tpg-operator; appset_refresh tpg-instances
  for x in "${changed[@]+"${changed[@]}"}"; do
    if [[ "$x" == operator ]]; then a="tpg-${C}-operator"; else a="tpg-${C}-${x}"; fi
    app_expect_synced "$a" 120 || bad+=("$x|$SYNC_FAIL_DETAIL")
  done
  where="branch ${SHA:0:12}, merged as ${PR_MERGE_SHA:0:12} (pull request #${PR_NUMBER})"
fi
failed=0
for x in "${all[@]}"; do
  bad_detail=""
  for b in "${bad[@]+"${bad[@]}"}"; do [[ "${b%%|*}" == "$x" ]] && bad_detail="${b#*|}"; done
  if [[ " ${hubonly[*]} " == *" ${x} "* ]]; then
    record "$(key_of "$x")" SUCCEEDED "" "committed at ${where}; nothing to sync: only values the workflows read changed ($(grep -F "${C}/${x}: nothing changes" "$WORK/diff-${C}.txt" | sed 's/.*the workflows read //' | head -n1))"
  elif [[ -n "$bad_detail" ]]; then
    record "$(key_of "$x")" FAILED MERGED_CONTENT_DIFFERS "${bad_detail}; the patch runs on the cluster, but the merge changed it: compare the pull request with the fleet branch"
    failed=1
  elif [[ "$x" == operator ]]; then
    record "$(key_of operator)" SUCCEEDED "" "synced at ${where}; values: $(patch_ref "$REPO/$FLEET_REL" "$C" "" operator || true)"
  else
    record "$(key_of "$x")" SUCCEEDED "" "Running, synced at ${where}; ${DETAIL[$x]:-}; patches: $(C="$C" I="$x" yq -o=json -I=0 '.clusters[strenv(C)].instances[strenv(I)].patches // {} | with_entries(.value |= (.current // ""))' "$REPO/$FLEET_REL")"
  fi
done
exit "$failed"
