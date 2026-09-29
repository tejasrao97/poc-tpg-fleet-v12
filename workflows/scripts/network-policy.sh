#!/usr/bin/env bash
# network-policy.sh plan WORKFLOW_NAME
# network-policy.sh apply WORKFLOW_NAME CLUSTER TIMEOUT_SECONDS
# tpg-network-policy (design decision D65): create, update or remove the network
# policy of Postgres instances. The policies are rendered by the tpg-instance
# chart from clusters/fleet.yaml clusters.<c>.instances.<i>.network, so Argo CD
# owns them like the rest of the instance:
#   NetworkPolicy tpg-ingress        ingress default deny + the flows the instance
#                                    needs + the client rules
#   CiliumNetworkPolicy tpg-egress   egress default deny + the flows the instance
#                                    needs + the egress rules
#
# plan  every selected instance (discover: clusterMap, or clusters x instances):
#   mode apply   network becomes {policy: baseline} plus exactly the rules given
#                (a rule list that is not given is removed)
#   mode update  policy baseline; only the rules given change, the others stay
#   mode remove  the network entry is deleted; the sync prunes both policies
#   Rules come from the clusterMap keys, else the inputs (ingressFromNamespaces,
#   ingressFromPodLabels, ingressFromCidrs, egressToCidrs, egressToFqdns).
#   network.acns follows tpg-settings acnsEnabled (backup egress by FQDN).
#   Each cluster: the new policies are rendered and applied with
#   --dry-run=server in the instance namespace; a cluster that fails is BLOCKED
#   and its entries are not written. Then one commit (PUSH_MODE) unless dryRun.
#   Records precheck.<cluster>, plan.<cluster> (the instances to sync) and result.git.
# apply one cluster: sync every planned instance (with prune for mode remove),
#   wait for the instance to be Running, then check (CONNECTIVITY_CHECK=true):
#     - WAL archiving still reaches the backup storage (pg_switch_wal, then
#       pg_stat_archiver.last_archived_wal changes and failed_count does not grow)
#     - a probe pod in the first ingressFromNamespaces namespace (with the
#       ingressFromPodLabels labels) reaches port 5432, and one in the default
#       namespace does not (unless default is allowed)
#   Records result.<cluster>.<instance>.
set -euo pipefail
CMD="$1"; WF="$2"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh
export PUSH_MODE="${P_PUSH_MODE:-direct}" PR_TIMEOUT_SECONDS="${P_PR_TIMEOUT:-3600}"
NP_MODE="${P_NP_MODE:-apply}"

