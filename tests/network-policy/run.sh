#!/usr/bin/env bash
# tpg-network-policy planning (workflows/scripts/network-policy.sh plan):
#   mode apply    network becomes {policy: baseline} with exactly the rules given
#   mode update   only the rules given change
#   mode remove   the network entry is deleted
#   clusterMap    rules per instance over the inputs; a postgresVersion guard
#   blocks        CILIUM_NOT_AVAILABLE, DRY_RUN_REJECTED (the cluster is not
#                 written), ACNS_NOT_ENABLED for egressToFqdns, INSTANCE_NOT_FOUND
#   dry run       nothing pushed
# Runs the script with the real lib.sh, clustermap.py and chart (the rendered
# policies are dry-run against a stub), and stubs for Git, the run ConfigMap and
# the target cluster.
# Requires: bash 4, python3, jq, yq (mikefarah), helm; skipped without them.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
for t in python3 jq yq helm; do command -v "$t" >/dev/null || { echo "SKIP tests/network-policy: $t not installed" >&2; exit 0; }; done
yq --version 2>&1 | grep -q mikefarah || { echo "SKIP tests/network-policy: yq is not mikefarah yq v4" >&2; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/       | /' | tail -15; FAIL=$((FAIL + 1)); }

REPO="$TMP/repo"
mkdir -p "$REPO/clusters"
cp -r "$ROOT/charts" "$REPO/"
cp -r "$ROOT/clusters/_template" "$REPO/clusters/"
cat > "$TMP/fleet.base.yaml" <<'YAML'
clusters:
  c1:
    operator: {version: v4.5.0}
    instances:
      orders-db:
        instance: {postgresVersion: postgres-17.6}
        network: {policy: baseline, acns: false, ingressFromNamespaces: [app], egressToCidrs: [10.9.0.0/16]}
      billing-db: {instance: {postgresVersion: postgres-16.10}}
  c2:
    operator: {version: v4.5.0}
    instances:
      orders-db: {instance: {postgresVersion: postgres-17.6}}
YAML

# ---- stubs. Scenario variables:
#   S_CILIUM   yes | no   CiliumNetworkPolicy CRD on the target
#   S_REJECT   an instance whose policies the API server rejects (dry run)
#   S_ACNS     tpg-settings acnsEnabled
#   S_MISSING  an instance that does not exist on the target
cat > "$TMP/prelude.sh" <<PRELUDE
export TPG_WORK="$TMP/work"
source "$ROOT/workflows/scripts/lib.sh"
CMAP_KEYS="$ROOT/workflows/params/cluster-map-keys.yaml"
git_clone() { rm -rf "\$1"; cp -r "$REPO" "\$1"; cp "$TMP/fleet.yaml" "\$1/clusters/fleet.yaml"; }
record() { printf '%s|%s|%s|%s\n' "\$1" "\$2" "\${3:-}" "\${4:-}" >> "$TMP/records"; printf '%s' "\$2" > "$TMP/result"; RESULT_RECORDED=1; }
record_entry() { printf '%s|%s|%s|%s\n' "\$1" "\$2" "\${3:-}" "\${4:-}" >> "$TMP/records"; }
run_data() { [[ "\$1" == inventory ]] && cat "$TMP/inventory.json"; return 0; }
setting() { [[ "\$1" == acnsEnabled ]] && printf '%s' "\${S_ACNS:-false}"; return 0; }
appset_refresh() { :; }
git_commit_push() { cp "\$1/clusters/fleet.yaml" "$TMP/pushed.yaml"; PUSHED_REVISION=abc123def456; }
use_cluster() { CLUSTER="\$1"; }
tk() {
  case "\$*" in
    *"get crd ciliumnetworkpolicies.cilium.io"*) [[ "\${S_CILIUM:-yes}" == yes ]] ;;
    *"--dry-run=server"*)
      cat >> "$TMP/dryrun.yaml"
      [[ "\$2" != "pg-\${S_REJECT:-none}" ]] || { echo 'Error from server (Invalid): CiliumNetworkPolicy.cilium.io "tpg-egress" is invalid'; return 1; }
      echo "created (server dry run)" ;;
    *" get postgres "*)
      [[ "\$2" != "pg-\${S_MISSING:-none}" ]] || return 1
      case "\$*" in *jsonpath*) [[ "\$2" == pg-billing-db ]] && printf 'postgres-16.10' || printf 'postgres-17.6' ;; esac
      return 0 ;;
    *) return 0 ;;
  esac
}
PRELUDE
sed "s#source /scripts/lib.sh#source $TMP/prelude.sh#" "$ROOT/workflows/scripts/network-policy.sh" > "$TMP/network-policy.sh"

