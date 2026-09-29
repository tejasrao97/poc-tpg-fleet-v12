#!/usr/bin/env bash
# day0-precheck.sh WORKFLOW_NAME CLUSTER
# Read-only. Records precheck.<cluster> = PASSED | MANAGED | BLOCKED (design decision D5).
# Used by tpg-day0 and tpg-create-instance (PRECHECK_MODE=create: the operator
# must already be ours, MANAGED).
#
# Ownership (design decision D62, lib.sh owned_by_app): an object belongs to the
# fleet when its Argo CD tracking annotation names the hub Application that
# deploys it. A Postgres CRD also belongs to it when that Application lists it
# in status.resources, because the Tanzu Postgres CRDs (installed from the
# chart's crds/ directory) do not keep the annotation, and a re-run of tpg-day0
# on a cluster it had deployed reported them as FOREIGN_CRD. An operator is
# found by its label app=postgres-operator or by its image name.
#   operator Deployment and CRDs  tpg-<cluster>-operator
#   Postgres instances            tpg-<cluster>-<instance>
# Postgres CRDs with no operator Deployment at all (left behind by an earlier
# install) are reported as warning ORPHAN_CRD and adopted by the operator sync.
WF="$1"; C="$2"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh
PMODE="${PRECHECK_MODE:-day0}"

# A version the cluster already runs differently (fleet-day0.sh): not changed by this run
blocked="$(run_data "block.${C}")"
if [[ -n "$blocked" ]]; then
  record "precheck.${C}" BLOCKED "$(jq -r '.reason' <<<"$blocked")" "$(jq -r '.detail' <<<"$blocked")"
  exit 0
fi

if ! use_cluster "$C" || ! tk get --raw=/readyz >/dev/null 2>&1; then
  record "precheck.${C}" BLOCKED UNREACHABLE "API server not reachable from the hub"
  exit 0
fi

STATUS=PASSED; MANAGED=false; REASONS=(); NOTES=()
block() { STATUS=BLOCKED; REASONS+=("$1"); }
warn() {  # warn TARGET REASON DETAIL: a warning in the run report, not a block
  record_entry "warning.$1" WARNING "$2" "$3"
  NOTES+=("$2")
}
OP_APP="tpg-${C}-operator"
OP_RES="$(app_resources "$OP_APP")"

# 1. Postgres operator
ours_op=0; foreign_op=0
while read -r d; do
  [[ -z "$d" ]] && continue
  if owned_by_app "$d" "$OP_APP" "$OP_RES"; then MANAGED=true; ours_op=1
  else foreign_op=1; block "FOREIGN_OPERATOR:$(jq -r '.metadata.namespace + "/" + .metadata.name' <<<"$d")"; fi
done < <(operator_deployments)

# 2. Postgres CRDs
orphans=()
while read -r c; do
  [[ -z "$c" ]] && continue
  name="$(jq -r '.metadata.name' <<<"$c")"
  if owned_by_app "$c" "$OP_APP" "$OP_RES"; then
    MANAGED=true
  elif [[ "$ours_op" -eq 0 && "$foreign_op" -eq 0 ]]; then
    orphans+=("$name")
  else
    block "FOREIGN_CRD:${name}"
  fi
done < <(tk get crd -o json | jq -c '.items[] | select(.metadata.name | endswith(".sql.tanzu.vmware.com"))')
if [[ "${#orphans[@]}" -gt 0 ]]; then
  warn "${C}.crds" ORPHAN_CRD "$(IFS=,; echo "${orphans[*]}") exist without a Tanzu Postgres operator; the operator sync adopts them"
fi

if [[ "$PMODE" == "create" && "$MANAGED" != "true" && "$STATUS" != "BLOCKED" ]]; then
  block "OPERATOR_NOT_INSTALLED:run tpg-day0 for ${C} first"
fi

# 3. Same-named Postgres instances (instances declared in Git for this cluster)
if tk get crd postgres.sql.tanzu.vmware.com >/dev/null 2>&1; then
  ALL="$(tk get postgres -A -o json)"
  for i in $(inventory_instances "$C"); do
    ires=""
    while read -r p; do
      [[ -z "$p" ]] && continue
      [[ -n "$ires" ]] || ires="$(app_resources "tpg-${C}-${i}")"
      owned_by_app "$p" "tpg-${C}-${i}" "$ires" || block "INSTANCE_NAME_IN_USE:${i}"
    done < <(jq -c --arg n "$i" '.items[] | select(.metadata.name == $n)' <<<"$ALL")
  done
fi

