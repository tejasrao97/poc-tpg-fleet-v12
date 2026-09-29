#!/usr/bin/env bash
# tpg-scale-instance planning (Round 14, D80): scale-instance.sh plan with the
# real lib.sh and clustermap.py, and stubs for Git, the run ConfigMap and the
# target cluster; then plan-batches.sh and the batch-items step of the template
# for the rollout.
#   maxReadReplicas   the input or the clusterMap cluster key is written to
#                     clusters.<c>.cluster.maxReadReplicas, alone (no instance is
#                     synced) or with a scale in the same commit; the new cap bounds
#                     the replicas of the run; a cap that would leave an instance
#                     above it is refused (MAX_BELOW_CURRENT) and the cap stays
#   rollout           precheck.<c> PASSED for every cluster with an instance to
#                     sync, so plan-batches builds canary, batches or all; the
#                     batch-items step picks the instances of one batch
# Requires: bash 4, python3, jq, yq (mikefarah); skipped without them.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
for t in python3 jq yq; do command -v "$t" >/dev/null || { echo "SKIP tests/scale: $t not installed" >&2; exit 0; }; done
yq --version 2>&1 | grep -q mikefarah || { echo "SKIP tests/scale: yq is not mikefarah yq v4" >&2; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/       | /' | tail -15; FAIL=$((FAIL + 1)); }

REPO="$TMP/repo"
mkdir -p "$REPO/clusters"
cp -r "$ROOT/clusters/_template" "$REPO/clusters/"
cat > "$TMP/fleet.base.yaml" <<'YAML'
clusters:
  c1:
    operator: {version: v4.5.0}
    instances:
      orders-db: {instance: {highAvailability: {enabled: true, readReplicas: 2}}}
      billing-db: {instance: {highAvailability: {enabled: false, readReplicas: 0}}}
  c2:
    cluster: {maxReadReplicas: 4}
    operator: {version: v4.5.0}
    instances:
      orders-db: {instance: {highAvailability: {enabled: true, readReplicas: 1}}}
  c3:
    operator: {version: v4.5.0}
    instances:
      reporting-db: {instance: {highAvailability: {enabled: true, readReplicas: 1}}}
YAML

cat > "$TMP/prelude.sh" <<PRELUDE
export TPG_WORK="$TMP/work"
source "$ROOT/workflows/scripts/lib.sh"
CMAP_KEYS="$ROOT/workflows/params/cluster-map-keys.yaml"
set +e
git_clone() { rm -rf "\$1"; cp -r "$REPO" "\$1"; cp "$TMP/fleet.yaml" "\$1/clusters/fleet.yaml"; }
record() { printf '%s|%s|%s|%s\n' "\$1" "\$2" "\${3:-}" "\${4:-}" >> "$TMP/records"; printf '%s' "\$2" > "$TMP/result"; RESULT_RECORDED=1; }
record_entry() { printf '%s|%s|%s|%s\n' "\$1" "\$2" "\${3:-}" "\${4:-}" >> "$TMP/records"; }
record_status() { grep -F "\$1|" "$TMP/records" 2>/dev/null | tail -n1 | cut -d'|' -f2; }
run_data() {
  [[ "\$1" == inventory ]] && { cat "$TMP/inventory.json"; return; }
  local l; l="\$(grep -F "\$1|" "$TMP/records" 2>/dev/null | tail -n1)"; [[ -n "\$l" ]] || return 0
  jq -cn --arg s "\$(cut -d'|' -f2 <<<"\$l")" --arg d "\$(cut -d'|' -f4- <<<"\$l")" '{status: \$s, detail: \$d}'
}
git_commit_push() { cp "\$1/clusters/fleet.yaml" "$TMP/pushed.yaml"; PUSHED_REVISION=abc123def456; }
use_cluster() { CLUSTER="\$1"; }
pg_state() { echo Running; }
pgdata_pool_shape() { echo "3 3"; }
tk() { case "\$*" in *" get postgresversionupgrade"*|*" get postgresrestore"*) echo '{"items":[]}' ;; esac; }
PRELUDE

