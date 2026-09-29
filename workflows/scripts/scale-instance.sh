#!/usr/bin/env bash
# scale-instance.sh plan WORKFLOW_NAME
# scale-instance.sh apply WORKFLOW_NAME CLUSTER INSTANCE TIMEOUT_SECONDS REPLICAS PREVIOUS
# scale-instance.sh restore WORKFLOW_NAME   (exit handler of a run that did not succeed)
# tpg-scale-instance: set the read replica count of the selected instances.
# Targets: clusterMap (replicas and enableHAIfNeeded per instance, the inputs as
# defaults), or every instance of the instances list on every cluster of the
# clusters list (the discover step has checked that each one is declared).
#
# plan (one step for the run):
#   1 guards   0 <= replicas <= maxReadReplicas, instance Running, no upgrade or
#              restore in progress, the clusterMap postgresVersion guard
#   2 HA       replicas > 0 needs highAvailability.enabled: turned on when
#              enableHAIfNeeded=true, otherwise the instance fails. replicas=0 is a
#              single node (design decision D72): highAvailability enabled false and
#              readReplicas 0, as the 4.5 documentation scales an HA instance down;
#              refused (FERRET_READONLY_NEEDS_HA) while FerretDB runs read-only
#              proxies, which connect to the standby.
#   3 cap      maxReadReplicas (clusterMap cluster key, else the input; Round 14,
#              D80) is written to clusters.<cluster>.cluster.maxReadReplicas and is
#              the bound of step 1; a run may set only the cap (no instances, no
#              sync). The validate step has refused a cap below any instance
#              (MAX_BELOW_CURRENT).
#   4 Git      clusters.<cluster>.instances.<instance>.instance.highAvailability for
#              every target, and the caps, in one commit (PUSH_MODE direct | pr)
#   Outputs /tmp/items.json: the instances to sync ([{cluster, instance, replicas, previous}]),
#   and precheck.<cluster> PASSED for every cluster with an instance to sync, which
#   plan-batches turns into the rollout (rolloutMode canary | batches | all, maxParallel).
# apply (one step per instance): sync the instance Application at the pushed
#   commit, check spec.highAvailability, then the pods until Running. The chart
#   renders no highAvailability block for a single node (D69), so the sync removes
#   the fields only where Argo CD is their only field manager; when another
#   manager (the operator) co-owns spec.highAvailability.enabled and it stays
#   true, the step applies enabled false and readReplicas 0 to the live object
#   with a server-side apply as field manager tpg-scale and records warning
#   HA_FIELD_CO_OWNED naming the managers (D72).
# P_DRY_RUN=true records the plan per instance and changes nothing.
MODE="$1"; WF="$2"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh
export PUSH_MODE="${P_PUSH_MODE:-direct}" PR_TIMEOUT_SECONDS="${P_PR_TIMEOUT:-3600}"

