#!/usr/bin/env bash
# discover.sh WORKFLOW_NAME CLUSTERS [FLEET_JSON]
# Build the run inventory from the registered clusters (Secret argo/kubeconfig-<cluster>,
# wave from its tpg.fleet/wave label) and clusters/fleet.yaml in tpg-fleet.
# CLUSTERS is "all" (registered clusters that have an entry in fleet.yaml) or a
# comma-separated list. FLEET_JSON, when set, replaces fleet.yaml (tpg-day0 dry runs).
# Instance selection (environment), for the workflows that act on chosen instances:
#   P_FILTER       none (default): every declared instance of the selected clusters
#                  off:   the same, also with clusterMap (tpg-day0)
#                  check: the same, but every clusterMap instance must be declared
#                         (tpg-upgrade: the operator upgrade checks every instance)
#                  pairs: only the selected instances, and each one must be declared
#                         on each selected cluster (tpg-scale-instance,
#                         tpg-delete-instance, tpg-patch, and any run with clusterMap)
#                  any:   only the selected instances, each declared on at least one
#                         selected cluster (tpg-backup, tpg-backup-retention)
#   P_CLUSTER_MAP  clusterMap: the instances of each cluster (always checked as pairs)
#   P_INSTANCES    otherwise: comma-separated instances, or all / empty for every one
# A selected instance that is not declared fails the run here, before anything
# changes, with UNKNOWN_INSTANCE and the instances that are declared.
# Outputs:
#   /tmp/inventory.json       [{name, wave, maxReadReplicas, operatorVersion, instances:[{name,
#                             postgresVersion, highAvailability, readReplicas, scheduledBackups,
#                             backupMode (fleet|none|operator), ferret, ferretReadOnlyReplicas,
#                             retentionDays, enableSSL, egressToFqdns, networkPolicy}]}]
#   /tmp/instance-items.json  [{cluster, instance, scheduled, retentionDays}]
WF="$1"; SELECTED="$2"; FLEET_JSON="${3:-}"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh

REPO="$WORK/repo"
git_clone "$REPO"
if [[ -n "$FLEET_JSON" && "$FLEET_JSON" != "{}" ]]; then
  printf '%s' "$FLEET_JSON" | yq -P '.' > "$REPO/$FLEET_REL"
  plan_restore "$REPO/$FLEET_REL" "$(setting backupCaBundle 2>/dev/null || true)" \
    || exit 1   # the plan names the tpg-settings CA bundle and backupCaBundle is empty
  # tpg-create-instance: the patch files the plan stored (Round 14), so the
  # instance values below (backup scheduler, FerretDB) include them
  patch_materialize "$REPO" >/dev/null || true
  log "using the clusters/fleet.yaml planned by this run (written to Git after the pre-check)"
fi
registered="$(registered_clusters)"

if [[ "$SELECTED" == "all" ]]; then
  wanted="$(fleet_clusters "$REPO")"
else
  wanted="$(tr ',' '\n' <<<"$SELECTED" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true)"
fi

FILTER="${P_FILTER:-none}"
# off (tpg-day0, tpg-upgrade): every declared instance, even with clusterMap -
# the operator upgrade checks all instances of a cluster, and Day 0 syncs them
CHECK_ONLY=false
if [[ "$FILTER" == "off" ]]; then FILTER=none
elif [[ "$FILTER" == "check" ]]; then FILTER=none; cmap_set && CHECK_ONLY=true
elif cmap_set; then FILTER=pairs
fi
if [[ "$FILTER" != "none" && -z "$(cmap_set && echo map)" ]] && [[ -z "${P_INSTANCES:-}" || "${P_INSTANCES}" == "all" ]]; then
  FILTER=none