inventory() {  # inventory CLUSTER:INSTANCE,INSTANCE ... (wave = index, c1 is wave 0)
  local out="[]" w=0 spec c insts
  for spec in "$@"; do
    c="${spec%%:*}"; insts="${spec#*:}"; [[ "$spec" == *:* ]] || insts=""
    out="$(jq -c --arg c "$c" --argjson w "$w" --arg i "$insts" \
      '. + [{name: $c, wave: $w, instances: ($i | split(",") | map(select(. != "")) | map({name: .}))}]' <<<"$out")"
    w=$((w + 1))
  done
  printf '%s' "$out" > "$TMP/inventory.json"
}

plan() {  # plan VAR=VALUE...: scale-instance.sh plan in a subshell
  rm -rf "$TMP/work" "$TMP/pushed.yaml"; : > "$TMP/records"; mkdir -p "$TMP/work"
  cp "$TMP/fleet.base.yaml" "$TMP/fleet.yaml"
  sed -e "s#^source /scripts/lib.sh#source $TMP/prelude.sh#" -e "s#/tmp/items.json#$TMP/items.json#g" \
    "$ROOT/workflows/scripts/scale-instance.sh" > "$TMP/scale.sh"
  OUT="$(env "$@" bash "$TMP/scale.sh" plan wf-test 2>&1)" || true
}
rec() { grep -F "$1|" "$TMP/records" | tail -n1; }
pushed() { yq -r "$1" "$TMP/pushed.yaml" 2>/dev/null; }

echo "== 1: maxReadReplicas alone"
inventory c1:orders-db,billing-db c2:orders-db
plan P_CLUSTERS=c1,c2 P_MAX_READ_REPLICAS=5 P_PUSH_MODE=direct
[[ "$(pushed '.clusters.c1.cluster.maxReadReplicas')" == 5 && "$(pushed '.clusters.c2.cluster.maxReadReplicas')" == 5 ]] \
  && ok "the cap is written for every selected cluster" || bad "the cap is written for every selected cluster" "$OUT"
[[ "$(jq length "$TMP/items.json")" == 0 ]] && ok "no instance is synced" || bad "no instance is synced" "$(cat "$TMP/items.json")"
grep -q '^precheck\.' "$TMP/records" && bad "no cluster is planned for the rollout" "$(cat "$TMP/records")" \
  || ok "no cluster is planned for the rollout"
[[ "$(pushed '.clusters.c1.instances.orders-db.instance.highAvailability.readReplicas')" == 2 ]] \
  && ok "the instances keep their counts" || bad "the instances keep their counts"
rec result.c2.maxReadReplicas | grep -q "SUCCEEDED||maxReadReplicas 4 -> 5" \
  && ok "the result names the old and the new cap" || bad "the result names the old and the new cap" "$(cat "$TMP/records")"

echo "== 2: the same cap again"
inventory c2:orders-db
plan P_CLUSTERS=c2 P_MAX_READ_REPLICAS=4 P_PUSH_MODE=direct
rec result.c2.maxReadReplicas | grep -q "ALREADY_AT_TARGET" && ok "an unchanged cap is ALREADY_AT_TARGET" || bad "an unchanged cap is ALREADY_AT_TARGET" "$(cat "$TMP/records")"
rec result.git | grep -q NO_CHANGE && [[ ! -f "$TMP/pushed.yaml" ]] && ok "and nothing is pushed" || bad "and nothing is pushed"

echo "== 3: a cap and a scale in one run"
inventory c1:orders-db
plan P_CLUSTERS=c1 P_INSTANCES=orders-db P_REPLICAS=5 P_MAX_READ_REPLICAS=5 P_PUSH_MODE=direct
[[ "$(pushed '.clusters.c1.instances.orders-db.instance.highAvailability.readReplicas')" == 5 \
   && "$(pushed '.clusters.c1.cluster.maxReadReplicas')" == 5 ]] \
  && ok "replicas 5 is within the new cap and both are in one commit" || bad "replicas 5 is within the new cap" "$OUT"
