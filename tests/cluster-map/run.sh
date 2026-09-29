#!/usr/bin/env bash
# clusterMap and the list inputs: workflows/scripts/validate-params.sh (with
# clustermap.py and workflows/params/cluster-map-keys.yaml), the clusterMap
# accessors of lib.sh, and fleet-day0.sh (tpg-day0 values and the version rule).
#
# validate-params.sh runs with the real lib.sh and a stub kubectl that lists the
# registered clusters. fleet-day0.sh runs with the real lib.sh and stubs for
# Git, the run ConfigMap and the target clusters (what each one runs), as a dry
# run, so the planned clusters/fleet.yaml is read from /tmp/fleet.json.
#
# Requires: bash 4, python3, jq, yq (mikefarah).
# ok() and bad() always return 0; single-quoted snippets are jq, yq or YAML.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
for t in python3 jq yq; do command -v "$t" >/dev/null || { echo "SKIP tests/cluster-map: $t not installed" >&2; exit 0; }; done
yq --version 2>&1 | grep -q mikefarah || { echo "SKIP tests/cluster-map: yq is not mikefarah yq v4" >&2; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/       | /' | tail -12; FAIL=$((FAIL + 1)); }

# ---- stub kubectl: registered clusters
mkdir -p "$TMP/bin"
cat > "$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"get secret -l tpg.fleet/cluster"* ]]; then
  printf '{"items":[%s]}' "$(for c in aks-tpg-poc-01 aks-tpg-poc-02 aks-tpg-poc-03; do
    printf '{"metadata":{"labels":{"tpg.fleet/cluster":"%s"}}},' "$c"; done | sed 's/,$//')"
  exit 0
fi
exit 0
STUB
chmod +x "$TMP/bin/kubectl"
# the fleet repository the tpg-scale-instance validate step reads (Round 13 addendum):
# orders-db on aks-tpg-poc-01 runs HA, billing-db is a single node
mkdir -p "$TMP/scalerepo/clusters"
cp -r "$ROOT/clusters/_template" "$TMP/scalerepo/clusters/"
cat > "$TMP/scalerepo/clusters/fleet.yaml" <<'YAML'
clusters:
  aks-tpg-poc-01:
    operator:
      version: v4.5.0
    instances:
      orders-db:
        instance:
          highAvailability:
            enabled: true
            readReplicas: 2
      billing-db:
        instance:
          highAvailability:
            enabled: false
            readReplicas: 0
YAML
sed -e "s#source /scripts/lib.sh#source $ROOT/workflows/scripts/lib.sh#" \
    -e "/^source .*lib.sh\$/a git_clone() { rm -rf \"\$1\"; cp -r $TMP/scalerepo \"\$1\"; }" \
    "$ROOT/workflows/scripts/validate-params.sh" > "$TMP/validate.sh"

vp() {  # vp MODE VAR=VALUE... -> runs validate-params.sh; output in $OUT, status in $RC
  local mode="$1"; shift
  rm -rf "$TMP/work"
  RC=0; OUT="$(cd "$TMP" && env -i PATH="$TMP/bin:$PATH" HOME="$TMP" TPG_WORK="$TMP/work" "$@" \
    bash "$TMP/validate.sh" "$mode" 2>&1)" || RC=$?
}
valid() { [[ "$RC" -eq 0 ]] && ok "$1" || bad "$1" "$OUT"; }
invalid() {  # invalid LABEL TEXT...
  local t
  [[ "$RC" -ne 0 ]] || { bad "$1 (accepted)" "$OUT"; return; }
  for t in "${@:2}"; do grep -qF -- "$t" <<<"$OUT" || { bad "$1 (no '$t')" "$OUT"; return; }; done
  ok "$1"
}

MAP_OK='aks-tpg-poc-01:
  operatorVersion: 4.5.0
  instances:
    orders-db:
      postgresVersion: 16.10
      highAvailability: true
      storageSize: 50Gi
      cpu: "2"
    billing-db:
      postgresVersion: postgres-17.6
      highAvailability: false
      enableSSL: true
aks-tpg-poc-02:
  operatorVersion: v4.5.0
  instances:
    orders-db: {postgresVersion: "17.6", highAvailability: true, readReplicas: 2}'

# ---- tpg-day0
vp day0 P_CLUSTER_MAP="$MAP_OK" P_PUSH_MODE=direct
valid "day0: a YAML clusterMap with per-instance keys is valid"
[[ "$(cat /tmp/selection)" == "aks-tpg-poc-01,aks-tpg-poc-02" && "$(jq -c . /tmp/clusters.json)" == '["aks-tpg-poc-01","aks-tpg-poc-02"]' ]] \
  && ok "day0: the selection and the cluster list come from the map" || bad "day0 selection" "$(cat /tmp/selection) $(cat /tmp/clusters.json)"
jq -e '.["aks-tpg-poc-01"].instances["orders-db"].postgresVersion == "postgres-16.10" and .["aks-tpg-poc-01"].operatorVersion == "v4.5.0"' \
  "$TMP/work/cmap.json" >/dev/null && ok "day0: an unquoted 16.10 stays postgres-16.10; 4.5.0 becomes v4.5.0" || bad "day0 normalize" "$(cat "$TMP/work/cmap.json")"
vp day0 P_CLUSTER_MAP='{"aks-tpg-poc-01":{"operatorVersion":"v4.5.0","instances":{"orders-db":{"postgresVersion":"17.6","highAvailability":true}}}}' P_PUSH_MODE=pr
valid "day0: a JSON clusterMap is valid"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01:
  operatorVersion: v4.5.0
  instances:
    orders_db: {postgresVersion: "17.6", highAvailability: true}' P_PUSH_MODE=direct
invalid "day0: orders_db is refused with a valid name suggested" "clusterMap.aks-tpg-poc-01.instances.orders_db" "(for example orders-db)"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-1:
  operatorVersion: v4.5.0
  instances:
    orders-db: {postgresVersion: "17.6", highAvailability: true}' P_PUSH_MODE=direct
invalid "day0: an unregistered cluster is refused with the closest registered one" "cluster 'aks-tpg-poc-1' is not registered (did you mean aks-tpg-poc-01?)"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01:
  operatorVersion: v4.5.0
  instances:
    orders-db: {postgresVerison: "17.6", highAvailability: true}' P_PUSH_MODE=direct