# ------------------------------------------------------------------ plan
if [[ "$CMD" == "plan" ]]; then
  result_guard result.git
  REPO="$WORK/repo"; F="$REPO/$FLEET_REL"
  git_clone "$REPO"
  cp "$F" "$WORK/fleet.before.yaml"
  inv="$(run_data inventory)"; [[ -n "$inv" ]] || inv="[]"
  ACNS="$(setting acnsEnabled 2>/dev/null || true)"; [[ "$ACNS" == "true" ]] || ACNS=false

  # the rule values of every target: clusterMap keys over the inputs, checked
  # and normalized with the clusterMap rules
  map_flag() { [[ -n "$(tr -d '[:space:]' <<<"${1:-}")" ]] || { printf ''; return; }; printf '%s\n' "$1" | yq -o=json -I=0 '.' 2>/dev/null || printf '%s' "$1"; }
  jq -cn --arg ingressFromNamespaces "${P_INGRESS_FROM_NAMESPACES:-}" \
    --arg ingressFromPodLabels "$(map_flag "${P_INGRESS_FROM_POD_LABELS:-}")" \
    --arg ingressFromCidrs "${P_INGRESS_FROM_CIDRS:-}" --arg egressToCidrs "${P_EGRESS_TO_CIDRS:-}" \
    --arg egressToFqdns "${P_EGRESS_TO_FQDNS:-}" \
    '$ARGS.named | with_entries(select(.value != "")) | with_entries(.value |= (fromjson? // .))' > "$WORK/flags.json"
  cmap_load
  jq -c --slurpfile f "$WORK/flags.json" --slurpfile m "$WORK/cmap.json" '
    [.[] | .name as $c | .instances[] | .name as $i
     | {($c): {instances: {($i): ($f[0] + (($m[0][$c].instances[$i]) // {}) | del(.postgresVersion))}}}]
    | reduce .[] as $e ({}; . * $e)' <<<"$inv" > "$WORK/targets.raw.json"
  yq -o=json -I=0 '.' "$(cmap_keys_file)" > "$WORK/keys.json"
  if ! errs="$(python3 "$TPG_LIB_DIR/clustermap.py" normalize --map "$WORK/targets.raw.json" --keys "$WORK/keys.json" --out "$WORK/targets.json")"; then
    record result.git FAILED INVALID_INPUT "$(tr '\n' ';' <<<"$errs")"
    exit 1
  fi

  for c in $(jq -r '.[].name' <<<"$inv"); do
    use_cluster "$c" || { record_entry "precheck.${c}" BLOCKED NOT_REGISTERED ""; continue; }
    cp "$F" "$WORK/fleet.pre-$c.yaml"
    planned=(); cblock=""
    if [[ "$NP_MODE" != "remove" ]] && ! tk get crd ciliumnetworkpolicies.cilium.io >/dev/null 2>&1; then
      cblock="CILIUM_NOT_AVAILABLE:CiliumNetworkPolicy is not installed (Azure CNI powered by Cilium)"
    fi
    for i in $(jq -r --arg c "$c" '.[] | select(.name == $c) | .instances[].name' <<<"$inv"); do
      [[ -z "$cblock" ]] || break
      if ! g="$(cmap_guard "$c" "$i")"; then record_entry "result.${c}.${i}" SKIPPED_VERSION_MISMATCH "" "$g"; continue; fi
      tk -n "pg-$i" get postgres "$i" >/dev/null 2>&1 \
        || { record_entry "result.${c}.${i}" FAILED INSTANCE_NOT_FOUND "pg-${i}/${i} does not exist on ${c}"; continue; }
      rules="$(jq -c --arg c "$c" --arg i "$i" '.[$c].instances[$i] // {}' "$WORK/targets.json")"
      if [[ "$NP_MODE" != "remove" ]] && jq -e '(.egressToFqdns // []) | length > 0' <<<"$rules" >/dev/null && [[ "$ACNS" != "true" ]]; then
        record_entry "result.${c}.${i}" FAILED ACNS_NOT_ENABLED "egressToFqdns needs ACNS (Terraform acns_enabled = true; run.sh sets acnsEnabled in tpg-settings)"
        continue
      fi
      case "$NP_MODE" in
        remove)
          C="$c" I="$i" yq -i 'del(.clusters[strenv(C)].instances[strenv(I)].network)' "$F" ;;
        apply|update)
          if [[ "$NP_MODE" == "apply" ]]; then
            C="$c" I="$i" yq -i 'del(.clusters[strenv(C)].instances[strenv(I)].network)' "$F"
          fi
          R="$rules" A="$ACNS" C="$c" I="$i" yq -i '
            .clusters[strenv(C)].instances[strenv(I)].network.policy = "baseline"
            | .clusters[strenv(C)].instances[strenv(I)].network.acns = (strenv(A) == "true")
            | .clusters[strenv(C)].instances[strenv(I)].network *= (strenv(R) | from_yaml)' "$F" ;;
      esac
      planned+=("$i")
    done
    if [[ -z "$cblock" && "${#planned[@]}" -gt 0 && "$NP_MODE" != "remove" ]]; then
      # server-side dry run of the rendered policies in each instance namespace
      for i in "${planned[@]}"; do
        if ! out="$(instance_render "$REPO" "$c" "$i" 2>&1)"; then cblock="RENDER_FAILED:${i}: $(tail -n 2 <<<"$out" | tr '\n' ' ')"; break; fi
        pol="$(yq 'select(.kind == "NetworkPolicy" or .kind == "CiliumNetworkPolicy")' <<<"$out")"
        [[ -n "$(tr -d '[:space:]-' <<<"$pol")" ]] || { cblock="RENDER_FAILED:${i}: no policy rendered"; break; }
        if ! out="$(printf '%s\n' "$pol" | tk -n "pg-$i" apply --dry-run=server -f - 2>&1)"; then
          cblock="DRY_RUN_REJECTED:${i}: $(tr '\n' ' ' <<<"$out" | cut -c1-300)"; break
        fi
      done
    fi
    if [[ -n "$cblock" ]]; then
      cp "$WORK/fleet.pre-$c.yaml" "$F"
      record_entry "precheck.${c}" BLOCKED "$cblock" ""
      continue
    fi
    record_entry "precheck.${c}" PASSED "" "${NP_MODE}: ${planned[*]:-nothing}"
    record_entry "plan.${c}" PLANNED "" "$(IFS=,; echo "${planned[*]:-}")"
  done

  changes="$(diff -u "$WORK/fleet.before.yaml" "$F" | tail -n +3 || true)"
  if [[ -z "$changes" ]]; then
    record result.git SUCCEEDED NO_CHANGE "clusters/fleet.yaml already declares these network policies"
    exit 0
  fi
  log "clusters/fleet.yaml changes:"
  printf '%s\n' "$changes" >&2
  if [[ "${P_DRY_RUN:-false}" == "true" ]]; then
    record result.git SUCCEEDED DRY_RUN "$(grep -c '^[+-]' <<<"$changes") changed lines, not pushed"
    exit 0
  fi
  git_commit_push "$REPO" "network-policy ${NP_MODE}: $(jq -r '[.[] | .name + "(" + ([.instances[].name] | join(",")) + ")"] | join(" ")' <<<"$inv") (${WF})" "$FLEET_REL" \
    || { record result.git FAILED GIT_PUSH_FAILED "pushMode=${PUSH_MODE}"; exit 1; }
  appset_refresh tpg-instances
  record_entry revision SET "" "${PUSHED_REVISION:-}"
  record result.git SUCCEEDED "" "pushMode=${PUSH_MODE} ${PUSHED_REVISION:0:12} $(cat /tmp/pull-request 2>/dev/null || true)"
  exit 0
fi

# ------------------------------------------------------------------ apply
C="$3"; TIMEOUT="${4:-900}"
key="result.${C}"
fail() { record "$key" FAILED "$1" "${2:-}"; exit 1; }
result_guard "$key"
use_cluster "$C" || fail NOT_REGISTERED
targets="$(run_data "plan.${C}" | jq -r '.detail // ""')"
git_clone "$WORK/repo"
rev="$(run_data revision | jq -r '.detail // empty')"
[[ -n "$rev" ]] || rev="$(fleet_head)"
failed=0

archive_check() {  # archive_check INSTANCE -> 0 when a WAL switch is archived after the policy change
  local i="$1" pod before after f0 f1 n
  pod="$(tk -n "pg-$i" get pod -l "postgres-instance=${i},role=primary" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$pod" ]] || { CHECK_DETAIL="no primary pod (label role=primary)"; return 1; }
  q() { tk -n "pg-$i" exec "$pod" -c pg-container -- psql -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
  before="$(q "select coalesce(last_archived_wal,'') from pg_stat_archiver")"
  f0="$(q "select failed_count from pg_stat_archiver")"
  # pg_switch_wal() does nothing when no WAL was written since the last switch
  # (an idle instance): commit a transaction with an xid first
  q "select txid_current()" >/dev/null || true
  q "select pg_switch_wal()" >/dev/null || true
  for n in $(seq 1 12); do
    sleep 10
    after="$(q "select coalesce(last_archived_wal,'') from pg_stat_archiver")"
    f1="$(q "select failed_count from pg_stat_archiver")"
    if [[ -n "$after" && "$after" != "$before" ]]; then CHECK_DETAIL="WAL ${after} archived"; return 0; fi
    if [[ -n "$f1" && -n "$f0" && "$f1" -gt "$f0" ]]; then CHECK_DETAIL="archive_command failed ${f1} times (was ${f0}): the backup storage is not reachable"; return 1; fi
    log "${i}: waiting for the WAL switch to be archived (${n}/12)"
  done
  CHECK_DETAIL="no WAL archived within 120s (last ${after:-none})"
  return 1
}
probe() {  # probe NAMESPACE INSTANCE LABELS_JSON -> 0 connected, 1 refused or timed out, 2 the probe pod did not run
  local ns="$1" i="$2" labels="$3" name phase="" args=()
  name="tpg-np-probe-$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
  while IFS= read -r l; do [[ -z "$l" ]] || args+=(--labels "$l"); done < <(jq -r 'to_entries[] | "\(.key)=\(.value)"' <<<"$labels")
  tk -n "$ns" run "$name" --image="${TOOLS_IMAGE:-alpine/k8s:1.35.8}" --restart=Never --quiet "${args[@]}" \
    --command -- sh -c "nc -z -w 5 ${i}.pg-${i}.svc.cluster.local 5432" >/dev/null 2>&1 || return 2
  for _ in $(seq 1 40); do
    phase="$(tk -n "$ns" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
    sleep 3
  done
  tk -n "$ns" delete pod "$name" --wait=false >/dev/null 2>&1 || true
  case "$phase" in Succeeded) return 0 ;; Failed) return 1 ;; *) return 2 ;; esac
}