reset() { rm -rf "$TMP/work"; : > "$TMP/records"; : > "$TMP/dryrun.yaml"; rm -f "$TMP/pushed.yaml"; cp "$TMP/fleet.base.yaml" "$TMP/fleet.yaml"
  unset S_CILIUM S_REJECT S_ACNS S_MISSING P_CLUSTER_MAP P_INGRESS_FROM_NAMESPACES P_INGRESS_FROM_POD_LABELS P_INGRESS_FROM_CIDRS \
    P_EGRESS_TO_CIDRS P_EGRESS_TO_FQDNS P_DRY_RUN; }
inv() {  # inv JSON: discover output, [{name, instances: [names]}]
  jq -c '[.[] | {name, wave: 0, instances: [.instances[] | {name: .}]}]' <<<"$1" > "$TMP/inventory.json"
}
plan() { RC=0; OUT="$(bash "$TMP/network-policy.sh" plan wf 2>&1)" || RC=$?; }
net() { yq -o=json -I=0 ".clusters.$1.instances.$2.network // null" "$TMP/pushed.yaml" 2>/dev/null || echo missing; }
rec() { grep -F "$1" "$TMP/records" || true; }

# ---- apply replaces the rules
reset; inv '[{"name":"c1","instances":["orders-db","billing-db"]}]'
P_NP_MODE=apply P_PUSH_MODE=direct P_INGRESS_FROM_NAMESPACES=batch P_INGRESS_FROM_POD_LABELS='role: api' plan
[[ "$RC" -eq 0 ]] && jq -e '. == {"policy":"baseline","acns":false,"ingressFromNamespaces":["batch"],"ingressFromPodLabels":{"role":"api"}}' <<<"$(net c1 orders-db)" >/dev/null \
  && jq -e '.policy == "baseline" and .ingressFromNamespaces == ["batch"]' <<<"$(net c1 billing-db)" >/dev/null \
  && ok "apply: exactly the rules given (egressToCidrs of orders-db removed), YAML map input" || bad "apply" "$(net c1 orders-db) $OUT"
rec "precheck.c1|PASSED" | grep -q "apply: orders-db billing-db" && rec "plan.c1|PLANNED" | grep -q "orders-db,billing-db" \
  && grep -q "kind: NetworkPolicy" "$TMP/dryrun.yaml" && grep -q "kind: CiliumNetworkPolicy" "$TMP/dryrun.yaml" \
  && ok "apply: both policies dry-run on the cluster, precheck PASSED and plan recorded" || bad "apply records" "$(cat "$TMP/records")"

# ---- update keeps the other rules
reset; inv '[{"name":"c1","instances":["orders-db"]}]'
P_NP_MODE=update P_PUSH_MODE=direct P_EGRESS_TO_CIDRS=10.20.0.0/16 plan
jq -e '.ingressFromNamespaces == ["app"] and .egressToCidrs == ["10.20.0.0/16"]' <<<"$(net c1 orders-db)" >/dev/null \
  && ok "update: the rule given changes, ingressFromNamespaces is kept" || bad "update" "$(net c1 orders-db) $OUT"

# ---- remove
reset; inv '[{"name":"c1","instances":["orders-db"]}]'
P_NP_MODE=remove P_PUSH_MODE=direct S_CILIUM=no plan
[[ "$(net c1 orders-db)" == "null" ]] && [[ ! -s "$TMP/dryrun.yaml" ]] && rec "precheck.c1|PASSED" | grep -q "remove" \
  && ok "remove: the network entry is deleted, no Cilium needed, nothing to dry-run" || bad "remove" "$(net c1 orders-db) $OUT"

# ---- clusterMap rules per instance, over the inputs
reset; inv '[{"name":"c1","instances":["orders-db"]},{"name":"c2","instances":["orders-db"]}]'
P_NP_MODE=apply P_PUSH_MODE=direct P_INGRESS_FROM_NAMESPACES=app P_CLUSTER_MAP='c1: {instances: {orders-db: {ingressFromCidrs: [10.1.0.0/16]}}}
c2: {instances: {orders-db: {ingressFromNamespaces: [web, api]}}}' plan
jq -e '.ingressFromNamespaces == ["app"] and .ingressFromCidrs == ["10.1.0.0/16"]' <<<"$(net c1 orders-db)" >/dev/null \
  && jq -e '.ingressFromNamespaces == ["web","api"]' <<<"$(net c2 orders-db)" >/dev/null \
  && ok "clusterMap: per-instance rules, the inputs are the defaults" || bad "clusterMap" "$(net c1 orders-db) $(net c2 orders-db) $OUT"