invalid "day0: a misspelled key is refused with the closest key" "unknown key postgresVerison (did you mean postgresVersion?)"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01:
  instances:
    orders-db: {operatorVersion: v4.5.0, postgresVersion: "17.6", highAvailability: true}' P_PUSH_MODE=direct
invalid "day0: operatorVersion on an instance is refused (a cluster key)" "operatorVersion is a cluster key: put it next to instances" "operatorVersion is required"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01:
  instances:
    orders-db: {postgresVersion: "17.6", highAvailability: true}' P_OPERATOR_VERSION=v4.5.0 P_PUSH_MODE=direct
valid "day0: the operatorVersion input is the default of a cluster without the key"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01:
  operatorVersion: v4.5.0
  instances:
    orders-db: {postgresVersion: "17.6", replicas: 2, highAvailability: yes}' P_PUSH_MODE=direct
invalid "day0: a key of another workflow and a bad boolean are refused" "replicas: not used by tpg-day0 (used by tpg-scale-instance)" "'yes' must be true or false"
vp day0 P_CLUSTER_MAP="$MAP_OK" P_CLUSTERS=all P_PUSH_MODE=direct
invalid "day0: clusterMap and clusters together are refused" "clusterMap and clusters cannot be used together"
vp day0 P_CLUSTERS=all P_INSTANCES=orders-db P_HA=true P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6 P_PUSH_MODE=direct
valid "day0: the list inputs without clusterMap stay valid"
vp day0 P_CLUSTER_MAP='just words' P_PUSH_MODE=direct
invalid "day0: a clusterMap that is not a mapping is refused" "clusterMap must be a mapping"

# ---- tpg-scale-instance
vp scale P_CLUSTERS=aks-tpg-poc-01,aks-tpg-poc-02 P_INSTANCES=orders-db,billing-db P_REPLICAS=2 P_PUSH_MODE=direct
valid "scale: clusters and instances lists are valid"
vp scale P_CLUSTERS=all P_INSTANCES=orders-db P_REPLICAS=2 P_PUSH_MODE=direct
invalid "scale: clusters=all is refused" "clusters does not accept all"
vp scale P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {}}}' P_PUSH_MODE=direct
invalid "scale: replicas is required (map key or input)" "orders-db: replicas is required (the map key replicas or the workflow input replicas)"
vp scale P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {replicas: 3, enableHAIfNeeded: false}, billing-db: {}}}' P_REPLICAS=1 P_PUSH_MODE=direct
valid "scale: the replicas input is the default of an instance without the key"
vp scale P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {billing-db: {replicas: 2, enableHAIfNeeded: false}}}' P_PUSH_MODE=direct
invalid "scale: replicas 2 with enableHAIfNeeded=false on a single-node instance fails at validation" \
  "aks-tpg-poc-01/billing-db: replicas 2 needs highAvailability, and billing-db is declared a single node" "(HA_DISABLED)"
vp scale P_CLUSTERS=aks-tpg-poc-01 P_INSTANCES=orders-db,billing-db P_REPLICAS=1 P_ENABLE_HA=false P_PUSH_MODE=direct
invalid "scale inputs: enableHAIfNeeded=false names only the single-node instance" "aks-tpg-poc-01/billing-db: replicas 1 needs highAvailability"
grep -q "orders-db: replicas" <<<"$OUT" && bad "scale inputs: the HA instance is not refused" "$OUT" || ok "scale inputs: the HA instance is not refused"
vp scale P_CLUSTERS=aks-tpg-poc-01 P_INSTANCES=billing-db P_REPLICAS=0 P_ENABLE_HA=false P_PUSH_MODE=direct
valid "scale inputs: replicas=0 with enableHAIfNeeded=false is valid (a single node stays one)"
# maxReadReplicas, rolloutMode, maxParallel (Round 14)
vp scale P_CLUSTERS=aks-tpg-poc-01 P_MAX_READ_REPLICAS=5 P_PUSH_MODE=direct
valid "scale: maxReadReplicas alone (no instances) is valid"
vp scale P_CLUSTERS=aks-tpg-poc-01 P_PUSH_MODE=direct
invalid "scale: neither instances nor maxReadReplicas is refused" "instances is mandatory"
vp scale P_CLUSTERS=aks-tpg-poc-01 P_REPLICAS=2 P_MAX_READ_REPLICAS=5 P_PUSH_MODE=direct
invalid "scale: replicas without instances is refused" "replicas needs instances"
vp scale P_CLUSTERS=aks-tpg-poc-01 P_MAX_READ_REPLICAS=0 P_PUSH_MODE=direct
invalid "scale: maxReadReplicas 0 is refused" "maxReadReplicas must be a positive integer"
vp scale P_CLUSTERS=aks-tpg-poc-01 P_MAX_READ_REPLICAS=1 P_PUSH_MODE=direct
invalid "scale: a cap below a declared readReplicas fails at validation" \
  "aks-tpg-poc-01: maxReadReplicas 1 is below the read replicas of orders-db=2 (MAX_BELOW_CURRENT)"
vp scale P_CLUSTERS=aks-tpg-poc-01 P_INSTANCES=orders-db P_REPLICAS=1 P_MAX_READ_REPLICAS=1 P_PUSH_MODE=direct
valid "scale: the same cap is valid when the run scales the instance down to it"
vp scale P_CLUSTER_MAP='aks-tpg-poc-01: {maxReadReplicas: 1}' P_PUSH_MODE=direct
invalid "scale map: a cap below a declared readReplicas fails at validation" "orders-db=2 (MAX_BELOW_CURRENT)"
vp scale P_CLUSTER_MAP='aks-tpg-poc-01: {maxReadReplicas: 1, instances: {orders-db: {replicas: 0}}}' P_PUSH_MODE=direct
valid "scale map: a cap with the instance scaled down in the same entry is valid"
vp scale P_CLUSTER_MAP='aks-tpg-poc-01: {}' P_PUSH_MODE=direct
invalid "scale map: a cluster with neither instances nor maxReadReplicas is refused" "nothing to do on this cluster"
vp scale P_CLUSTER_MAP='aks-tpg-poc-01: {}' P_MAX_READ_REPLICAS=4 P_PUSH_MODE=direct
valid "scale map: the maxReadReplicas input fills a cluster entry without instances"
vp scale P_CLUSTER_MAP='aks-tpg-poc-02: {maxReadReplicas: 4}' P_PUSH_MODE=direct
invalid "scale map: a cap for a cluster without a fleet.yaml entry is refused" "aks-tpg-poc-02: maxReadReplicas is written to clusters.aks-tpg-poc-02.cluster"
vp scale P_CLUSTERS=aks-tpg-poc-01 P_INSTANCES=orders-db P_REPLICAS=1 P_ROLLOUT_MODE=waves P_MAX_PARALLEL=0 P_PUSH_MODE=direct
invalid "scale: rolloutMode and maxParallel are checked" "rolloutMode" "maxParallel must be a positive integer"