fi
unknown=0
declare -A seen_anywhere=()
# What the plan of this run (tpg-day0, tpg-create-instance: fleet-day0.sh) already
# blocked: a blocked cluster or instance is left out here without failing the run,
# and its BLOCKED record stays what the report and the gate show.
records="$(run_records 2>/dev/null || echo '{}')"
plan_block() {  # plan_block KEY -> "REASON|DETAIL" of a BLOCKED record, or nothing
  jq -r --arg k "$1" '.[$k] // empty | fromjson? | select(.status == "BLOCKED") | "\(.reason)|\(.detail // "")"' <<<"$records"
}

inv="[]"
for c in $wanted; do
  if ! grep -qx "$c" <<<"$registered"; then
    record "result.${c}" FAILED NOT_REGISTERED "Secret argo/kubeconfig-${c} is missing; registered clusters: $(paste -sd, <<<"$registered")"
    continue
  fi
  cblock="$(plan_block "block.${c}")"
  if ! fleet_has_cluster "$REPO" "$c"; then
    if [[ -n "$cblock" ]]; then
      # blocked by the plan before it got an entry: the pre-check row carries the reason
      record_entry "precheck.${c}" BLOCKED "${cblock%%|*}" "${cblock#*|}"
      log "${c}: blocked in the plan (${cblock%%|*}), left out"
      continue
    fi
    record "result.${c}" FAILED NOT_IN_FLEET "no clusters.${c} entry in ${FLEET_REL} (run tpg-day0 for this cluster)"
    continue
  fi
  declared="$(fleet_instances "$REPO" "$c")"
  if [[ "$FILTER" == "none" ]]; then
    chosen="$declared"
    if [[ "$CHECK_ONLY" == "true" ]]; then
      for i in $(cmap_instances "$c"); do
        grep -qx "$i" <<<"$declared" && continue
        record "result.${c}.${i}" FAILED UNKNOWN_INSTANCE \
          "no clusters.${c}.instances.${i} in ${FLEET_REL}; declared on ${c}: $(paste -sd, <<<"$declared")"
        unknown=1
      done
    fi
  else
    chosen=""
    for i in $(selected_instances "$REPO" "$c"); do
      if grep -qx "$i" <<<"$declared"; then
        chosen="$(printf '%s\n%s' "$chosen" "$i")"; seen_anywhere[$i]=1
      elif [[ -n "$cblock" || -n "$(plan_block "result.${c}.${i}")" ]]; then
        log "${c}/${i}: blocked in the plan, left out"
      elif [[ "$FILTER" == "pairs" ]]; then
        record "result.${c}.${i}" FAILED UNKNOWN_INSTANCE \
          "no clusters.${c}.instances.${i} in ${FLEET_REL}; declared on ${c}: $(paste -sd, <<<"$declared")"
        unknown=1
      fi
    done
  fi
  instances="[]"
  for i in $chosen; do
    ha="$(fleet_instance_value "$REPO" "$c" "$i" '.instance.highAvailability.enabled' true)"
    rr="$(fleet_instance_value "$REPO" "$c" "$i" '.instance.highAvailability.readReplicas' 0)"
    [[ "$ha" == "true" ]] || rr=0
    # Backup scheduler (D70): the CronWorkflows back up an instance unless
    # backup.scheduled is false (backupSchedule none, or operator with
    # PostgresBackupSchedule objects); a tpg-patch values file may change it
    sched=true
    [[ "$(instance_effective "$REPO" "$c" "$i" '.backup.scheduled' true)" == "false" ]] && sched=false
    bmode=fleet
    if [[ "$(instance_effective "$REPO" "$c" "$i" '.backup.operatorSchedules.full' '')" != "" ]]; then bmode=operator
    elif [[ "$sched" == "false" ]]; then bmode=none; fi
    # FerretDB (D71)
    fer=false; [[ "$(instance_effective "$REPO" "$c" "$i" '.ferret.enabled' false)" == "true" ]] && fer=true
    fro="$(instance_effective "$REPO" "$c" "$i" '.ferret.readOnlyReplicas' 0)"; [[ "$fro" =~ ^[0-9]+$ ]] || fro=0
    # Backup age limit for tpg-backup-retention: instance override, then cluster override,
    # then clusters/_template/cluster.yaml, then 35 days
    rd="$(C="$c" I="$i" yq -r '.clusters[strenv(C)].instances[strenv(I)].backup.retentionDays | select(. != null)' "$REPO/$FLEET_REL")"
    [[ -n "$rd" && "$rd" != "null" ]] || rd="$(fleet_cluster_value "$REPO" "$c" '.backup.retentionDays' 35)"
    [[ "$rd" =~ ^[0-9]+$ ]] || rd=35
    # enableSSL of the backup location: instance, then cluster, then the templates
    ssl="$(C="$c" I="$i" yq -r '.clusters[strenv(C)].instances[strenv(I)].backup.enableSSL | select(. != null)' "$REPO/$FLEET_REL")"
    [[ -n "$ssl" && "$ssl" != "null" ]] || ssl="$(fleet_cluster_value "$REPO" "$c" '.backup.enableSSL' false)"
    [[ "$ssl" == "true" ]] || ssl=false
    fqdns="$(C="$c" I="$i" yq -o=json -I=0 '.clusters[strenv(C)].instances[strenv(I)].network.egressToFqdns // []' "$REPO/$FLEET_REL")"
    npol="$(C="$c" I="$i" yq -r '.clusters[strenv(C)].instances[strenv(I)].network.policy // "none"' "$REPO/$FLEET_REL")"
    obj="$(jq -cn --arg n "$i" --arg v "$(fleet_instance_value "$REPO" "$c" "$i" '.instance.postgresVersion' '')" \
      --argjson ha "$ha" --argjson rr "$rr" --argjson s "$sched" --argjson rd "$rd" --argjson ssl "$ssl" \
      --argjson fq "${fqdns:-[]}" --arg np "$npol" --arg bm "$bmode" --argjson fe "$fer" --argjson fro "$fro" \
      '{name:$n, postgresVersion:$v, highAvailability:$ha, readReplicas:$rr, scheduledBackups:$s, backupMode:$bm, retentionDays:$rd,
        enableSSL:$ssl, egressToFqdns:$fq, networkPolicy:$np, ferret:$fe, ferretReadOnlyReplicas:$fro}')"
    instances="$(jq -c --argjson o "$obj" '. + [$o]' <<<"$instances")"
  done
  obj="$(jq -cn --arg n "$c" \
    --argjson w "$(registered_wave "$c")" \
    --argjson m "$(fleet_cluster_value "$REPO" "$c" '.cluster.maxReadReplicas' 3)" \
    --arg v "$(C="$c" yq -r '.clusters[strenv(C)].operator.version // ""' "$REPO/$FLEET_REL")" \
    --argjson inst "$instances" \
    '{name:$n, wave:$w, maxReadReplicas:$m, operatorVersion:$v, instances:$inst}')"
  inv="$(jq -c --argjson o "$obj" '. + [$o]' <<<"$inv")"
done

if [[ "$FILTER" == "any" ]]; then
  for i in $(split_list "${P_INSTANCES:-}"); do
    [[ -n "${seen_anywhere[$i]:-}" ]] && continue
    record "result.${i}" FAILED UNKNOWN_INSTANCE "${i} is not declared on any selected cluster in ${FLEET_REL}"
    unknown=1
  done
fi

printf '%s' "$inv" > /tmp/inventory.json
jq -c '[.[] as $c | $c.instances[] | {cluster: $c.name, instance: .name, scheduled: (.scheduledBackups | tostring),
  retentionDays: (.retentionDays | tostring)}]' <<<"$inv" > /tmp/instance-items.json
kubectl -n "$ARGO_NS" patch configmap "$(run_cm)" --type merge \
  -p "$(jq -cn --arg v "$inv" '{data: {inventory: $v}}')" >/dev/null
log "inventory: $(jq -r 'map(.name + "(" + (.instances | length | tostring) + ")") | join(", ")' <<<"$inv")"
if [[ "$unknown" -ne 0 ]]; then
  log "selected instances that are not declared in ${FLEET_REL}: nothing was changed"
  exit 1
fi