if [[ "$MODE" == "plan" ]]; then
  result_guard result.git
  echo '[]' > /tmp/items.json
  REPO="$WORK/repo"
  git_clone "$REPO"
  inv="$(run_data inventory)"; [[ -n "$inv" ]] || inv="[]"
  items="[]"; summary=(); cap_done=()
  declare -A CAP=() CAP_WRITE=()
  for C in $(jq -r '.[].name' <<<"$inv"); do
    cap="$(cmap_cval "$C" maxReadReplicas "${P_MAX_READ_REPLICAS:-}")"
    [[ -n "$cap" ]] || continue
    old="$(fleet_cluster_value "$REPO" "$C" '.cluster.maxReadReplicas' 3)"
    CAP[$C]="$cap"
    if [[ "$old" == "$cap" ]]; then
      record_entry "result.${C}.maxReadReplicas" SUCCEEDED ALREADY_AT_TARGET "maxReadReplicas=${cap}"
      continue
    fi
    if [[ "${P_DRY_RUN:-false}" == "true" ]]; then
      record_entry "result.${C}.maxReadReplicas" SUCCEEDED DRY_RUN "would set maxReadReplicas ${old} -> ${cap}"
      continue
    fi
    CAP_WRITE[$C]="$old"
  done
  # Instances: the clusterMap entries (discover kept only those), or the
  # instances input; a run with neither only sets maxReadReplicas
  pairs=""
  if cmap_set || [[ -n "${P_INSTANCES:-}" ]]; then
    pairs="$(jq -r '.[] | .name as $c | .instances[] | "\($c) \(.name)"' <<<"$inv")"
  fi
  while read -r C I; do
    [[ -n "$C" ]] || continue
    key="result.${C}.${I}"
    ifail() { record_entry "$key" FAILED "$1" "${2:-}"; }
    N="$(cmap_ival "$C" "$I" replicas "${P_REPLICAS:-}")"
    [[ "$N" =~ ^[0-9]+$ ]] || { ifail OUT_OF_BOUNDS "replicas must be a non-negative integer (got '${N}')"; continue; }
    max="${CAP[$C]:-$(fleet_cluster_value "$REPO" "$C" '.cluster.maxReadReplicas' 3)}"
    (( N <= max )) || { ifail OUT_OF_BOUNDS "replicas ${N} > maxReadReplicas ${max}"; continue; }
    ha="$(fleet_instance_value "$REPO" "$C" "$I" '.instance.highAvailability.enabled' true)"
    cur="$(fleet_instance_value "$REPO" "$C" "$I" '.instance.highAvailability.readReplicas' 0)"
    [[ "$ha" == "true" ]] || cur=0
    HA="$ha"
    if (( N > 0 )) && [[ "$ha" != "true" ]]; then
      [[ "$(cmap_ival "$C" "$I" enableHAIfNeeded "${P_ENABLE_HA:-true}")" == "true" ]] \
        || { ifail HA_DISABLED "replicas ${N} needs highAvailability; set enableHAIfNeeded=true"; continue; }
      HA=true
    fi
    if (( N == 0 )); then
      # a single node (D72); read-only FerretDB proxies need the standby (D71)
      HA=false
      if [[ "$(instance_effective "$REPO" "$C" "$I" '.ferret.enabled' false)" == "true" ]] \
         && [[ "$(instance_effective "$REPO" "$C" "$I" '.ferret.readOnlyReplicas' 0)" != "0" ]]; then
        ifail FERRET_READONLY_NEEDS_HA "replicas 0 makes ${I} a single node, but FerretDB runs read-only proxies that connect to the standby: set ferret.readOnlyReplicas to 0 with a tpg-patch values file first"
        continue
      fi
    fi
    use_cluster "$C" || { ifail NOT_REGISTERED; continue; }
    if ! g="$(cmap_guard "$C" "$I")"; then record_entry "$key" SKIPPED_VERSION_MISMATCH "" "$g"; continue; fi
    [[ "$(pg_state "$I")" == "Running" ]] || { ifail NOT_RUNNING "currentState=$(pg_state "$I")"; continue; }
    busy=""
    for kind in postgresversionupgrade postgresrestore; do
      n="$(tk -n "pg-${I}" get "$kind" -o json 2>/dev/null \
        | jq -r '[.items[] | select((.status.phase // "") | test("^(Succeeded|Failed|PreCheckFailed)$") | not)] | length')"
      [[ "${n:-0}" -eq 0 ]] || busy="${busy}${kind} "
    done
    [[ -z "$busy" ]] || { ifail OPERATION_IN_PROGRESS "$busy"; continue; }
    if [[ "$cur" == "$N" && "$HA" == "$ha" ]]; then
      record_entry "$key" SUCCEEDED ALREADY_AT_TARGET "readReplicas=${N}"
      continue
    fi
    if [[ "$HA" == "true" ]]; then
      # 4.5 release notes: more database pods than zones can put the leader and the
      # synchronous standby in one zone, where Patroni does not fail over (D66)
      read -r _ zones <<<"$(pgdata_pool_shape)"
      if (( N + 1 > zones )); then
        record_entry "warning.${C}.${I}.zones" WARNING HA_NODES_EXCEED_ZONES \
          "${I}: $((N + 1)) database pods (1 + readReplicas) in ${zones} zone(s); if the zone of the leader and the synchronous standby fails, Patroni does not fail over automatically (fail over by hand, Runbook)"
      fi
    fi
    if [[ "${P_DRY_RUN:-false}" == "true" ]]; then
      record_entry "$key" SUCCEEDED DRY_RUN "would set readReplicas ${cur} -> ${N}, highAvailability ${ha} -> ${HA}"
      continue
    fi
    C="$C" I="$I" N="$N" HA="$HA" yq -i '
      .clusters[strenv(C)].instances[strenv(I)].instance.highAvailability.enabled = (strenv(HA) == "true") |
      .clusters[strenv(C)].instances[strenv(I)].instance.highAvailability.readReplicas = (strenv(N) | tonumber)' "$REPO/$FLEET_REL"
    items="$(jq -c --arg c "$C" --arg i "$I" --arg n "$N" --arg p "$cur" --arg h "$ha" \
      '. + [{cluster: $c, instance: $i, replicas: $n, previous: $p, previousEnabled: ($h == "true")}]' <<<"$items")"
    summary+=("${C}/${I} ${cur}->${N}")
  done <<<"$pairs"

  # The caps, after the instance counts of this run are in fleet.yaml: an instance
  # left above the new cap (its scale was refused or skipped above) keeps the old cap
  for C in "${!CAP_WRITE[@]}"; do
    cap="${CAP[$C]}"; old="${CAP_WRITE[$C]}"; below=()
    for I in $(C="$C" yq -r '.clusters[strenv(C)].instances // {} | keys | .[]' "$REPO/$FLEET_REL"); do
      cur="$(fleet_instance_value "$REPO" "$C" "$I" '.instance.highAvailability.readReplicas' 0)"
      [[ "$(fleet_instance_value "$REPO" "$C" "$I" '.instance.highAvailability.enabled' true)" == "true" ]] || cur=0
      [[ "$cur" =~ ^[0-9]+$ ]] && (( cur > cap )) && below+=("${I}=${cur}")
    done
    if [[ "${#below[@]}" -gt 0 ]]; then
      record_entry "result.${C}.maxReadReplicas" FAILED MAX_BELOW_CURRENT \
        "maxReadReplicas ${cap} is below the read replicas of ${below[*]}; the cap stays ${old}"
      continue
    fi
    C="$C" N="$cap" yq -i '.clusters[strenv(C)].cluster.maxReadReplicas = (strenv(N) | tonumber)' "$REPO/$FLEET_REL"
    cap_done+=("${C}|maxReadReplicas ${old} -> ${cap} (${FLEET_REL} only; nothing on the cluster changes)")
    summary+=("${C} maxReadReplicas ${old}->${cap}")
  done

  if [[ "${#summary[@]}" -eq 0 ]]; then
    record result.git SUCCEEDED NO_CHANGE "nothing to change in ${FLEET_REL}"
    exit 0
  fi
  git_commit_push "$REPO" "scale ${summary[*]} (${WF})" "$FLEET_REL" \
    || { record result.git FAILED GIT_PUSH_FAILED "pushMode=${PUSH_MODE}"; exit 1; }
  record_entry revision SET "" "${PUSHED_REVISION:-}"
  record_entry plan.items SET "" "$items"
  for e in "${cap_done[@]}"; do record_entry "result.${e%%|*}.maxReadReplicas" SUCCEEDED "" "${e#*|}"; done
  printf '%s' "$items" > /tmp/items.json
  # the rollout plan (plan-batches) takes the clusters that have an instance to sync
  for C in $(jq -r '[.[].cluster] | unique | .[]' <<<"$items"); do
    record_entry "precheck.${C}" PASSED "" "instances: $(jq -r --arg c "$C" '[.[] | select(.cluster == $c) | .instance] | join(",")' <<<"$items")"
  done
  record result.git SUCCEEDED "" "pushMode=${PUSH_MODE} ${PUSHED_REVISION:0:12} $(cat /tmp/pull-request 2>/dev/null || true)"
  exit 0