# ---- tpg-backup and tpg-backup-retention
vp backup P_CLUSTERS=all
valid "backup: clusters=all (the CronWorkflows) is valid"
vp backup P_CLUSTER_MAP='aks-tpg-poc-02: {instances: {orders-db: {backupType: incremental, backupTimeoutSeconds: 600}}}'
valid "backup: a clusterMap with backupType and backupTimeoutSeconds is valid"
vp backup P_CLUSTER_MAP='aks-tpg-poc-02: {instances: {orders-db: {backupType: weekly}}}'
invalid "backup: an unknown backupType is refused" "'weekly' must be one of full, incremental, differential"
vp backup-retention P_CLUSTER_MAP='aks-tpg-poc-02: {instances: {orders-db: {retentionDays: 0}}}'
invalid "backup-retention: retentionDays 0 is refused" "'0' must be a positive integer"

# ---- tpg-delete-instance and tpg-delete-apps
vp delete-instance P_CLUSTERS=aks-tpg-poc-01,aks-tpg-poc-02 P_INSTANCES=orders-db,billing-db P_CONFIRM=billing-db,orders-db
valid "delete-instance: confirm repeats the instances (any order)"
vp delete-instance P_CLUSTERS=aks-tpg-poc-01 P_INSTANCES=orders-db P_CONFIRM=orders
invalid "delete-instance: a confirm that differs is refused" "confirm must repeat the instances value"
vp restore P_SOURCE_CLUSTER=aks-tpg-poc-01 P_INSTANCE=orders-db P_MODE=backup P_BACKUP_NAME=orders-db-full-1
invalid "restore: mode=backup without targetInstance is refused before the run" "mode=backup restores only inside the source namespace" "targetInstance=orders-db"
vp restore P_SOURCE_CLUSTER=aks-tpg-poc-01 P_INSTANCE=orders-db P_MODE=backup P_BACKUP_NAME=orders-db-full-1 P_TARGET_INSTANCE=orders-db P_CONFIRM=orders-db
valid "restore: mode=backup in place with confirm is valid"
vp delete-apps P_CLUSTERS=aks-tpg-poc-01,aks-tpg-poc-02 P_APPS='{"aks-tpg-poc-01":["tpg-operator"],"aks-tpg-poc-02":["tpg-operator"]}' P_CONFIRM=aks-tpg-poc-02,aks-tpg-poc-01 P_DRY_RUN=true P_PURGE_PVCS=false P_PURGE_NS=false P_PUSH_MODE=direct
valid "delete-apps: confirm repeats the clusters in any order"
vp delete-instance P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {purgeNamespace: true}}}' P_CONFIRM=aks-tpg-poc-01
invalid "delete-instance: purgeNamespace without purgePvcs is refused per instance" "orders-db: purgeNamespace=true needs purgePvcs=true"
vp delete-apps P_CLUSTER_MAP='aks-tpg-poc-03:
  deleteOperator: true
  instances:
    orders-db: {purgePvcs: true, purgeNamespace: true, finalBackup: required}
aks-tpg-poc-02:
  deleteOperator: true
  instances: {}' P_CONFIRM=aks-tpg-poc-02,aks-tpg-poc-03 P_DRY_RUN=true P_PUSH_MODE=direct
valid "delete-apps: a clusterMap with an operator-only cluster is valid"
vp delete-apps P_CLUSTER_MAP='aks-tpg-poc-03: {instances: {orders-db: {}}}' P_CONFIRM=aks-tpg-poc-03 P_DRY_RUN=true P_PUSH_MODE=direct
invalid "delete-apps: purgePvcs has no default" "orders-db: purgePvcs is required"
vp delete-apps P_CLUSTER_MAP='aks-tpg-poc-03: {instances: {}}' P_CONFIRM=aks-tpg-poc-03 P_DRY_RUN=true P_PUSH_MODE=direct
invalid "delete-apps: a cluster with nothing to delete is refused" "nothing to do on this cluster"

# ---- tpg-patch (Round 14: one local file per kind, contents in patchFiles)
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
PG_OK="$(b64 $'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  logLevel: Debug\n')"
VAL_OK="$(b64 $'backup:\n  fullRetention: 6\n')"
OP_OK="$(b64 $'resources:\n  limits: {cpu: 500m, memory: 300Mi}\nenableSecurityContext: true\n')"
vp patch P_CLUSTER_MAP='aks-tpg-poc-01:
  operatorValuesPatchFilePath: ./op.yaml
  instances:
    orders-db: {postgresPatchFilePath: pg.yaml, valuesPatchFilePath: vals/backup.yaml}' P_PUSH_MODE=direct \
  P_PATCH_FILES="{\"op.yaml\": \"${OP_OK}\", \"./pg.yaml\": \"${PG_OK}\", \"vals/backup.yaml\": \"${VAL_OK}\"}"