[[ "$(jq -c '[.[] | .cluster + "/" + .instance]' "$TMP/items.json")" == '["c1/orders-db"]' ]] \
  && ok "the instance is planned for the sync" || bad "the instance is planned for the sync" "$(cat "$TMP/items.json")"
rec precheck.c1 | grep -q "PASSED||instances: orders-db" && ok "precheck.c1 PASSED for the rollout" || bad "precheck.c1 PASSED" "$(cat "$TMP/records")"
plan P_CLUSTERS=c1 P_INSTANCES=orders-db P_REPLICAS=5 P_PUSH_MODE=direct
rec result.c1.orders-db | grep -q "OUT_OF_BOUNDS|replicas 5 > maxReadReplicas 3" \
  && ok "without the new cap the default 3 still bounds it" || bad "without the new cap the default 3 bounds it" "$(cat "$TMP/records")"

echo "== 4: a cap the run cannot honour stays as it was"
# the validate step refuses this; the plan keeps the cap when a scale in the run fails
inventory c1:orders-db
plan P_CLUSTER_MAP='c1: {maxReadReplicas: 1, instances: {orders-db: {replicas: 1}}}' P_PUSH_MODE=direct \
  P_ENABLE_HA=true
[[ "$(pushed '.clusters.c1.cluster.maxReadReplicas')" == 1 ]] && ok "scaled to the cap: the cap is written" || bad "scaled to the cap: the cap is written" "$OUT"
cat > "$TMP/prelude.extra" <<'X'
pg_state() { [[ "$1" == orders-db ]] && echo Updating || echo Running; }
X
cat "$TMP/prelude.extra" >> "$TMP/prelude.sh"
plan P_CLUSTER_MAP='c1: {maxReadReplicas: 1, instances: {orders-db: {replicas: 1}}}' P_PUSH_MODE=direct
rec result.c1.maxReadReplicas | grep -q "FAILED|MAX_BELOW_CURRENT|maxReadReplicas 1 is below the read replicas of orders-db=2; the cap stays 3" \
  && ok "the instance was not scaled (NOT_RUNNING): the cap is refused" || bad "the cap is refused when the scale fails" "$(cat "$TMP/records")"
rec result.git | grep -q NO_CHANGE && ok "and nothing is pushed" || bad "and nothing is pushed" "$(cat "$TMP/records")"
sed -i '/^pg_state() { \[\[/d' "$TMP/prelude.sh"

echo "== 5: clusterMap: a cap-only cluster next to a scaled one"
inventory c1:orders-db c3
plan P_CLUSTER_MAP='{c1: {instances: {orders-db: {replicas: 1}}}, c3: {maxReadReplicas: 2}}' P_PUSH_MODE=direct
[[ "$(pushed '.clusters.c3.cluster.maxReadReplicas')" == 2 && "$(pushed '.clusters.c1.cluster.maxReadReplicas // "unset"')" == unset ]] \
  && ok "only c3 gets a cap" || bad "only c3 gets a cap" "$OUT"
grep -q '^precheck\.c3' "$TMP/records" && bad "c3 is not in the rollout" || ok "c3 is not in the rollout"
rec precheck.c1 | grep -q PASSED && ok "c1 is in the rollout" || bad "c1 is in the rollout" "$(cat "$TMP/records")"