# 4. Declared Postgres versions exist, and the backup location CRD offers Azure
#    (only possible once the operator is installed)
if [[ "$STATUS" == "PASSED" && "$MANAGED" == "true" ]]; then
  while read -r v; do
    [[ -z "$v" ]] && continue
    tk get postgresversion "$v" >/dev/null 2>&1 || block "VERSION_NOT_AVAILABLE:${v}"
  done < <(inventory_cluster "$C" | jq -r '.instances[].postgresVersion' | sort -u)
  need=""; [[ "$(inventory_cluster "$C" | jq '[.instances[] | select(.enableSSL == true)] | length')" -eq 0 ]] || need=with-ca
  azure_backup_supported $need || block "AZURE_BACKUP_UNSUPPORTED:${AZURE_BACKUP_DETAIL}"
fi

# 5. High availability needs a pgdata pool that spans three zones with three nodes.
#    The rule applies to the pgdata pool only, and only when this run deploys an
#    HA instance; a single-node instance runs on any pool shape.
if [[ "$(inventory_cluster "$C" | jq '[.instances[] | select(.highAvailability)] | length')" -gt 0 ]]; then
  read -r ready zones <<<"$(pgdata_pool_shape)"
  if [[ "${ready:-0}" -lt 3 || "${zones:-0}" -lt 3 ]]; then
    block "PGDATA_POOL_NOT_HA_CAPABLE:${ready:-0} Ready nodes in ${zones:-0} zone(s), highAvailability needs 3 nodes across 3 zones"
  fi
  # 4.5 release notes: with more database pods than zones, the leader and the
  # synchronous standby can share a zone, and Patroni does not fail over when
  # that zone is lost (design decision D66). A warning, not a block.
  while read -r row; do
    [[ -z "$row" ]] && continue
    i="${row%% *}"; pods="${row##* }"
    if (( pods > ${zones:-0} )); then
      warn "${C}.${i}.zones" HA_NODES_EXCEED_ZONES \
        "${i}: ${pods} database pods (1 + readReplicas) in ${zones:-0} zone(s); if the zone of the leader and the synchronous standby fails, Patroni does not fail over automatically (fail over by hand, Runbook)"
    fi
  done < <(inventory_cluster "$C" | jq -r '.instances[] | select(.highAvailability) | "\(.name) \(1 + (.readReplicas // 0))"')
fi

# 6. Network policies (baseline) use CiliumNetworkPolicy for egress; egressToFqdns
#    and the backup FQDN rule need Advanced Container Networking Services (ACNS)
if [[ "$(inventory_cluster "$C" | jq '[.instances[] | select(.networkPolicy == "baseline")] | length')" -gt 0 ]]; then
  tk get crd ciliumnetworkpolicies.cilium.io >/dev/null 2>&1 \
    || block "CILIUM_NOT_AVAILABLE:networkPolicy=baseline needs CiliumNetworkPolicy (Azure CNI powered by Cilium)"
fi
if [[ "$(inventory_cluster "$C" | jq '[.instances[] | select((.egressToFqdns // []) | length > 0)] | length')" -gt 0 \
      && "$(setting acnsEnabled)" != "true" ]]; then
  block "ACNS_NOT_ENABLED:egressToFqdns needs ACNS on the cluster (Terraform acns_enabled = true; run.sh then sets acnsEnabled in tpg-settings)"
fi

# 7. FerretDB (D71, Tech Preview): Postgres 17.5 or later; the
#    PostgresFerretDocumentDB CRD once the operator runs (a new operator is
#    checked again by the deploy step after its sync)
while read -r row; do
  [[ -z "$row" ]] && continue
  i="${row%% *}"; v="${row##* }"; num="${v#postgres-}"
  if ! [[ "$num" =~ ^[0-9]+\.[0-9]+$ ]] || [[ "$(printf '%s\n%s\n' 17.5 "$num" | sort -V | head -n1)" != "17.5" ]]; then
    block "FERRET_VERSION_UNSUPPORTED:${i} runs ${v}; FerretDB needs Postgres 17.5 or later"
  fi
done < <(inventory_cluster "$C" | jq -r '.instances[] | select(.ferret == true) | "\(.name) \(.postgresVersion)"')
if [[ "$(inventory_cluster "$C" | jq '[.instances[] | select(.ferret == true)] | length')" -gt 0 && "$MANAGED" == "true" ]]; then
  tk get crd postgresferretdocumentdbs.sql.tanzu.vmware.com >/dev/null 2>&1 \
    || block "FERRET_CRD_MISSING:the operator on ${C} has no PostgresFerretDocumentDB CRD (operator 4.5.0 or later)"
fi

[[ "$STATUS" == "PASSED" && "$MANAGED" == "true" ]] && STATUS=MANAGED
record "precheck.${C}" "$STATUS" "$(IFS=,; echo "${REASONS[*]:-}")" "$( [[ "${#NOTES[@]}" -eq 0 ]] || printf 'warnings: %s' "$(IFS=,; echo "${NOTES[*]}")")"