valid "patch: a clusterMap with one file per kind, contents in patchFiles (./ ignored on either side), is valid"
vp patch P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {postgresPatchFilePath: [a.yaml, b.yaml]}}}' P_PUSH_MODE=direct
invalid "patch: a list of files is refused (one current file per kind)" "one file path is expected"
vp patch P_CLUSTER_MAP='aks-tpg-poc-01: {operatorManifestPatchFilePath: m.yaml}' P_PUSH_MODE=direct
invalid "patch: operatorManifestPatchFilePath is gone" "unknown key operatorManifestPatchFilePath"
vp patch P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {postgresPatchFilePath: ../mem.yaml}}}' P_PUSH_MODE=direct
invalid "patch: a path outside the current directory is refused" "must be the relative path of one .yaml or .yml file"
vp patch P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {valuesPatchFilePath: mem.yaml}}}' P_PUSH_MODE=direct
invalid "patch: a file whose contents did not come is refused" "mem.yaml: its contents are not in patchFiles"
vp patch P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {}}}' P_PUSH_MODE=direct
invalid "patch: an instance without any patch file is refused" "no postgresPatchFilePath or valuesPatchFilePath"
vp patch P_CLUSTERS=all P_OPERATOR_VALUES_PATCH=op.yaml P_PUSH_MODE=direct P_PATCH_FILES="{\"op.yaml\": \"${OP_OK}\"}"
valid "patch: an operator values patch on every cluster (inputs) is valid"
vp patch P_CLUSTERS=all P_PUSH_MODE=direct
invalid "patch: no patch file at all is refused" "no patch file"
# 1a: the file must fit the input it is passed to
vp patch P_CLUSTERS=aks-tpg-poc-01 P_INSTANCES=orders-db P_VALUES_PATCH=pg.yaml P_PUSH_MODE=direct P_PATCH_FILES="{\"pg.yaml\": \"${PG_OK}\"}"
invalid "patch 1a: a Postgres manifest passed as valuesPatchFilePath is refused" \
  "valuesPatchFilePath: pg.yaml: is a Kubernetes manifest (kind: Postgres), not chart values" "pass it as postgresPatchFilePath"
vp patch P_CLUSTERS=aks-tpg-poc-01 P_INSTANCES=orders-db P_POSTGRES_PATCH=v.yaml P_PUSH_MODE=direct P_PATCH_FILES="{\"v.yaml\": \"${VAL_OK}\"}"
invalid "patch 1a: chart values passed as postgresPatchFilePath are refused" "holds chart values (backup), not a Postgres manifest: pass it as valuesPatchFilePath"
vp patch P_CLUSTERS=aks-tpg-poc-01 P_INSTANCES=orders-db P_VALUES_PATCH=v.yaml P_PUSH_MODE=direct \
  P_PATCH_FILES="{\"v.yaml\": \"$(b64 $'instance:\n  storageSze: 30Gi\n')\"}"
invalid "patch 1a: an unknown chart value is named with the closest key" "instance.storageSze is not a value of the tpg-instance chart (did you mean storageSize?)"
vp patch P_CLUSTERS=aks-tpg-poc-01 P_INSTANCES=orders-db P_POSTGRES_PATCH=p.yaml P_PUSH_MODE=direct \
  P_PATCH_FILES="{\"p.yaml\": \"$(b64 $'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  logLevl: Debug\n')\"}"
invalid "patch 1a: a field the Postgres CRD does not have is refused" "spec.logLevl is not a field of the Postgres resource (did you mean logLevel?)"
vp patch P_CLUSTERS=aks-tpg-poc-01 P_POSTGRES_PATCH= P_OPERATOR_VALUES_PATCH=o.yaml P_PUSH_MODE=direct \
  P_PATCH_FILES="{\"o.yaml\": \"$(b64 $'operatorImage: reg.example.com/postgres-operator:v4.5.0\nnodeSelector: {pool: system}\nresources: {limits: {gpu: 1}}\n')\"}"
invalid "patch 1b: operator keys outside the allow-list are refused" "nodeSelector cannot be patched" "resources.limits.gpu cannot be set (only cpu and memory)"
vp patch P_CLUSTERS=aks-tpg-poc-01 P_OPERATOR_VALUES_PATCH=o.yaml P_PUSH_MODE=direct \
  P_PATCH_FILES="{\"o.yaml\": \"$(b64 $'apiVersion: apps/v1\nkind: Deployment\nmetadata: {name: postgres-operator}\n')\"}"
invalid "patch 1b: a manifest as operator values is refused" "operator manifest patches were removed in Round 14"
vp patch P_CLUSTERS=aks-tpg-poc-01 P_OPERATOR_VALUES_PATCH=o.yaml P_PUSH_MODE=direct \
  P_PATCH_FILES="{\"o.yaml\": \"${OP_OK}\", \"extra.yaml\": \"${VAL_OK}\"}"
invalid "patch: patchFiles may carry only the named files" "patchFiles carries extra.yaml, which no path input or clusterMap key names"
vp patch P_CLUSTERS=aks-tpg-poc-01 P_INSTANCES=orders-db P_VALUES_PATCH=charts/tpg-instance/patches/backup-ab12c.yaml P_PATCH_MODE=clear P_PUSH_MODE=direct
valid "patch: patchMode=clear names the current file and needs no contents"
vp patch P_CLUSTERS=aks-tpg-poc-01 P_INSTANCES=orders-db P_VALUES_PATCH=v.yaml P_PATCH_MODE=append P_PUSH_MODE=direct P_PATCH_FILES="{\"v.yaml\": \"${VAL_OK}\"}"
invalid "patch: the Round 11 patchMode values are refused" "patchMode must be one of: apply clear (got 'append')"
vp patch P_CLUSTERS=aks-tpg-poc-01 P_INSTANCES=orders-db P_VALUES_PATCH=v.yaml P_PUSH_MODE=direct P_PATCH_FILES="{\"v.yaml\": \"$(b64 $'backup: [x\n')\"}"
invalid "patch: a file that is not YAML is refused" "v.yaml: not valid YAML"

# ---- tpg-upgrade
vp upgrade P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.1, instances: {orders-db: {postgresVersion: "17.7", allowMajor: true}}}' P_PUSH_MODE=direct
valid "upgrade: operator and Postgres in one clusterMap is valid"
[[ "$(cat /tmp/approval)" == "true" ]] && ok "upgrade: allowMajor in the map asks for batch approval" || bad "upgrade approval $(cat /tmp/approval)"
vp upgrade P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {}}}' P_PUSH_MODE=direct
invalid "upgrade: a map without versions is refused" "nothing to upgrade"
vp upgrade P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {}}}' P_COMPONENT=postgres P_TARGET_VERSION=17.7 P_PUSH_MODE=direct
valid "upgrade: component=postgres with targetVersion as the default of every instance"
vp upgrade P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.1}' P_TARGET_VERSION=4.5.1 P_PUSH_MODE=direct
invalid "upgrade: targetVersion without component is refused with clusterMap" "targetVersion needs component=operator or component=postgres with clusterMap"