# ---- postgresVersion guard
reset; inv '[{"name":"c1","instances":["billing-db"]}]'
P_NP_MODE=apply P_PUSH_MODE=direct P_CLUSTER_MAP='c1: {instances: {billing-db: {postgresVersion: "17.6"}}}' plan
rec "result.c1.billing-db|SKIPPED_VERSION_MISMATCH" | grep -q "the live instance runs postgres-16.10" && rec "result.git|SUCCEEDED|NO_CHANGE" | grep -q . \
  && ok "guard: an instance on another version is skipped and nothing changes" || bad "guard" "$(cat "$TMP/records")"

# ---- blocks
reset; inv '[{"name":"c1","instances":["orders-db"]},{"name":"c2","instances":["orders-db"]}]'
P_NP_MODE=apply P_PUSH_MODE=direct P_INGRESS_FROM_NAMESPACES=app S_REJECT=orders-db plan
rec "precheck.c1|BLOCKED|DRY_RUN_REJECTED" | grep -q 'is invalid' && rec "precheck.c2|BLOCKED|DRY_RUN_REJECTED" | grep -q . \
  && [[ ! -f "$TMP/pushed.yaml" ]] && rec "result.git|SUCCEEDED|NO_CHANGE" | grep -q . \
  && ok "DRY_RUN_REJECTED: the cluster is BLOCKED and its entries are not written" || bad "dry run rejected" "$(cat "$TMP/records")"
reset; inv '[{"name":"c1","instances":["orders-db"]}]'
P_NP_MODE=apply P_PUSH_MODE=direct S_CILIUM=no plan
rec "precheck.c1|BLOCKED|CILIUM_NOT_AVAILABLE" | grep -q . && ok "CILIUM_NOT_AVAILABLE blocks apply" || bad "cilium" "$(cat "$TMP/records")"
reset; inv '[{"name":"c1","instances":["orders-db","billing-db"]}]'
P_NP_MODE=apply P_PUSH_MODE=direct P_CLUSTER_MAP='c1: {instances: {orders-db: {egressToFqdns: [api.example.com]}, billing-db: {}}}' plan
rec "result.c1.orders-db|FAILED|ACNS_NOT_ENABLED" | grep -q . && rec "plan.c1|PLANNED" | grep -q "|billing-db$" \
  && jq -e '.policy == "baseline"' <<<"$(net c1 billing-db)" >/dev/null \
  && ok "ACNS_NOT_ENABLED: egressToFqdns without ACNS fails that instance, the others go ahead" || bad "acns" "$(cat "$TMP/records")"
reset; inv '[{"name":"c1","instances":["orders-db"]}]'
P_NP_MODE=apply P_PUSH_MODE=direct S_ACNS=true P_EGRESS_TO_FQDNS='*.example.com' plan
jq -e '.acns == true and .egressToFqdns == ["*.example.com"]' <<<"$(net c1 orders-db)" >/dev/null && grep -q 'matchPattern: "\*.example.com"' "$TMP/dryrun.yaml" \
  && ok "ACNS: network.acns true and toFQDNs rendered" || bad "acns on" "$(net c1 orders-db) $OUT"
reset; inv '[{"name":"c1","instances":["orders-db"]}]'
P_NP_MODE=apply P_PUSH_MODE=direct S_MISSING=orders-db plan
rec "result.c1.orders-db|FAILED|INSTANCE_NOT_FOUND" | grep -q . && ok "INSTANCE_NOT_FOUND for a declared instance that does not run" || bad "missing" "$(cat "$TMP/records")"

# ---- invalid input and dry run
reset; inv '[{"name":"c1","instances":["orders-db"]}]'
P_NP_MODE=apply P_PUSH_MODE=direct P_INGRESS_FROM_CIDRS=10.1.2.3/16 plan
[[ "$RC" -ne 0 ]] && rec "result.git|FAILED|INVALID_INPUT" | grep -q "host bits zero" && ok "a CIDR with host bits fails the plan (INVALID_INPUT)" || bad "invalid" "$(cat "$TMP/records")"
reset; inv '[{"name":"c1","instances":["orders-db"]}]'
P_NP_MODE=apply P_PUSH_MODE=direct P_DRY_RUN=true P_INGRESS_FROM_NAMESPACES=app plan
rec "result.git|SUCCEEDED|DRY_RUN" | grep -q . && [[ ! -f "$TMP/pushed.yaml" ]] && ok "dryRun: planned and dry-run, nothing pushed" || bad "dry run" "$(cat "$TMP/records")"

echo
echo "network-policy: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