for i in $(tr ',' ' ' <<<"$targets"); do
  ikey="result.${C}.${i}"
  opts=(); [[ "$NP_MODE" == "remove" ]] && opts=(--prune)
  rc=0; sync_instance_app "$C" "$i" "$TIMEOUT" "$rev" "${opts[@]}" || rc=$?
  if [[ "$rc" -ne 0 ]]; then record_entry "$ikey" FAILED "$SYNC_FAIL_REASON" "$SYNC_FAIL_DETAIL"; failed=1; continue; fi
  n_np="$(tk -n "pg-$i" get networkpolicy tpg-ingress -o name 2>/dev/null | wc -l)"
  n_cnp="$(tk -n "pg-$i" get ciliumnetworkpolicy tpg-egress -o name 2>/dev/null | wc -l)"
  if [[ "$NP_MODE" == "remove" ]]; then
    [[ "$n_np" -eq 0 && "$n_cnp" -eq 0 ]] || { record_entry "$ikey" FAILED POLICY_NOT_REMOVED "tpg-ingress or tpg-egress still exists in pg-${i}"; failed=1; continue; }
  else
    [[ "$n_np" -eq 1 && "$n_cnp" -eq 1 ]] || { record_entry "$ikey" FAILED POLICY_NOT_APPLIED "NetworkPolicy tpg-ingress and CiliumNetworkPolicy tpg-egress expected in pg-${i}"; failed=1; continue; }
  fi
  detail="${NP_MODE}"
  if [[ "${CONNECTIVITY_CHECK:-true}" == "true" ]]; then
    if ! archive_check "$i"; then record_entry "$ikey" FAILED BACKUP_EGRESS_BLOCKED "$CHECK_DETAIL"; failed=1; continue; fi
    detail="${detail}; ${CHECK_DETAIL}"
    if [[ "$NP_MODE" != "remove" ]]; then
      ns="$(C="$C" I="$i" yq -r '.clusters[strenv(C)].instances[strenv(I)].network.ingressFromNamespaces[0] // ""' "$WORK/repo/$FLEET_REL")"
      labels="$(C="$C" I="$i" yq -o=json -I=0 '.clusters[strenv(C)].instances[strenv(I)].network.ingressFromPodLabels // {}' "$WORK/repo/$FLEET_REL")"
      if [[ -n "$ns" ]]; then
        prc=0; probe "$ns" "$i" "$labels" || prc=$?
        case "$prc" in
          0) detail="${detail}; ${ns} reaches 5432" ;;
          1) record_entry "$ikey" FAILED CLIENT_BLOCKED "a pod in ${ns} (labels ${labels}) cannot reach ${i}:5432"; failed=1; continue ;;
          *) record_entry "warning.${C}.${i}.probe" WARNING PROBE_NOT_RUN "the probe pod could not run in ${ns}; check ${ns} -> ${i}:5432 by hand" ;;
        esac
      fi
      allowed="$(C="$C" I="$i" yq -r '.clusters[strenv(C)].instances[strenv(I)].network.ingressFromNamespaces // [] | .[]' "$WORK/repo/$FLEET_REL")"
      if ! grep -qx default <<<"$allowed"; then
        prc=0; probe default "$i" '{}' || prc=$?
        case "$prc" in
          0) record_entry "$ikey" FAILED NOT_ISOLATED "a pod in namespace default reaches ${i}:5432 although it is not allowed"; failed=1; continue ;;
          1) detail="${detail}; default is denied" ;;
          *) record_entry "warning.${C}.${i}.probe-default" WARNING PROBE_NOT_RUN "the probe pod could not run in namespace default" ;;
        esac
      fi
    fi
  fi
  record_entry "$ikey" SUCCEEDED "" "$detail"
done
if [[ "$failed" -eq 0 ]]; then
  record "$key" SUCCEEDED "" "network policy ${NP_MODE}: ${targets:-nothing}"
else
  record "$key" FAILED NETWORK_POLICY_FAILED "see the instance results"
  exit 1
fi