fi

# ---- restore (exit handler, when the run did not succeed): the plan committed
# every target's count before the rollout; a failed batch stops the later ones, so
# their instances never synced while clusters/fleet.yaml already declares the new
# count. Those entries (no result recorded) get their previous highAvailability
# back in one commit, so the next sync of any workflow does not scale them
# unasked. Instances that ran keep what they got (their result names it); the caps
# stay (nothing on a cluster reads them).
if [[ "$MODE" == "restore" ]]; then
  items="$(run_data plan.items | jq -r '.detail // empty')"
  [[ -n "$items" && "$items" != "[]" ]] || exit 0
  unreached="$(jq -c '[.[] | select(.previousEnabled != null)]' <<<"$items")"
  todo="[]"
  while IFS= read -r it; do
    [[ -n "$it" ]] || continue
    C="$(jq -r .cluster <<<"$it")"; I="$(jq -r .instance <<<"$it")"
    [[ -z "$(run_data "result.${C}.${I}")" ]] && todo="$(jq -c --argjson x "$it" '. + [$x]' <<<"$todo")"
  done < <(jq -c '.[]' <<<"$unreached")
  [[ "$(jq length <<<"$todo")" -gt 0 ]] || exit 0
  REPO="$WORK/repo"
  git_clone "$REPO"
  names=()
  while IFS= read -r it; do
    C="$(jq -r .cluster <<<"$it")"; I="$(jq -r .instance <<<"$it")"
    N="$(jq -r .previous <<<"$it")"; HA="$(jq -r .previousEnabled <<<"$it")"
    C="$C" I="$I" N="$N" HA="$HA" yq -i '
      .clusters[strenv(C)].instances[strenv(I)].instance.highAvailability.enabled = (strenv(HA) == "true") |
      .clusters[strenv(C)].instances[strenv(I)].instance.highAvailability.readReplicas = (strenv(N) | tonumber)' "$REPO/$FLEET_REL"
    names+=("${C}/${I}")
  done < <(jq -c '.[]' <<<"$todo")
  if git_commit_push "$REPO" "scale: restore the targets the rollout did not reach: ${names[*]} (${WF})" "$FLEET_REL"; then
    note="${FLEET_REL} restored to the previous count (${PUSHED_REVISION:0:12})"
  else
    note="${FLEET_REL} still declares the new count: the restore commit could not be pushed; set it back by hand"
  fi
  while IFS= read -r it; do
    C="$(jq -r .cluster <<<"$it")"; I="$(jq -r .instance <<<"$it")"
    record_entry "result.${C}.${I}" NOT_RUN "" "an earlier batch failed; ${note}"
  done < <(jq -c '.[]' <<<"$todo")
  exit 0