# ---- Round 12: exposure and network policy values (list, map and CIDR types, null)
D0='P_CLUSTERS=aks-tpg-poc-01 P_INSTANCES=orders-db P_HA=true P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6 P_PUSH_MODE=direct'
# shellcheck disable=SC2086
vp day0 $D0 P_EXPOSURE=internalLoadBalancer P_INTERNAL_LB_SUBNET=apps-subnet P_ALLOWED_SOURCE_RANGES=10.0.0.0/8,192.168.10.0/24 \
  P_SERVICE_ANNOTATIONS='service.beta.kubernetes.io/azure-dns-label-name: orders' P_NETWORK_POLICY=baseline \
  P_INGRESS_FROM_NAMESPACES=app,batch P_INGRESS_FROM_POD_LABELS='{"role":"api"}' P_EGRESS_TO_FQDNS='api.example.com,*.example.org'
valid "day0 inputs: exposure, subnet, CIDRs, a YAML annotation map, baseline policy with rules"
# shellcheck disable=SC2086
vp day0 $D0 P_EXPOSURE=nodePort P_ALLOWED_SOURCE_RANGES=10.0.0.1/8 P_EGRESS_TO_FQDNS='http://x' P_NETWORK_POLICY=baseline
invalid "day0 inputs: unknown exposure, CIDR with host bits, URL as a host name" "exposure" "'10.0.0.1/8' must be a CIDR such as 10.20.0.0/16 (host bits zero)" "'http://x' must be a host name"
# shellcheck disable=SC2086
vp day0 $D0 P_EXPOSURE=internalLoadBalancer P_INTERNAL_LB_SUBNET=AKS-Apps_Subnet.01
valid "day0 inputs: an Azure subnet name with uppercase, '_' and '.'"
# shellcheck disable=SC2086
vp day0 $D0 P_EXPOSURE=internalLoadBalancer P_INTERNAL_LB_SUBNET='apps/subnet'
invalid "day0 inputs: a subnet name with '/' is refused" "must be an Azure subnet name"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6", highAvailability: true, exposure: internalLoadBalancer, internalLoadBalancerSubnet: AKS_Apps}}}' P_PUSH_MODE=direct
valid "day0 clusterMap: internalLoadBalancerSubnet takes an Azure name"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6", highAvailability: true, internalLoadBalancerSubnet: -apps}}}' P_PUSH_MODE=direct
invalid "day0 clusterMap: an Azure name must start with a letter or digit" "must be an Azure resource name"
# shellcheck disable=SC2086
vp day0 $D0 P_INGRESS_FROM_NAMESPACES=app
invalid "day0 inputs: a rule without networkPolicy=baseline" "the ingressFrom*/egressTo* rules need networkPolicy=baseline"
# shellcheck disable=SC2086
vp day0 $D0 P_SERVICE_ANNOTATIONS='just words'
invalid "day0 inputs: an annotation input that is not a map" "serviceAnnotations must be a map (YAML or JSON)"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01:
  operatorVersion: v4.5.0
  instances:
    orders-db: {postgresVersion: "17.6", highAvailability: true, exposure: loadBalancer, allowedSourceRanges: [203.0.113.0/24],
                networkPolicy: baseline, ingressFromCidrs: [203.0.113.0/24], ingressFromPodLabels: {app.kubernetes.io/name: api}}' P_PUSH_MODE=direct
valid "day0 clusterMap: exposure and policy keys as YAML lists and maps"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01:
  operatorVersion: v4.5.0
  instances:
    orders-db: {postgresVersion: "17.6", highAvailability: null, ingressFromNamespaces: [], serviceAnnotations: {}}' P_PUSH_MODE=direct
invalid "day0 clusterMap: null and empty lists or maps are refused with the fix named" \
  "highAvailability: null is not a value; remove the key to use the default" \
  "ingressFromNamespaces: a non-empty list is expected (remove the key instead of setting it empty)" \
  "serviceAnnotations: a non-empty mapping is expected"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6", highAvailability: true, ingressFromNamespaces: [App_1]}}}' P_PUSH_MODE=direct
invalid "day0 clusterMap: a namespace that is not a DNS label" "'App_1' must be a lowercase DNS label"

# ---- Round 13: HA and readReplicas, operator backup schedules, FerretDB (D69 to D71)
# Round 13 addendum: the two depend on each other, checked where they are set
# shellcheck disable=SC2086
vp day0 P_CLUSTERS=aks-tpg-poc-01 P_INSTANCES=orders-db P_HA=false P_READ_REPLICAS=2 P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6 P_PUSH_MODE=direct
invalid "day0 inputs: readReplicas 2 with highAvailability=false is refused" "inputs: readReplicas 2 needs highAvailability=true"
vp day0 P_CLUSTERS=aks-tpg-poc-01 P_INSTANCES=orders-db P_HA=false P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6 P_PUSH_MODE=direct
valid "day0 inputs: highAvailability=false without readReplicas is a single node"
vp day0 P_CLUSTERS=aks-tpg-poc-01 P_INSTANCES=orders-db P_HA=true P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6 P_PUSH_MODE=direct
valid "day0 inputs: highAvailability=true without readReplicas means 1"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-02: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "16.9", highAvailability: false, readReplicas: 2}}}' P_HA=true P_PUSH_MODE=direct
invalid "day0 clusterMap: an entry with highAvailability false and readReplicas 2 is refused" \
  "clusterMap.aks-tpg-poc-02.instances.orders-db: readReplicas 2 needs highAvailability=true"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6"}, audit-db: {postgresVersion: "17.6", highAvailability: false}}}' P_HA=true P_READ_REPLICAS=3 P_PUSH_MODE=direct
valid "day0 clusterMap: the readReplicas input does not apply to an entry that sets highAvailability false"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6", readReplicas: 2}}}' P_HA=false P_PUSH_MODE=direct
invalid "day0 clusterMap: an entry readReplicas with the highAvailability=false input is refused" \
  "clusterMap.aks-tpg-poc-01.instances.orders-db: readReplicas 2 needs highAvailability=true"