echo "== 6: the rollout"
cat > "$TMP/inventory.json" <<'J'
[{"name":"c1","wave":0,"instances":[{"name":"orders-db"}]},{"name":"c2","wave":1,"instances":[{"name":"orders-db"}]},{"name":"c3","wave":1,"instances":[{"name":"reporting-db"}]}]
J
: > "$TMP/records"
for c in c1 c2 c3; do printf 'precheck.%s|PASSED||\n' "$c" >> "$TMP/records"; done
batches() {  # batches MODE MAXP -> batches JSON
  (cd "$TMP" && sed -e "s#^source /scripts/lib.sh#source $TMP/prelude.sh#" -e "s#/tmp/batches.json#$TMP/pb-batches.json#g" -e "s#/tmp/has-batches#$TMP/pb-has-batches#g" \
      "$ROOT/workflows/scripts/plan-batches.sh" > "$TMP/pb.sh" && bash "$TMP/pb.sh" wf true "$2" "$1" >/dev/null 2>&1)
  cat "$TMP/pb-batches.json"
}
[[ "$(batches all 2)" == '[["c1","c2","c3"]]' ]] && ok "all: one batch" || bad "all: one batch" "$(batches all 2)"
[[ "$(batches canary 2)" == '[["c1"],["c2","c3"]]' ]] && ok "canary: c1 first, then batches of 2" || bad "canary" "$(batches canary 2)"
[[ "$(batches batches 1)" == '[["c1"],["c2"],["c3"]]' ]] && ok "batches of 1" || bad "batches of 1" "$(batches batches 1)"
sel="$(yq -r '.spec.templates[] | select(.name == "batch-items") | .container.args[0]' "$ROOT/workflows/templates/tpg-scale-instance.yaml" \
  | sed "s#/tmp/batch-items.json#$TMP/bi.json#g")"
all='[{"cluster":"c1","instance":"orders-db"},{"cluster":"c2","instance":"orders-db"},{"cluster":"c3","instance":"reporting-db"}]'
got="$(bash -c "$sel" '["c2","c3"]' "$all")"
[[ "$got" == '[{"cluster":"c2","instance":"orders-db"},{"cluster":"c3","instance":"reporting-db"}]' ]] \
  && ok "batch-items keeps the instances of the batch's clusters" || bad "batch-items" "$got"
got="$(bash -c "$sel" '["c9"]' "$all")"
[[ "$got" == '[]' ]] && ok "batch-items: a batch without instances is an empty list" || bad "batch-items empty" "$got"
yq -e '.spec.arguments.parameters[] | select(.name == "rolloutMode") | .value == "all"' \
  "$ROOT/workflows/templates/tpg-scale-instance.yaml" >/dev/null && ok "rolloutMode defaults to all" || bad "rolloutMode defaults to all"

echo "== 7: a failed batch: the targets it did not reach get their previous count back"
inventory c1:orders-db c2:orders-db
plan P_CLUSTERS=c1,c2 P_INSTANCES=orders-db P_REPLICAS=3 P_PUSH_MODE=direct
rec plan.items | grep -q '"previousEnabled":true' && ok "the plan records the previous highAvailability of each target" \
  || bad "the plan records the previous highAvailability" "$(cat "$TMP/records")"
printf 'result.c1.orders-db|FAILED|SYNC_REJECTED|stub\n' >> "$TMP/records"   # the canary failed, c2 never ran
cp "$TMP/pushed.yaml" "$TMP/fleet.yaml"; rm -f "$TMP/pushed.yaml"
sed -i "s#^git_clone() .*#git_clone() { rm -rf \"\\\$1\"; cp -r $REPO \"\\\$1\"; cp $TMP/fleet.yaml \"\\\$1/clusters/fleet.yaml\"; }#" "$TMP/prelude.sh"
OUT="$(bash "$TMP/scale.sh" restore wf-test 2>&1)" || true
[[ "$(pushed '.clusters.c2.instances.orders-db.instance.highAvailability.readReplicas')" == 1 \
   && "$(pushed '.clusters.c1.instances.orders-db.instance.highAvailability.readReplicas')" == 3 ]] \
  && ok "c2 (not reached) is back at 1; c1 (ran and failed) keeps 3" || bad "restore of the unreached target" "$OUT"
rec result.c2.orders-db | grep -q "NOT_RUN||an earlier batch failed; clusters/fleet.yaml restored" \
  && ok "c2 is NOT_RUN with the restore named" || bad "c2 is NOT_RUN" "$(cat "$TMP/records")"
rm -f "$TMP/pushed.yaml"
OUT="$(bash "$TMP/scale.sh" restore wf-test 2>&1)" || true
[[ ! -f "$TMP/pushed.yaml" ]] && ok "a second restore finds nothing left to do" || bad "a second restore" "$OUT"

echo
echo "tests/scale: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