fi

# ---- apply: one instance
C="$3"; I="$4"; TIMEOUT="$5"; N="$6"; prev="${7:-}"
key="result.${C}.${I}"
fail() { record "$key" FAILED "$1" "${2:-}"; exit 1; }
result_guard "$key"
use_cluster "$C" || fail NOT_REGISTERED
ns="pg-${I}"
app="tpg-${C}-${I}"
rev="$(run_data revision | jq -r '.detail // empty')"
[[ -n "$rev" ]] || rev="$(fleet_head)"
_PG_WATCHED="$I"
rc=0; app_sync_wait "$app" "$TIMEOUT" ${rev:+--revision "$rev"} --pods "$ns" "postgres-instance=${I}" --ready-fn _pg_ready || rc=$?
[[ "$rc" -eq 0 ]] || fail "$SYNC_FAIL_REASON" "$SYNC_FAIL_DETAIL"

if [[ "$N" == "0" ]]; then
  # Single node (D72): the chart renders no highAvailability block, and the
  # sync removed the fields only if Argo CD was their only field manager
  spec_en="$(tk -n "$ns" get postgres "$I" -o jsonpath='{.spec.highAvailability.enabled}')"
  if [[ "$spec_en" == "true" ]]; then
    owners="$(tk -n "$ns" get postgres "$I" -o json | jq -r '[.metadata.managedFields[]?
      | select(.fieldsV1["f:spec"]["f:highAvailability"]["f:enabled"] != null) | .manager] | unique | join(",")')"
    log "spec.highAvailability.enabled is still true after the sync (field managers: ${owners:-unknown}); applying the single-node values as field manager tpg-scale"
    printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nmetadata:\n  name: %s\n  namespace: %s\nspec:\n  highAvailability:\n    enabled: false\n    readReplicas: 0\n' "$I" "$ns" \
      | tk apply --server-side --field-manager=tpg-scale --force-conflicts -f - >/dev/null \
      || fail SPEC_NOT_APPLIED "the single-node values could not be applied (field managers of spec.highAvailability.enabled: ${owners:-unknown})"
    record_entry "warning.${C}.${I}.ha" WARNING HA_FIELD_CO_OWNED \
      "${I}: spec.highAvailability.enabled stayed true after the sync because ${owners:-another field manager} co-owns it; enabled false and readReplicas 0 were applied as field manager tpg-scale"
    spec_en="$(tk -n "$ns" get postgres "$I" -o jsonpath='{.spec.highAvailability.enabled}')"
  fi
  [[ "$spec_en" != "true" ]] || fail SPEC_NOT_APPLIED "spec.highAvailability.enabled is still true"
fi
spec_rr="$(tk -n "$ns" get postgres "$I" -o jsonpath='{.spec.highAvailability.readReplicas}')"
[[ "${spec_rr:-0}" == "$N" ]] || fail SPEC_NOT_APPLIED "spec.highAvailability.readReplicas=${spec_rr}, expected ${N}"
# The operator adds or removes replica pods after the spec change
log "giving the operator 30s to act on the spec change"
sleep 30
pg_wait_ready "$I" "$TIMEOUT" || fail "${POD_WATCH_REASON:-REPLICAS_NOT_READY}" "after the scale: ${POD_WATCH_DETAIL}"
ready="$(tk -n "$ns" get statefulset "$I" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}')"
if [[ "$N" == "0" ]]; then
  record "$key" SUCCEEDED "" "single node (highAvailability off), statefulset ready ${ready}" "$prev"
else
  record "$key" SUCCEEDED "" "readReplicas=${N}, statefulset ready ${ready}" "$prev"
fi