vp create-instance P_CLUSTERS=aks-tpg-poc-01 P_INSTANCES=docs-db P_HA=false P_READ_REPLICAS=1 P_POSTGRES_VERSION=17.6 P_PUSH_MODE=direct
invalid "create-instance inputs: readReplicas 1 with highAvailability=false is refused" "inputs: readReplicas 1 needs highAvailability=true"
# shellcheck disable=SC2086
vp day0 $D0 P_READ_REPLICAS=0
invalid "day0 inputs: highAvailability=true with readReplicas 0 is refused" "inputs: highAvailability=true needs readReplicas 1 or more"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6", highAvailability: true, readReplicas: 0}, audit-db: {postgresVersion: "17.6", highAvailability: false, readReplicas: 0}}}' P_PUSH_MODE=direct
invalid "day0 clusterMap: readReplicas 0 with highAvailability true is refused for that instance only" \
  "clusterMap.aks-tpg-poc-01.instances.orders-db: highAvailability=true needs readReplicas 1 or more"
grep -q "audit-db" <<<"$OUT" && bad "day0 clusterMap: a single node (false, 0) is accepted" "$OUT" || ok "day0 clusterMap: a single node (false, 0) is accepted"
# shellcheck disable=SC2086
vp day0 $D0 P_BACKUP_SCHEDULE=operator P_OPERATOR_FULL_SCHEDULE='0 1 * * 0' P_OPERATOR_INCR_SCHEDULE=''
valid "day0 inputs: backupSchedule=operator with a full schedule only"
# shellcheck disable=SC2086
vp day0 $D0 P_BACKUP_SCHEDULE=operator P_OPERATOR_FULL_SCHEDULE='every sunday'
invalid "day0 inputs: a full schedule that is not cron" "operatorFullSchedule must be a cron schedule of 5 fields"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6", highAvailability: true, backupSchedule: operator, operatorFullSchedule: "30 2 * * 6", operatorIncrementalSchedule: none}}}' P_PUSH_MODE=direct
valid "day0 clusterMap: operator schedules per instance (incremental none)"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6", highAvailability: true, operatorFullSchedule: "0 0 * *"}}}' P_PUSH_MODE=direct
invalid "day0 clusterMap: a cron with 4 fields" "operatorFullSchedule: '0 0 * *' must be a cron schedule of 5 fields"
# shellcheck disable=SC2086
vp day0 $D0 P_FERRET=true P_FERRET_REPLICAS=2 P_FERRET_RO_REPLICAS=1 P_FERRET_EXPOSURE=internalLoadBalancer P_FERRET_SECRET=orders-db-app-user-db-secret
valid "day0 inputs: FerretDB with read-only proxies on an HA instance"
vp day0 P_CLUSTERS=aks-tpg-poc-01 P_INSTANCES=orders-db P_HA=false P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6 P_PUSH_MODE=direct \
  P_FERRET=true P_FERRET_RO_REPLICAS=1
invalid "day0 inputs: read-only FerretDB proxies on a single node" "ferretReadOnlyReplicas 1 needs highAvailability=true"
# shellcheck disable=SC2086
vp day0 $D0 P_FERRET=yes P_FERRET_REPLICAS=0 P_FERRET_SECRET=Bad_Name
invalid "day0 inputs: FerretDB input types" "ferret must be true or false" "ferretReplicas must be a positive integer" "ferretSecretName 'Bad_Name' must be a Kubernetes object name"
vp day0 P_CLUSTERS=aks-tpg-poc-01 P_INSTANCES=orders-db P_HA=false P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6 P_PUSH_MODE=direct \
  P_FERRET_RO_REPLICAS=1
invalid "day0 inputs: read-only FerretDB proxies on a single node with ferret empty (same rule as the admission policy)" "ferretReadOnlyReplicas 1 needs highAvailability=true"
vp create-instance P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {docs-db: {postgresVersion: "17.6", highAvailability: false, ferret: true, ferretReadOnlyReplicas: 2}}}' P_PUSH_MODE=direct
invalid "create-instance clusterMap: read-only FerretDB proxies need highAvailability" "clusterMap.aks-tpg-poc-01.instances.docs-db: ferretReadOnlyReplicas 2 needs highAvailability=true"
vp create-instance P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {docs-db: {postgresVersion: "17.6", highAvailability: true, ferret: true, ferretExposure: nodePort}}}' P_PUSH_MODE=direct
invalid "create-instance clusterMap: ferretExposure is an enum" "ferretExposure: 'nodePort' must be one of clusterIP, internalLoadBalancer, loadBalancer"

# ---- tpg-create-instance
vp create-instance P_CLUSTERS=aks-tpg-poc-01,aks-tpg-poc-02 P_INSTANCES=reports-db P_HA=false P_POSTGRES_VERSION=17.6 P_PUSH_MODE=direct
valid "create-instance: clusters and instances lists"
vp create-instance P_CLUSTERS=aks-tpg-poc-01 P_INSTANCES=reports-db P_PUSH_MODE=direct
invalid "create-instance: highAvailability and postgresVersion are mandatory without clusterMap" "highAvailability" "postgresVersion"
vp create-instance P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {reports-db: {postgresVersion: "17.6", highAvailability: false}}}
aks-tpg-poc-02: {instances: {audit-db: {highAvailability: true, readReplicas: 2}}}' P_POSTGRES_VERSION=16.10 P_PUSH_MODE=pr
valid "create-instance clusterMap: other instances per cluster, the input postgresVersion is the default"
vp create-instance P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {reports-db: {postgresVersion: "17.6", highAvailability: false}}}' P_PUSH_MODE=direct
invalid "create-instance clusterMap: operatorVersion is not a key of tpg-create-instance" "operatorVersion"
vp create-instance P_CLUSTERS=aks-tpg-poc-01 P_INSTANCES=reports-db P_HA=false P_POSTGRES_VERSION=17.6 P_PUSH_MODE=direct \
  P_POSTGRES_PATCH_FILES=debug.yaml P_PATCH_FILES="{\"debug.yaml\": \"$(b64 $'operatorImage: x/y:1\n')\"}"
invalid "create-instance: a file of the wrong kind is refused (1a)" "postgresPatchFilePath: debug.yaml: holds operator chart values: pass it as operatorValuesPatchFilePath"

# ---- tpg-network-policy
vp network-policy P_CLUSTERS=aks-tpg-poc-01 P_INSTANCES=orders-db P_NP_MODE=apply P_PUSH_MODE=direct P_INGRESS_FROM_NAMESPACES=app P_EGRESS_TO_CIDRS=10.50.0.0/16
valid "network-policy apply: rules as inputs"
vp network-policy P_CLUSTERS=aks-tpg-poc-01 P_INSTANCES=orders-db P_PUSH_MODE=direct
invalid "network-policy: mode is mandatory" "mode"
vp network-policy P_CLUSTERS=aks-tpg-poc-01 P_INSTANCES=orders-db P_NP_MODE=remove P_PUSH_MODE=direct P_INGRESS_FROM_NAMESPACES=app
invalid "network-policy remove: rule inputs are refused" "mode=remove deletes the whole policy: leave the rule inputs empty"
vp network-policy P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {ingressFromCidrs: [10.1.0.0/16]}}}' P_NP_MODE=remove P_PUSH_MODE=direct
invalid "network-policy remove: clusterMap rules are refused" "clusterMap may name the instances (and postgresVersion guards) but no rules"
vp network-policy P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {networkPolicy: none}}}' P_NP_MODE=update P_PUSH_MODE=direct
invalid "network-policy clusterMap: networkPolicy is a day0 and create-instance key only" "networkPolicy"

# ---- lib accessors
cat > "$TMP/acc.sh" <<ACC
export TPG_WORK="$TMP/acc"
source "$ROOT/workflows/scripts/lib.sh"
set +e
printf '%s|' "\$(cmap_ival aks-tpg-poc-01 orders-db storageSize 20Gi)" "\$(cmap_ival aks-tpg-poc-01 billing-db storageSize 20Gi)" \
  "\$(cmap_cval aks-tpg-poc-02 operatorVersion v0)" "\$(cmap_instances aks-tpg-poc-01 | paste -sd,)" "\$(cmap_clusters | paste -sd,)"
ACC
got="$(PATH="$TMP/bin:$PATH" P_CLUSTER_MAP="$MAP_OK" bash "$TMP/acc.sh" 2>/dev/null)"
[[ "$got" == "50Gi|20Gi|v4.5.0|billing-db,orders-db|aks-tpg-poc-01,aks-tpg-poc-02|" ]] \
  && ok "lib: map keys override, the input default applies, instances and clusters listed" || bad "lib accessors" "$got"
rm -rf "$TMP/acc"
got="$(PATH="$TMP/bin:$PATH" P_CLUSTER_MAP="" bash "$TMP/acc.sh" 2>/dev/null)"
[[ "$got" == "20Gi|20Gi|v0|||" ]] && ok "lib: without clusterMap every accessor returns the default" || bad "lib no map" "$got"

# ---- fleet-day0.sh: values and the version rule (dry run)
REPO="$TMP/repo"
mkdir -p "$REPO/clusters/_template"
cp "$ROOT/clusters/_template/"*.yaml "$REPO/clusters/_template/"
cat > "$REPO/clusters/fleet.yaml" <<'YAML'
clusters:
  aks-tpg-poc-01:
    operator: {version: v4.5.0}
    instances:
      orders-db: {instance: {postgresVersion: postgres-16.9}}
  aks-tpg-poc-02:
    operator: {version: v4.5.0}
    instances:
      orders-db: {instance: {postgresVersion: postgres-16.9}}
  aks-tpg-poc-03:
    operator: {version: v4.4.0}
YAML
# live state per cluster: operator image tag ("" = not installed) and running instances
cat > "$TMP/live.json" <<'JSON'
{"aks-tpg-poc-01": {"operator": "", "instances": {}},
 "aks-tpg-poc-02": {"operator": "v4.5.0", "instances": {"orders-db": "postgres-16.9"}},
 "aks-tpg-poc-03": {"operator": "v4.4.0", "instances": {}},
 "aks-tpg-poc-04": {"operator": "latest", "instances": {}}}
JSON
cat > "$TMP/day0-prelude.sh" <<PRELUDE
export TPG_WORK="$TMP/day0work"
source "$ROOT/workflows/scripts/lib.sh"
CMAP_KEYS="$ROOT/workflows/params/cluster-map-keys.yaml"
git_clone() { rm -rf "\$1"; cp -r "$REPO" "\$1"; }
record() { printf '%s %s %s %s\n' "\$1" "\$2" "\${3:-}" "\${4:-}" >> "$TMP/records"; printf '%s' "\$2" > /tmp/result; RESULT_RECORDED=1; }
record_entry() { printf '%s %s %s %s\n' "\$1" "\$2" "\${3:-}" "\${4:-}" >> "$TMP/records"; }
appset_refresh() { :; }
setting() { case "\$1" in backupCaBundle) printf '%s' "\${S_CA-PEM}" ;; acnsEnabled) printf false ;; esac; }
git_commit_push() { :; }
use_cluster() { CLUSTER="\$1"; }
tk() {
  local live; live="\$(jq -c --arg c "\$CLUSTER" '.[\$c]' "$TMP/live.json")"
  case "\$*" in
    *readyz*) return 0 ;;
    *"get deploy -A -o json"*)
      jq -c '{items: (if .operator == "" then [] else [{spec: {template: {spec: {containers: [{image: ("reg.example/postgres-operator:" + .operator)}]}}}}] end)}' <<<"\$live" ;;
    *"get postgres"*)
      local i; i="\$(sed -E 's/.*get postgres ([a-z0-9-]+).*/\1/' <<<"\$*")"
      local v; v="\$(jq -r --arg i "\$i" '.instances[\$i] // ""' <<<"\$live")"
      [[ -n "\$v" ]] || return 1
      [[ "\$*" == *jsonpath* ]] && printf '%s' "\$v"
      return 0 ;;
  esac
}
PRELUDE
sed "s#source /scripts/lib.sh#source $TMP/day0-prelude.sh#" "$ROOT/workflows/scripts/fleet-day0.sh" > "$TMP/fleet-day0.sh"
day0() {  # day0 CLUSTERS_JSON VAR=VALUE... -> planned fleet.yaml JSON in $FLEET, records in $TMP/records
  rm -rf "$TMP/day0work" "$TMP/records" /tmp/fleet.json; : > "$TMP/records"
  RC=0; OUT="$(env PATH="$TMP/bin:$PATH" P_DRY_RUN=true P_PUSH_MODE=direct "${@:2}" bash "$TMP/fleet-day0.sh" wf "$1" 2>&1)" || RC=$?
  FLEET="$(cat /tmp/fleet.json 2>/dev/null || echo '{}')"
}
day0 '["aks-tpg-poc-01","aks-tpg-poc-02","aks-tpg-poc-03"]' P_INSTANCES=orders-db P_HA=true \
  P_OPERATOR_VERSION=4.4.0 P_POSTGRES_VERSION=17.6
[[ "$RC" -eq 0 ]] && ok "item 8: the run goes ahead with a blocked cluster" || bad "item 8 rc" "$OUT"
jq -e '.clusters["aks-tpg-poc-01"].operator.version == "v4.4.0" and .clusters["aks-tpg-poc-01"].instances["orders-db"].instance.postgresVersion == "postgres-17.6"' <<<"$FLEET" >/dev/null \
  && grep -q "FLEET_OVERRIDDEN aks-tpg-poc-01 operator v4.5.0 -> v4.4.0 (not installed on the cluster)" <<<"$OUT" \
  && ok "item 8: nothing runs on aks-tpg-poc-01, so the input replaces the fleet.yaml versions (FLEET_OVERRIDDEN)" || bad "item 8 override" "$OUT"
grep -q "^block.aks-tpg-poc-02 BLOCKED DOWNGRADE_NOT_ALLOWED operator v4.5.0 runs on aks-tpg-poc-02" "$TMP/records" \
  && jq -e '.clusters["aks-tpg-poc-02"].operator.version == "v4.5.0"' <<<"$FLEET" >/dev/null \
  && ok "item 8: aks-tpg-poc-02 runs v4.5.0: v4.4.0 is BLOCKED (DOWNGRADE_NOT_ALLOWED) and fleet.yaml is kept" || bad "item 8 downgrade" "$(cat "$TMP/records")"
day0 '["aks-tpg-poc-02"]' P_INSTANCES=orders-db P_HA=true P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6
grep -q "^block.aks-tpg-poc-02 BLOCKED UPGRADE_REQUIRED orders-db runs postgres-16.9 on aks-tpg-poc-02: use tpg-upgrade component=postgres targetVersion=postgres-17.6 instances=orders-db" "$TMP/records" \
  && ok "item 8: a running instance on another version is BLOCKED with the tpg-upgrade command" || bad "item 8 instance" "$(cat "$TMP/records")"
day0 '["aks-tpg-poc-03"]' P_INSTANCES=orders-db P_HA=true P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6
grep -q "^block.aks-tpg-poc-03 BLOCKED UPGRADE_REQUIRED operator v4.4.0 runs on aks-tpg-poc-03: use tpg-upgrade component=operator targetVersion=v4.5.0" "$TMP/records" \
  && ok "item 8: a newer operator input on a running cluster is BLOCKED (UPGRADE_REQUIRED)" || bad "item 8 upgrade" "$(cat "$TMP/records")"
day0 '["aks-tpg-poc-04"]' P_INSTANCES=orders-db P_HA=true P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6
grep -q "^block.aks-tpg-poc-04 BLOCKED VERSION_UNKNOWN an operator runs on aks-tpg-poc-04 but its version cannot be read" "$TMP/records" \
  && ok "item 8: an operator whose version cannot be read is BLOCKED (VERSION_UNKNOWN)" || bad "item 8 unknown" "$(cat "$TMP/records")"
day0 '["aks-tpg-poc-02"]' P_INSTANCES=orders-db P_HA=true P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=16.9 P_STORAGE_SIZE=40Gi
jq -e '.clusters["aks-tpg-poc-02"].instances["orders-db"].instance.storageSize == "40Gi"' <<<"$FLEET" >/dev/null && ! grep -q '^block' "$TMP/records" \
  && ok "item 8: the versions the cluster runs are accepted and other inputs are written" || bad "item 8 same version" "$OUT $(cat "$TMP/records")"
day0 '[]' P_CLUSTER_MAP='aks-tpg-poc-01:
  operatorVersion: v4.5.0
  maxReadReplicas: 4
  instances:
    orders-db: {postgresVersion: "17.6", highAvailability: true, readReplicas: 4, cpu: "2", memory: 8Gi, enableSSL: true}
    reporting-db: {postgresVersion: "17.6", highAvailability: false, backupSchedule: none}' P_HA=true P_READ_REPLICAS=3
jq -e '.clusters["aks-tpg-poc-01"] as $c
  | $c.cluster.maxReadReplicas == 4
  and $c.instances["orders-db"].instance.resources.data.requests.cpu == "2" and $c.instances["orders-db"].instance.resources.data.limits.cpu == "2"
  and $c.instances["orders-db"].instance.resources.data.limits.memory == "8Gi"
  and $c.instances["orders-db"].instance.highAvailability.readReplicas == 4
  and $c.instances["orders-db"].backup.enableSSL == true
  and $c.instances["orders-db"].backup.caBundle == "@tpg-settings:backupCaBundle@"
  and ($c.instances["reporting-db"].backup | has("caBundle") | not)
  and $c.instances["reporting-db"].instance.highAvailability == {"enabled": false, "readReplicas": 0}
  and $c.instances["reporting-db"].backup.scheduled == false
  and $c.instances["reporting-db"].backup.enableSSL == false' <<<"$FLEET" >/dev/null \
  && ok "day0 clusterMap: every key lands on its fleet.yaml paths (cpu twice, no replicas without HA, backupSchedule none, caBundle as the tpg-settings placeholder with enableSSL only)" \
  || bad "day0 clusterMap write" "$(jq -c '.clusters["aks-tpg-poc-01"]' <<<"$FLEET") $OUT"
day0 '[]' P_CLUSTER_MAP='aks-tpg-poc-01:
  operatorVersion: v4.5.0
  instances:
    reporting-db: {postgresVersion: "17.6", highAvailability: false, readReplicas: 2}' P_HA=true
grep -q "result.git FAILED INVALID_INPUT .*aks-tpg-poc-01/reporting-db: readReplicas 2 needs highAvailability=true" "$TMP/records" \
  && ok "day0 backstop: fleet-day0.sh refuses readReplicas 2 with highAvailability false (no silent 0)" || bad "day0 backstop rr" "$(cat "$TMP/records")"
day0 '[]' P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6", highAvailability: true, readReplicas: 5}}}'
[[ "$RC" -ne 0 ]] && grep -q "readReplicas 5 exceeds maxReadReplicas 3" "$TMP/records" \
  && ok "day0 clusterMap: readReplicas above maxReadReplicas fails the step" || bad "day0 max" "$(cat "$TMP/records") $OUT"

echo
echo "tests/cluster-map: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
