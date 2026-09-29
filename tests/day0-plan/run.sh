#!/usr/bin/env bash
# Day 0 and tpg-create-instance planning (design decisions D60 to D66):
#   fleet-day0.sh     the plan: nothing pushed, per-instance outcomes in create
#                     mode, the CA bundle for enableSSL, exposure and network keys
#   day0-precheck.sh  ownership from the Argo CD Application's resource list
#                     (the CRDs without a tracking annotation are MANAGED),
#                     ORPHAN_CRD, OPERATOR_NOT_INSTALLED, HA_NODES_EXCEED_ZONES,
#                     AZURE_BACKUP_UNSUPPORTED
#   fleet-commit.sh   only PASSED or MANAGED clusters are written;
#                     FLEET_CHANGED_DURING_RUN
#   blocked-gate.sh   the run fails when anything was BLOCKED
#   operator-upgrade.sh  a declared but absent instance is left out (warning);
#                     an API error is not taken for an absent instance
#   discover.sh       an instance or cluster the plan blocked is left out; the
#                     backup scheduler and FerretDB as the chart sees them
#                     (values patch files included, D70, D71)
#   Round 13 (D69 to D72): highAvailability=true with readReplicas 0 and read-only
#                     FerretDB proxies without HA are refused; backupSchedule=operator
#                     and ferret write their keys; FERRET_VERSION_UNSUPPORTED,
#                     FERRET_CRD_MISSING, FERRET_EXTENSION_REQUIRED
#
# Runs the scripts with the real lib.sh, clustermap.py and chart, and stubs for
# Git, the run ConfigMap, the Argo CD API and the target cluster.
# Requires: bash 4, python3, jq, yq (mikefarah), helm; skipped without them.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
for t in python3 jq yq helm; do command -v "$t" >/dev/null || { echo "SKIP tests/day0-plan: $t not installed" >&2; exit 0; }; done
yq --version 2>&1 | grep -q mikefarah || { echo "SKIP tests/day0-plan: yq is not mikefarah yq v4" >&2; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/       | /' | tail -15; FAIL=$((FAIL + 1)); }

REPO="$TMP/repo"
mkdir -p "$REPO/clusters"
cp -r "$ROOT/charts" "$REPO/"
cp -r "$ROOT/clusters/_template" "$REPO/clusters/"
P="$REPO/charts/tpg-instance/patches"
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  storageClassName: premium-fast\n' > "$P/sc.yaml"
printf 'kind: Postgres\nspec:\n  highAvailability: {enabled: false}\n' > "$P/ha.yaml"
printf 'instance:\n  walStorageSize: 30Gi\nbackup:\n  fullRetention: 9\n' > "$P/vals.yaml"
cat > "$TMP/fleet.base.yaml" <<'YAML'
clusters:
  c1:
    operator: {version: v4.5.0}
    instances:
      orders-db: {instance: {postgresVersion: postgres-17.6, highAvailability: {enabled: true, readReplicas: 1}}, backup: {enableSSL: false}}
YAML

# ---- stubs. Scenario variables (environment of each run):
#   S_OPERATOR   none | ours | foreign     operator Deployment on the target
#   S_TRACKED    yes | no                  tracking annotation on the operator Deployment and the instances
#   S_CRD_TRACKED yes | no                 tracking annotation on the Postgres CRDs (default: S_TRACKED)
#   S_APPRES     yes | no                  the operator Application lists the CRDs and the Deployment
#   S_RUNNING    instances that run on the target (space separated)
#   S_ZONES      zones of the data pool, one Ready node per zone (default 3)
#   S_AZURE      yes | nocab | no          spec.storage.azure in the backup location CRD
#   S_CRDS       yes | no                  the Postgres CRDs exist
#   S_API_ERR    instances whose Postgres read fails with a timeout (not NotFound)
#   S_CA         tpg-settings backupCaBundle (empty: not set)
#   S_ACNS       tpg-settings acnsEnabled
#   S_FERRET_CRD yes | no                  the PostgresFerretDocumentDB CRD exists
cat > "$TMP/prelude.sh" <<PRELUDE
export TPG_WORK="$TMP/work"
source "$ROOT/workflows/scripts/lib.sh"
CMAP_KEYS="$ROOT/workflows/params/cluster-map-keys.yaml"
set +e
git_clone() { rm -rf "\$1"; cp -r "$REPO" "\$1"; cp "$TMP/fleet.yaml" "\$1/clusters/fleet.yaml"; }
record() { printf '%s|%s|%s|%s\n' "\$1" "\$2" "\${3:-}" "\${4:-}" >> "$TMP/records"; printf '%s' "\$2" > "$TMP/result"; RESULT_RECORDED=1; }
record_entry() { printf '%s|%s|%s|%s\n' "\$1" "\$2" "\${3:-}" "\${4:-}" >> "$TMP/records"; }
_last() { grep -F "\$1|" "$TMP/records" 2>/dev/null | tail -n1; }
record_status() { _last "\$1" | cut -d'|' -f2; }
run_data() {
  case "\$1" in
    inventory) cat "$TMP/inventory.json" ;;
    *) local l; l="\$(_last "\$1")"; [[ -n "\$l" ]] || return 0
       jq -cn --arg s "\$(cut -d'|' -f2 <<<"\$l")" --arg r "\$(cut -d'|' -f3 <<<"\$l")" --arg d "\$(cut -d'|' -f4- <<<"\$l")" '{status:\$s, reason:\$r, detail:\$d}' ;;
  esac
}
run_records() {
  local out='{}' k l
  while IFS= read -r l; do
    k="\$(cut -d'|' -f1 <<<"\$l")"
    out="\$(jq -c --arg k "\$k" --arg s "\$(cut -d'|' -f2 <<<"\$l")" --arg r "\$(cut -d'|' -f3 <<<"\$l")" \
      '.[\$k] = ({status:\$s, reason:\$r} | tojson)' <<<"\$out")"
  done < "$TMP/records"
  printf '%s' "\$out"
}
setting() { case "\$1" in backupCaBundle) printf '%s' "\${S_CA:-}" ;; acnsEnabled) printf '%s' "\${S_ACNS:-false}" ;; esac; }
appset_refresh() { :; }
git_commit_push() { cp "\$1/clusters/fleet.yaml" "$TMP/pushed.yaml"; printf '%s\n' "\${@:3}" > "$TMP/pushed-files"; PUSHED_REVISION=abc123def456; }
use_cluster() { CLUSTER="\$1"; }
app_resources() {
  [[ "\${S_APPRES:-no}" == yes ]] || return 0
  if [[ "\$1" == *-operator ]]; then
    printf 'apps/Deployment/tanzu-postgres-operator/postgres-operator\n'
    for c in postgres postgresbackuplocations; do printf 'apiextensions.k8s.io/CustomResourceDefinition//%s.sql.tanzu.vmware.com\n' "\$c"; done
  else
    local i="\${1#tpg-c1-}"; printf 'sql.tanzu.vmware.com/Postgres/pg-%s/%s\n' "\$i" "\$i"
  fi
}
_ann() { [[ "\${S_TRACKED:-no}" == yes ]] && printf '{"argocd.argoproj.io/tracking-id": "%s:x"}' "\$1" || printf '{}'; }
tk() {
  case "\$*" in
    *readyz*) return 0 ;;
    *"--dry-run=server"*) cat >> "$TMP/dryrun.yaml"; echo "created (server dry run)" ;;
    *"get deploy -A -o json"*)
      case "\${S_OPERATOR:-none}" in
        none) echo '{"items":[]}' ;;
        ours) printf '{"items":[{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"postgres-operator","namespace":"tanzu-postgres-operator","annotations":%s},"spec":{"template":{"spec":{"containers":[{"image":"reg/postgres-operator:v4.5.0"}]}}}}]}' "\$(_ann "tpg-c1-operator")" ;;
        foreign) echo '{"items":[{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"postgres-operator","namespace":"other"},"spec":{"template":{"spec":{"containers":[{"image":"reg/postgres-operator:v4.5.0"}]}}}}]}' ;;
      esac ;;
    *"get crd -o json"*)
      if [[ "\${S_CRDS:-yes}" == yes ]]; then
        local ca; ca="\$(S_TRACKED="\${S_CRD_TRACKED:-\${S_TRACKED:-no}}" _ann tpg-c1-operator)"
        printf '{"items":[{"apiVersion":"apiextensions.k8s.io/v1","kind":"CustomResourceDefinition","metadata":{"name":"postgres.sql.tanzu.vmware.com","annotations":%s}},{"apiVersion":"apiextensions.k8s.io/v1","kind":"CustomResourceDefinition","metadata":{"name":"postgresbackuplocations.sql.tanzu.vmware.com","annotations":%s}}]}' "\$ca" "\$ca"
      else echo '{"items":[]}'; fi ;;
    *"get crd postgresbackuplocations.sql.tanzu.vmware.com -o json"*)
      case "\${S_AZURE:-yes}" in
        yes) echo '{"spec":{"versions":[{"storage":true,"schema":{"openAPIV3Schema":{"properties":{"spec":{"properties":{"storage":{"properties":{"azure":{"properties":{"container":{},"enableSSL":{},"caBundle":{}}}}}}}}}}}]}}' ;;
        nocab) echo '{"spec":{"versions":[{"storage":true,"schema":{"openAPIV3Schema":{"properties":{"spec":{"properties":{"storage":{"properties":{"azure":{"properties":{"container":{}}}}}}}}}}}]}}' ;;
        *) echo '{"spec":{"versions":[{"storage":true,"schema":{"openAPIV3Schema":{"properties":{"spec":{"properties":{"storage":{"properties":{"s3":{}}}}}}}}}]}}' ;;
      esac ;;
    *"get crd postgres.sql.tanzu.vmware.com"*) [[ "\${S_CRDS:-yes}" == yes ]] ;;
    *"get crd ciliumnetworkpolicies.cilium.io"*) return 0 ;;
    *"get crd postgresferretdocumentdbs.sql.tanzu.vmware.com"*) [[ "\${S_FERRET_CRD:-yes}" == yes ]] ;;
    *"get postgres -A -o json"*)
      printf '{"items":['; local first=1 i
      for i in \${S_RUNNING:-}; do [[ \$first == 1 ]] || printf ','; first=0
        printf '{"apiVersion":"sql.tanzu.vmware.com/v1","kind":"Postgres","metadata":{"name":"%s","namespace":"pg-%s","annotations":%s}}' "\$i" "\$i" "\$(_ann "tpg-c1-\$i")"; done
      printf ']}' ;;
    *"get postgresversion"*) return 0 ;;
    *" get postgres "*)
      local ns="\${2#pg-}"
      if [[ " \${S_RUNNING:-} " == *" \$ns "* ]]; then
        case "\$*" in *currentState*) printf 'Running' ;; *jsonpath*) printf 'postgres-17.6' ;; esac
        return 0
      fi
      if [[ " \${S_API_ERR:-} " == *" \$ns "* ]]; then echo "Unable to connect to the server: dial tcp 10.0.0.1:443: i/o timeout" >&2; return 1; fi
      echo "Error from server (NotFound): postgres.sql.tanzu.vmware.com \"\$ns\" not found" >&2
      return 1 ;;
    *"get nodes -l tpg.fleet/pool=postgres -o json"*)
      printf '{"items":['; local z first=1
      for z in \$(seq 1 "\${S_ZONES:-3}"); do [[ \$first == 1 ]] || printf ','; first=0
        printf '{"metadata":{"labels":{"topology.kubernetes.io/zone":"eastus2-%s"}},"status":{"conditions":[{"type":"Ready","status":"True"}]}}' "\$z"; done
      printf ']}' ;;
    *) return 0 ;;
  esac
}
PRELUDE
for s in fleet-day0 day0-precheck fleet-commit blocked-gate operator-upgrade; do
  sed "s#source /scripts/lib.sh#source $TMP/prelude.sh#" "$ROOT/workflows/scripts/$s.sh" > "$TMP/$s.sh"
done
rec() { grep -F "$1" "$TMP/records" || true; }
reset() { rm -rf "$TMP/work"; : > "$TMP/records"; : > "$TMP/dryrun.yaml"; rm -f "$TMP/pushed.yaml"; cp "$TMP/fleet.base.yaml" "$TMP/fleet.yaml"; }
inv() {  # inv INSTANCES_JSON: the discover output for c1
  jq -cn --argjson i "$1" '[{name:"c1", wave:0, maxReadReplicas:3, operatorVersion:"v4.5.0", instances:$i}]' > "$TMP/inventory.json"
}
plan_json() { cat "$TMP/planned.json"; }

# ---- 1 Day 0 re-run adding billing-db on a cluster the fleet already runs
reset
export S_OPERATOR=ours S_TRACKED=yes S_CRDS=yes S_RUNNING="orders-db" S_APPRES=yes
env P_CLUSTERS=c1 P_INSTANCES=orders-db,billing-db P_HA=true P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=postgres-17.6 \
  P_READ_REPLICAS=1 bash "$TMP/fleet-day0.sh" wf '["c1"]' > "$TMP/out" 2>&1 || true
[[ ! -f "$TMP/pushed.yaml" ]] && ok "1 the plan pushes nothing" || bad "1 plan pushed" "$(cat "$TMP/out")"
cp /tmp/fleet.json "$TMP/planned.json"; cp /tmp/fleet-base.json "$TMP/base.json"
jq -e '.clusters.c1.instances["billing-db"].instance.postgresVersion == "postgres-17.6"' "$TMP/planned.json" >/dev/null \
  && ok "1 the planned fleet.yaml declares billing-db" || bad "1 planned" "$(cat "$TMP/planned.json") $(cat "$TMP/out")"
jq -e '.clusters.c1.instances | has("billing-db") | not' "$TMP/base.json" >/dev/null && ok "1 the base is the fleet.yaml as cloned" || bad "1 base"
rec "plan.git|PLANNED" | grep -q "c1(billing-db,orders-db)" && ok "1 plan.git records the plan" || bad "1 plan.git" "$(cat "$TMP/records")"

# pre-check: the operator Deployment keeps its tracking annotation (found by its
# image: the stub has no app label); the CRDs carry none and the Application lists them
inv '[{"name":"orders-db","postgresVersion":"postgres-17.6","highAvailability":true,"readReplicas":1,"enableSSL":false},{"name":"billing-db","postgresVersion":"postgres-17.6","highAvailability":true,"readReplicas":1,"enableSSL":false}]'
: > "$TMP/records"
S_TRACKED=yes S_CRD_TRACKED=no S_APPRES=yes bash "$TMP/day0-precheck.sh" wf c1 > "$TMP/out" 2>&1 || true
rec "precheck.c1|MANAGED" | grep -q . && ok "1 CRDs listed by tpg-c1-operator are MANAGED without a tracking annotation (was FOREIGN_CRD)" \
  || bad "1 precheck managed" "$(cat "$TMP/records") $(cat "$TMP/out")"
: > "$TMP/records"
S_TRACKED=yes S_CRD_TRACKED=no S_APPRES=no bash "$TMP/day0-precheck.sh" wf c1 > "$TMP/out" 2>&1 || true
rec "precheck.c1|BLOCKED" | grep -q "FOREIGN_CRD" && ok "1 CRDs neither listed nor annotated are FOREIGN_CRD" || bad "1 foreign crd" "$(cat "$TMP/records")"
: > "$TMP/records"
S_TRACKED=no S_APPRES=yes bash "$TMP/day0-precheck.sh" wf c1 > "$TMP/out" 2>&1 || true
rec "precheck.c1|BLOCKED" | grep -q "FOREIGN_OPERATOR" \
  && ok "1 an operator Deployment without the annotation is FOREIGN even when the Application lists its name" || bad "1 foreign" "$(cat "$TMP/records")"
: > "$TMP/records"
S_TRACKED=yes S_APPRES=no bash "$TMP/day0-precheck.sh" wf c1 > "$TMP/out" 2>&1 || true
rec "precheck.c1|MANAGED" | grep -q . && ok "1 the tracking annotation alone still makes them MANAGED" || bad "1 annotation" "$(cat "$TMP/records")"

# commit: MANAGED cluster written, then blocked-gate passes
: > "$TMP/records"; echo 'precheck.c1|MANAGED||' >> "$TMP/records"
bash "$TMP/fleet-commit.sh" wf "$(cat "$TMP/planned.json")" "$(cat "$TMP/base.json")" > "$TMP/out" 2>&1 || true
yq -e '.clusters.c1.instances["billing-db"]' "$TMP/pushed.yaml" >/dev/null 2>&1 && rec "result.git|SUCCEEDED" | grep -q abc123 \
  && ok "1 the commit writes the MANAGED cluster" || bad "1 commit" "$(cat "$TMP/records") $(cat "$TMP/out")"
# Round 13 addendum: the committed file is block YAML, the JSON plan and the flow
# style of the base file (fleet.base.yaml) alike, with no JSON quotes
[[ "$(yq '[... | select((tag == "!!map" or tag == "!!seq") and length > 0 and style == "flow")] | length' "$TMP/pushed.yaml")" == "0" ]] \
  && ! grep -q '"' "$TMP/pushed.yaml" && yq -e '.clusters.c1.instances["orders-db"].instance.highAvailability.enabled == true' "$TMP/pushed.yaml" >/dev/null \
  && ok "1 clusters/fleet.yaml is committed in block YAML (no flow maps, no JSON quotes, values kept)" || bad "1 block yaml" "$(cat "$TMP/pushed.yaml")"
cat > "$TMP/style.yaml" <<'YAML'
# fleet file
clusters:
  c1: {"operator": {"version": "v4.5.0"}}  # added by hand
  c2:
    instances:
      a: {instance: {postgresVersion: postgres-17.6}, backup: {caBundle: "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n", s: "true", n: "0", e: {}}}
YAML
bash -c "source '$TMP/prelude.sh'; fleet_yaml_style '$TMP/style.yaml'" > /dev/null 2>&1
[[ "$(yq '[... | select((tag == "!!map" or tag == "!!seq") and length > 0 and style == "flow")] | length' "$TMP/style.yaml")" == "0" ]] \
  && grep -q '^    # added by hand$' "$TMP/style.yaml" && grep -q '^          caBundle: |$' "$TMP/style.yaml" \
  && [[ "$(yq -o=json -I=0 '.clusters.c2.instances.a.backup | [.s, .n, .e]' "$TMP/style.yaml")" == '["true","0",{}]' ]] \
  && ok "1 fleet_yaml_style: block YAML, the comment kept above its content, caBundle literal, quoted strings stay strings" \
  || bad "1 fleet_yaml_style" "$(head -8 "$TMP/style.yaml")"
bash "$TMP/blocked-gate.sh" wf > "$TMP/out" 2>&1 && ok "1 the gate passes when nothing is BLOCKED" || bad "1 gate" "$(cat "$TMP/out")"

# ---- 2 a BLOCKED cluster is never written, and the run fails
: > "$TMP/records"; rm -f "$TMP/pushed.yaml"; echo 'precheck.c1|BLOCKED|FOREIGN_OPERATOR:other/postgres-operator|' >> "$TMP/records"
bash "$TMP/fleet-commit.sh" wf "$(cat "$TMP/planned.json")" "$(cat "$TMP/base.json")" > "$TMP/out" 2>&1 || true
[[ ! -f "$TMP/pushed.yaml" ]] && rec "result.git|SUCCEEDED|NO_CHANGE" | grep -q "not written (pre-check): c1 (pre-check BLOCKED)" \
  && ok "2 a BLOCKED cluster's plan does not reach Git" || bad "2 blocked commit" "$(cat "$TMP/records") $(cat "$TMP/out")"
if bash "$TMP/blocked-gate.sh" wf > "$TMP/out" 2>&1; then bad "2 gate should fail" "$(cat "$TMP/out")"
else grep -q "c1 FOREIGN_OPERATOR" "$TMP/out" && ok "2 the gate fails the run and names the blocked cluster" || bad "2 gate text" "$(cat "$TMP/out")"; fi

# ---- 3 Git changed for the cluster while planning
: > "$TMP/records"; rm -f "$TMP/pushed.yaml"; echo 'precheck.c1|MANAGED||' >> "$TMP/records"
yq -i '.clusters.c1.instances["orders-db"].instance.storageSize = "99Gi"' "$TMP/fleet.yaml"
bash "$TMP/fleet-commit.sh" wf "$(cat "$TMP/planned.json")" "$(cat "$TMP/base.json")" > "$TMP/out" 2>&1 || true
rec "result.git|FAILED|FLEET_CHANGED_DURING_RUN" | grep -q c1 && [[ ! -f "$TMP/pushed.yaml" ]] \
  && ok "3 a cluster changed in Git during the run is not overwritten" || bad "3 changed" "$(cat "$TMP/records")"

# ---- 4 ORPHAN_CRD: CRDs with no operator are adopted with a warning
reset; : > "$TMP/records"
S_OPERATOR=none S_TRACKED=no S_APPRES=no S_RUNNING="" bash "$TMP/day0-precheck.sh" wf c1 > "$TMP/out" 2>&1 || true
rec "warning.c1.crds|WARNING|ORPHAN_CRD" | grep -q . && rec "precheck.c1|PASSED" | grep -q . \
  && ok "4 CRDs without an operator: warning ORPHAN_CRD, cluster PASSED" || bad "4 orphan" "$(cat "$TMP/records") $(cat "$TMP/out")"

# ---- 5 HA_NODES_EXCEED_ZONES (4.5 release notes)
inv '[{"name":"orders-db","postgresVersion":"postgres-17.6","highAvailability":true,"readReplicas":3,"enableSSL":false}]'
: > "$TMP/records"
S_OPERATOR=ours S_TRACKED=yes S_APPRES=yes S_ZONES=3 bash "$TMP/day0-precheck.sh" wf c1 > "$TMP/out" 2>&1 || true
rec "warning.c1.orders-db.zones|WARNING|HA_NODES_EXCEED_ZONES" | grep -q "4 database pods" && rec "precheck.c1|MANAGED" | grep -q . \
  && ok "5 readReplicas 3 on 3 zones: warning, not a block" || bad "5 zones" "$(cat "$TMP/records")"

# ---- 6 AZURE_BACKUP_UNSUPPORTED: the live CRD decides (4.5 docs list S3 and GCS only)
: > "$TMP/records"
S_OPERATOR=ours S_TRACKED=yes S_APPRES=yes S_AZURE=no bash "$TMP/day0-precheck.sh" wf c1 > "$TMP/out" 2>&1 || true
rec "precheck.c1|BLOCKED" | grep -q "AZURE_BACKUP_UNSUPPORTED" && ok "6 no spec.storage.azure in the CRD: BLOCKED" || bad "6 azure" "$(cat "$TMP/records")"
inv '[{"name":"orders-db","postgresVersion":"postgres-17.6","highAvailability":false,"readReplicas":0,"enableSSL":true}]'
: > "$TMP/records"
S_OPERATOR=ours S_TRACKED=yes S_APPRES=yes S_AZURE=nocab bash "$TMP/day0-precheck.sh" wf c1 > "$TMP/out" 2>&1 || true
rec "precheck.c1|BLOCKED" | grep -q "no spec.storage.azure.caBundle" && ok "6 enableSSL without caBundle in the CRD: BLOCKED" || bad "6 cab" "$(cat "$TMP/records")"

# ---- 7 enableSSL: the CA bundle from tpg-settings, or CA_BUNDLE_MISSING
reset
S_OPERATOR=ours S_RUNNING="orders-db" S_CA="" \
  env P_CLUSTERS=c1 P_INSTANCES=new-db P_HA=false P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=postgres-17.6 P_BACKUP_ENABLE_SSL=true \
  bash "$TMP/fleet-day0.sh" wf '["c1"]' > "$TMP/out" 2>&1 || true
rec "result.git|FAILED|INVALID_INPUT" | grep -q CA_BUNDLE_MISSING && ok "7 enableSSL=true without a bundle: CA_BUNDLE_MISSING" || bad "7 missing" "$(cat "$TMP/records")"
reset
S_OPERATOR=ours S_RUNNING="orders-db" S_CA=$'-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----' \
  env P_CLUSTERS=c1 P_INSTANCES=new-db P_HA=false P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=postgres-17.6 P_BACKUP_ENABLE_SSL=true \
  bash "$TMP/fleet-day0.sh" wf '["c1"]' > "$TMP/out" 2>&1 || true
jq -e '.clusters.c1.instances["new-db"].backup | .enableSSL == true and .caBundle == "@tpg-settings:backupCaBundle@"' /tmp/fleet.json >/dev/null \
  && ok "7 enableSSL=true plans backup.caBundle as the tpg-settings placeholder" || bad "7 bundle" "$(cat /tmp/fleet.json) $(cat "$TMP/out")"
jq -e '.clusters.c1.instances["new-db"].instance.highAvailability | .enabled == false and .readReplicas == 0' /tmp/fleet.json >/dev/null \
  && ok "7 highAvailability=false writes enabled false and readReplicas 0" || bad "7 ha"
cp /tmp/fleet.json "$TMP/planned.json"; cp /tmp/fleet-base.json "$TMP/base.json"
: > "$TMP/records"; echo 'precheck.c1|MANAGED||' >> "$TMP/records"
S_CA=$'-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----' \
  bash "$TMP/fleet-commit.sh" wf "$(cat "$TMP/planned.json")" "$(cat "$TMP/base.json")" > "$TMP/out" 2>&1 || true
yq -e '.clusters.c1.instances["new-db"].backup.caBundle | test("^-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----")' "$TMP/pushed.yaml" >/dev/null 2>&1 \
  && ! grep -q '@tpg-settings' "$TMP/pushed.yaml" \
  && ok "7 the commit writes the bundle itself in place of the placeholder" || bad "7 restore" "$(cat "$TMP/pushed.yaml" 2>/dev/null) $(cat "$TMP/out")"
: > "$TMP/records"; rm -f "$TMP/pushed.yaml"; echo 'precheck.c1|MANAGED||' >> "$TMP/records"
S_CA="" bash "$TMP/fleet-commit.sh" wf "$(cat "$TMP/planned.json")" "$(cat "$TMP/base.json")" > "$TMP/out" 2>&1 || true
rec "result.git|FAILED|CA_BUNDLE_MISSING" | grep -q . && [[ ! -f "$TMP/pushed.yaml" ]] \
  && ok "7 the bundle removed from tpg-settings before the commit: CA_BUNDLE_MISSING, nothing pushed" || bad "7 commit missing" "$(cat "$TMP/records")"
# the plan stays small with many enableSSL instances (one container argument is limited to 128 KiB)
reset
BIG="$(for _ in $(seq 1 150); do echo MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw; done)"
BIG="$BIG" yq -i '.clusters.c1.instances["orders-db"].backup = {"enableSSL": true, "caBundle": strenv(BIG)}' "$TMP/fleet.yaml"
many="$(seq -s, -f 'db-%02g' 1 20)"
S_OPERATOR=ours S_RUNNING="orders-db" S_CA="$BIG" \
  env P_CLUSTERS=c1 P_INSTANCES="$many" P_HA=false P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=postgres-17.6 P_BACKUP_ENABLE_SSL=true \
  bash "$TMP/fleet-day0.sh" wf '["c1"]' > "$TMP/out" 2>&1 || true
[[ "$(jq '[.clusters.c1.instances[] | select(.backup.enableSSL == true)] | length' /tmp/fleet.json)" -eq 21 ]] \
  && [[ "$(wc -c < /tmp/fleet.json)" -lt 16384 && "$(wc -c < /tmp/fleet-base.json)" -lt 16384 ]] \
  && ok "7 21 enableSSL instances with a ${#BIG}-byte bundle: plan and base stay under 16 KiB" \
  || bad "7 size" "fleet.json $(wc -c < /tmp/fleet.json) bytes, base $(wc -c < /tmp/fleet-base.json) bytes $(tail -5 "$TMP/out")"

# ---- 8 exposure and network policy inputs (lists and maps normalized)
reset
S_OPERATOR=ours S_RUNNING="orders-db" S_ACNS=true \
  env P_CLUSTERS=c1 P_INSTANCES=new-db P_HA=false P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=postgres-17.6 \
  P_EXPOSURE=loadBalancer P_SERVICE_ANNOTATIONS='service.beta.kubernetes.io/azure-dns-label-name: orders' \
  P_NETWORK_POLICY=baseline P_INGRESS_FROM_NAMESPACES='app, reporting' P_INGRESS_FROM_CIDRS=10.1.0.0/16 \
  bash "$TMP/fleet-day0.sh" wf '["c1"]' > "$TMP/out" 2>&1 || true
jq -e '.clusters.c1.instances["new-db"] | .instance.exposure == "loadBalancer"
   and .instance.serviceAnnotations["service.beta.kubernetes.io/azure-dns-label-name"] == "orders"
   and .network.policy == "baseline" and .network.ingressFromNamespaces == ["app","reporting"]
   and .network.ingressFromCidrs == ["10.1.0.0/16"] and .network.acns == true' /tmp/fleet.json >/dev/null \
  && ok "8 exposure and network keys are written with their types (list, map, acns from tpg-settings)" || bad "8 keys" "$(jq -c '.clusters.c1.instances["new-db"]' /tmp/fleet.json) $(cat "$TMP/out")"
rec "warning.c1.new-db.exposure|WARNING|EXPOSURE_UNRESTRICTED" | grep -q . \
  && ok "8 loadBalancer without allowedSourceRanges: warning EXPOSURE_UNRESTRICTED" || bad "8 warning" "$(cat "$TMP/records")"
reset
S_OPERATOR=ours S_RUNNING="orders-db" env P_CLUSTERS=c1 P_INSTANCES=new-db P_HA=false P_OPERATOR_VERSION=v4.5.0 \
  P_POSTGRES_VERSION=postgres-17.6 P_ALLOWED_SOURCE_RANGES=10.0.0.1/8 bash "$TMP/fleet-day0.sh" wf '["c1"]' > "$TMP/out" 2>&1 || true
rec "result.git|FAILED|INVALID_INPUT" | grep -q "must be a CIDR" && ok "8 a CIDR with host bits is refused" || bad "8 cidr" "$(cat "$TMP/records")"

# ---- 9 tpg-create-instance: operator required, idempotent, patch creation rules
reset
S_OPERATOR=none S_RUNNING="" env FLEET_MODE=create P_CLUSTERS=c1 P_INSTANCES=new-db P_HA=false P_POSTGRES_VERSION=postgres-17.6 \
  bash "$TMP/fleet-day0.sh" wf '["c1"]' > "$TMP/out" 2>&1 || true
rec "block.c1|BLOCKED|OPERATOR_NOT_INSTALLED" | grep -q . && ok "9 no operator on the cluster: OPERATOR_NOT_INSTALLED" || bad "9 operator" "$(cat "$TMP/records") $(cat "$TMP/out")"
reset
S_OPERATOR=ours S_RUNNING="orders-db" env FLEET_MODE=create P_CLUSTERS=c1 P_INSTANCES=orders-db P_HA=true P_READ_REPLICAS=1 \
  P_POSTGRES_VERSION=postgres-17.6 bash "$TMP/fleet-day0.sh" wf '["c1"]' > "$TMP/out" 2>&1 || true
rec "result.c1.orders-db|SUCCEEDED|ALREADY_EXISTS" | grep -q . && ok "9 a running instance with the same values: ALREADY_EXISTS" || bad "9 exists" "$(cat "$TMP/records") $(cat "$TMP/out")"
reset
S_OPERATOR=ours S_RUNNING="orders-db" env FLEET_MODE=create P_CLUSTERS=c1 P_INSTANCES=orders-db P_HA=true P_READ_REPLICAS=2 \
  P_POSTGRES_VERSION=postgres-17.6 bash "$TMP/fleet-day0.sh" wf '["c1"]' > "$TMP/out" 2>&1 || true
rec "result.c1.orders-db|BLOCKED|INSTANCE_EXISTS" | grep -q "tpg-patch, tpg-scale-instance or tpg-upgrade" \
  && jq -e '.clusters.c1.instances["orders-db"].instance.highAvailability.readReplicas == 1' /tmp/fleet.json >/dev/null \
  && ok "9 a running instance with other values: INSTANCE_EXISTS, its entry unchanged" || bad "9 differs" "$(cat "$TMP/records")"
reset
S_OPERATOR=ours S_RUNNING="orders-db" env FLEET_MODE=create P_CLUSTERS=c1 P_INSTANCES=orders-db P_HA=true P_READ_REPLICAS=1 \
  P_POSTGRES_VERSION=postgres-17.6 P_EXPOSURE=loadBalancer bash "$TMP/fleet-day0.sh" wf '["c1"]' > "$TMP/out" 2>&1 || true
rec "result.c1.orders-db|BLOCKED|INSTANCE_EXISTS" | grep -q . && ! rec "EXPOSURE_UNRESTRICTED" | grep -q . \
  && ok "9 no exposure warning for an entry that is put back (INSTANCE_EXISTS)" || bad "9 warning on revert" "$(cat "$TMP/records")"
# Round 14: the patch files come from the submitting machine (patchFiles) and are
# stored as charts/tpg-instance/patches/<name>-<uid>.yaml, recorded as current
pf() { jq -cn --arg a "$1" --arg b "$(base64 < "$P/$2" | tr -d '\n')" '{($a): $b}'; }
PF_SC="$(pf ./sc.yaml sc.yaml)"; PF_VALS="$(pf vals.yaml vals.yaml)"; PF_HA="$(pf ha.yaml ha.yaml)"
reset
S_OPERATOR=ours S_RUNNING="orders-db" env FLEET_MODE=create P_CLUSTERS=c1 P_INSTANCES=new-db P_HA=false P_POSTGRES_VERSION=postgres-17.6 \
  P_POSTGRES_PATCH_FILES=./sc.yaml P_VALUES_PATCH_FILES=vals.yaml P_PATCH_FILES="$(jq -cn --argjson a "$PF_SC" --argjson b "$PF_VALS" '$a + $b')" \
  bash "$TMP/fleet-day0.sh" wf '["c1"]' > "$TMP/out" 2>&1 || true
jq -e '.clusters.c1.instances["new-db"].patches | (.postgres.current | test("^patches/sc-[a-z0-9]{5}\\.yaml$"))
       and (.values.current | test("^patches/vals-[a-z0-9]{5}\\.yaml$")) and (has("previous") | not)' /tmp/fleet.json >/dev/null \
  && ok "9 creation patches are stored as <name>-<uid>.yaml and recorded as current (storage class allowed at creation)" \
  || bad "9 patches" "$(jq -c '.clusters.c1.instances' /tmp/fleet.json) $(cat "$TMP/out")"
stored_sc="$(jq -r '.clusters.c1.instances["new-db"].patches.postgres.current' /tmp/fleet.json)"
cmp -s "$TMP/work/repo/charts/tpg-instance/$stored_sc" "$P/sc.yaml" \
  && rec "patch.names|SET" | grep -q "\"sc.yaml\":\"charts/tpg-instance/${stored_sc}\"" \
  && ok "9 the stored file holds the received contents; patch.names records its name (./ dropped)" || bad "9 stored" "$(cat "$TMP/records")"
# fleet-commit writes the stored files the written entries reference, and commits them
cp /tmp/fleet.json "$TMP/planned.json"; cp /tmp/fleet-base.json "$TMP/base.json"
echo 'precheck.c1|PASSED||' >> "$TMP/records"
P_PATCH_FILES="$(jq -cn --argjson a "$PF_SC" --argjson b "$PF_VALS" '$a + $b')" \
  bash "$TMP/fleet-commit.sh" wf "$(cat "$TMP/planned.json")" "$(cat "$TMP/base.json")" > "$TMP/out" 2>&1 || true
grep -qx "charts/tpg-instance/${stored_sc}" "$TMP/pushed-files" && grep -qx "clusters/fleet.yaml" "$TMP/pushed-files" \
  && cmp -s "$TMP/work/repo/charts/tpg-instance/${stored_sc}" "$P/sc.yaml" \
  && ok "9 fleet-commit commits clusters/fleet.yaml with the stored patch files" || bad "9 commit files" "$(cat "$TMP/pushed-files" 2>/dev/null) $(cat "$TMP/out")"
# a repeated create with the same file keeps the current file: ALREADY_EXISTS
yq -P '.' "$TMP/planned.json" > "$TMP/fleet.yaml"
cp "$TMP/work/repo/charts/tpg-instance/${stored_sc}" "$P/"; stored_vals="$(yq -r '.clusters.c1.instances["new-db"].patches.values.current' "$TMP/fleet.yaml")"
cp "$TMP/work/repo/charts/tpg-instance/${stored_vals}" "$P/"
rm -rf "$TMP/work"; : > "$TMP/records"
S_OPERATOR=ours S_RUNNING="orders-db new-db" env FLEET_MODE=create P_CLUSTERS=c1 P_INSTANCES=new-db P_HA=false P_POSTGRES_VERSION=postgres-17.6 \
  P_POSTGRES_PATCH_FILES=./sc.yaml P_VALUES_PATCH_FILES=vals.yaml P_PATCH_FILES="$(jq -cn --argjson a "$PF_SC" --argjson b "$PF_VALS" '$a + $b')" \
  bash "$TMP/fleet-day0.sh" wf '["c1"]' > "$TMP/out" 2>&1 || true
rec "result.c1.new-db|SUCCEEDED|ALREADY_EXISTS" | grep -q . \
  && jq -e --arg s "$stored_sc" '.clusters.c1.instances["new-db"].patches.postgres.current == $s' /tmp/fleet.json >/dev/null \
  && ok "9 the same file again: the current stored file is kept, ALREADY_EXISTS" || bad "9 idempotent" "$(cat "$TMP/records") $(jq -c '.clusters.c1.instances["new-db"].patches' /tmp/fleet.json)"
rm -f "$P/${stored_sc#patches/}" "$P/${stored_vals#patches/}"
yq -e 'select(.metadata.name == "tpg-create-probe") | .spec.storageClassName == "premium-fast" and .metadata.namespace == "default"' "$TMP/dryrun.yaml" >/dev/null \
  && ok "9 the rendered instance is dry-run through the webhooks under a probe name" || bad "9 dry run" "$(cat "$TMP/dryrun.yaml")"
reset
S_OPERATOR=ours S_RUNNING="orders-db" env FLEET_MODE=create P_CLUSTERS=c1 P_INSTANCES=new-db P_HA=false P_POSTGRES_VERSION=postgres-17.6 \
  P_POSTGRES_PATCH_FILES=ha.yaml P_PATCH_FILES="$PF_HA" bash "$TMP/fleet-day0.sh" wf '["c1"]' > "$TMP/out" 2>&1 || true
rec "result.c1.new-db|BLOCKED|PATCH_REFUSED" | grep -q "ha.yaml: spec.highAvailability comes from" \
  && jq -e '.clusters.c1.instances | has("new-db") | not' /tmp/fleet.json >/dev/null \
  && ok "9 a patch of an input-owned field is refused and the instance left out" || bad "9 refused" "$(cat "$TMP/records")"

# ---- 10 operator upgrade: a declared but absent instance is left out
reset
yq -i '.clusters.c1.instances["billing-db"] = {"instance": {"postgresVersion": "postgres-17.6"}}' "$TMP/fleet.yaml"
inv '[{"name":"orders-db"},{"name":"billing-db"}]'
S_RUNNING="orders-db" P_DRY_RUN=true bash "$TMP/operator-upgrade.sh" wf c1 v4.5.1 600 > "$TMP/out" 2>&1 || true
rec "warning.c1.billing-db.deployed|WARNING|INSTANCE_NOT_DEPLOYED" | grep -q . && rec "result.c1|SUCCEEDED|DRY_RUN" | grep -q . \
  && ok "10 billing-db (declared, absent) gets a warning; the guard passes" || bad "10 guard" "$(cat "$TMP/records") $(cat "$TMP/out")"
reset
yq -i '.clusters.c1.instances["billing-db"] = {"instance": {"postgresVersion": "postgres-17.6"}}' "$TMP/fleet.yaml"
S_RUNNING="orders-db" S_API_ERR="billing-db" P_DRY_RUN=true bash "$TMP/operator-upgrade.sh" wf c1 v4.5.1 600 > "$TMP/out" 2>&1 || true
rec "result.c1|FAILED|CLUSTER_API_ERROR" | grep -q "i/o timeout" && ! rec "INSTANCE_NOT_DEPLOYED" | grep -q . \
  && ok "10 an API error is not taken for an absent instance (CLUSTER_API_ERROR)" || bad "10 api error" "$(cat "$TMP/records") $(cat "$TMP/out")"

# ---- 10b operator upgrade: the operatorImage tag of the current values patch
mkdir -p "$REPO/patches/operator"
printf 'operatorImage: myacr.azurecr.io/postgres-operator:v4.5.0\nresources:\n  limits: {cpu: 500m}\n' > "$REPO/patches/operator/op-ab12c.yaml"
{ cat "$TMP/prelude.sh"; echo 'appset_refresh() { exit 0; }   # stop after the version commit'; } > "$TMP/prelude-upgrade.sh"
sed "s#source $TMP/prelude.sh#source $TMP/prelude-upgrade.sh#" "$TMP/operator-upgrade.sh" > "$TMP/operator-upgrade-git.sh"
reset
yq -i '.clusters.c1.operator.patches.values.current = "patches/operator/op-ab12c.yaml"' "$TMP/fleet.yaml"
inv '[{"name":"orders-db"}]'
S_RUNNING="orders-db" P_PRE_BACKUP=false bash "$TMP/operator-upgrade-git.sh" wf c1 v4.5.1 600 > "$TMP/out" 2>&1 || true
new="$(yq -r '.clusters.c1.operator.patches.values.current' "$TMP/pushed.yaml")"
[[ "$new" =~ ^patches/operator/op-[a-z0-9]{5}\.yaml$ && "$new" != patches/operator/op-ab12c.yaml ]] \
  && [[ "$(yq -r '.operatorImage' "$TMP/work/repo/$new")" == "myacr.azurecr.io/postgres-operator:v4.5.1" ]] \
  && [[ "$(yq -r '.operatorImage' "$TMP/work/repo/patches/operator/op-ab12c.yaml")" == "myacr.azurecr.io/postgres-operator:v4.5.0" ]] \
  && [[ "$(yq -r '.clusters.c1.operator.patches.values.previous.path' "$TMP/pushed.yaml")" == patches/operator/op-ab12c.yaml ]] \
  && grep -qx "$new" "$TMP/pushed-files" && grep -qx "patches/operator/clusters/c1.yaml" "$TMP/pushed-files" \
  && grep -q "postgres-operator:v4.5.1" "$TMP/work/repo/patches/operator/clusters/c1.yaml" \
  && ok "10b the new tag goes to a new stored file, which becomes current; the old file is unchanged and previous" \
  || bad "10b operatorImage tag" "$(cat "$TMP/out") $(cat "$TMP/pushed-files" 2>/dev/null)"
reset
yq -i '.clusters.c1.operator.patches.values = ["patches/operator/op-ab12c.yaml", "patches/operator/op-ab12c.yaml"]' "$TMP/fleet.yaml"
S_RUNNING="orders-db" P_DRY_RUN=true bash "$TMP/operator-upgrade.sh" wf c1 v4.5.1 600 > "$TMP/out" 2>&1 || true
rec "result.c1|FAILED|OPERATOR_PATCH_LIST" | grep -q "merge them into one" \
  && ok "10b a Round 11 list of several operator values files stops the upgrade" || bad "10b list" "$(cat "$TMP/records") $(cat "$TMP/out")"
rm -rf "$REPO/patches"

# ---- 11 discover after the plan: a blocked instance is left out, not UNKNOWN_INSTANCE
cat > "$TMP/prelude-discover.sh" <<PRELUDE
source "$TMP/prelude.sh"
registered_clusters() { printf 'c1\n'; }
registered_wave() { echo 0; }
kubectl() { :; }
PRELUDE
sed "s#source /scripts/lib.sh#source $TMP/prelude-discover.sh#" "$ROOT/workflows/scripts/discover.sh" > "$TMP/discover.sh"
reset
S_OPERATOR=ours S_RUNNING="orders-db" env FLEET_MODE=create P_CLUSTERS=c1 P_INSTANCES=new-db P_HA=false P_POSTGRES_VERSION=postgres-17.6 \
  P_POSTGRES_PATCH_FILES=ha.yaml P_PATCH_FILES="$PF_HA" bash "$TMP/fleet-day0.sh" wf '["c1"]' > "$TMP/out" 2>&1 || true
RC=0; P_FILTER=pairs P_INSTANCES=new-db bash "$TMP/discover.sh" wf c1 "$(cat /tmp/fleet.json)" > "$TMP/out" 2>&1 || RC=$?
[[ "$RC" -eq 0 ]] && grep -q "c1/new-db: blocked in the plan, left out" "$TMP/out" && ! rec "UNKNOWN_INSTANCE" | grep -q . \
  && rec "result.c1.new-db|BLOCKED|PATCH_REFUSED" | grep -q . \
  && ok "11 discover leaves out an instance the plan blocked (the run reaches the gate)" || bad "11 discover blocked" "$(cat "$TMP/records") $(cat "$TMP/out")"
: > "$TMP/records"
RC=0; P_FILTER=pairs P_INSTANCES=new-db bash "$TMP/discover.sh" wf c1 "$(cat /tmp/fleet.json)" > "$TMP/out" 2>&1 || RC=$?
[[ "$RC" -ne 0 ]] && rec "result.c1.new-db|FAILED|UNKNOWN_INSTANCE" | grep -q . \
  && ok "11 without a plan record the same instance is UNKNOWN_INSTANCE" || bad "11 discover unknown" "$(cat "$TMP/records") $(cat "$TMP/out")"

# ---- 12 Round 13: HA refusal, operator backup schedules, FerretDB (D69 to D71)
reset
S_OPERATOR=ours S_RUNNING="orders-db" env P_CLUSTERS=c1 P_INSTANCES=new-db P_HA=true P_READ_REPLICAS=0 P_OPERATOR_VERSION=v4.5.0 \
  P_POSTGRES_VERSION=postgres-17.6 bash "$TMP/fleet-day0.sh" wf '["c1"]' > "$TMP/out" 2>&1 || true
rec "result.git|FAILED|INVALID_INPUT" | grep -q "highAvailability=true needs readReplicas 1 or more" \
  && ok "12 highAvailability=true with readReplicas 0 is refused (a single node is highAvailability=false)" || bad "12 ha 0" "$(cat "$TMP/records")"
reset
S_OPERATOR=ours S_RUNNING="orders-db" env P_CLUSTERS=c1 P_INSTANCES=new-db P_HA=false P_OPERATOR_VERSION=v4.5.0 \
  P_POSTGRES_VERSION=postgres-17.6 P_FERRET=true P_FERRET_RO_REPLICAS=2 bash "$TMP/fleet-day0.sh" wf '["c1"]' > "$TMP/out" 2>&1 || true
rec "result.git|FAILED|INVALID_INPUT" | grep -q "ferretReadOnlyReplicas 2 needs highAvailability=true" \
  && ok "12 read-only FerretDB proxies on a single node are refused" || bad "12 ferret ro" "$(cat "$TMP/records")"
reset
S_OPERATOR=ours S_RUNNING="orders-db" env P_CLUSTERS=c1 P_INSTANCES=new-db P_HA=true P_READ_REPLICAS=1 P_OPERATOR_VERSION=v4.5.0 \
  P_POSTGRES_VERSION=postgres-17.6 P_BACKUP_SCHEDULE=operator P_OPERATOR_FULL_SCHEDULE='0 1 * * 0' P_OPERATOR_INCR_SCHEDULE='' \
  P_FERRET=true P_FERRET_REPLICAS=2 P_FERRET_RO_REPLICAS=1 P_FERRET_EXPOSURE=internalLoadBalancer \
  bash "$TMP/fleet-day0.sh" wf '["c1"]' > "$TMP/out" 2>&1 || true
jq -e '.clusters.c1.instances["new-db"] | .backup.scheduled == false and .backup.operatorSchedules == {"full": "0 1 * * 0"}
   and .ferret == {"enabled": true, "replicas": 2, "readOnlyReplicas": 1, "exposure": "internalLoadBalancer"}' /tmp/fleet.json >/dev/null \
  && ok "12 backupSchedule=operator writes scheduled false and the full schedule (empty incremental: none); ferret writes its block" \
  || bad "12 operator+ferret" "$(jq -c '.clusters.c1.instances["new-db"]' /tmp/fleet.json) $(cat "$TMP/out")"
rec "warning.c1.new-db.ferret|WARNING|FERRET_EXTENSION_REQUIRED" | grep -q documentdb \
  && ok "12 ferret=true records warning FERRET_EXTENSION_REQUIRED" || bad "12 ferret warning" "$(cat "$TMP/records")"
# the planned entry renders: two PostgresBackupSchedule objects would need incremental;
# here only the full one, and the FerretDB object with read-only proxies
cp /tmp/fleet.json "$TMP/planned.json"
yq -P '.' "$TMP/planned.json" > "$REPO/clusters/fleet.yaml"
out="$(instance_render_test() { C=c1 I=new-db yq '.clusters[strenv(C)] as $c | ($c.instances[strenv(I)] // {}) as $i
    | ($c | with_entries(select(.key != "instances" and .key != "operator")))
    * {"cluster": {"name": strenv(C)}, "backup": {"container": "pg-backups-c1"}} * $i * {"instance": {"name": strenv(I)}}' "$REPO/clusters/fleet.yaml" > "$TMP/vals.yaml"
  helm template new-db "$REPO/charts/tpg-instance" -f "$REPO/clusters/_template/cluster.yaml" -f "$REPO/clusters/_template/instance.yaml" -f "$TMP/vals.yaml" -n pg-new-db; }; instance_render_test 2>&1)"
[[ "$(yq 'select(.kind == "PostgresBackupSchedule") | .metadata.name' <<<"$out")" == "new-db-backup-full" ]] \
  && [[ "$(yq 'select(.kind == "PostgresFerretDocumentDB") | .spec.readOnly.replicas' <<<"$out")" == "1" ]] \
  && ok "12 the planned entry renders one PostgresBackupSchedule and the FerretDB object" || bad "12 render" "$out"
reset
yq -i '.clusters.c1.instances["orders-db"].ferret = {"enabled": true} | .clusters.c1.instances["orders-db"].backup.operatorSchedules = {"full": "0 0 * * 0"} | .clusters.c1.instances["orders-db"].backup.scheduled = false' "$TMP/fleet.yaml"
S_OPERATOR=ours S_RUNNING="orders-db" env P_CLUSTERS=c1 P_INSTANCES=orders-db P_HA=true P_READ_REPLICAS=1 P_OPERATOR_VERSION=v4.5.0 \
  P_POSTGRES_VERSION=postgres-17.6 bash "$TMP/fleet-day0.sh" wf '["c1"]' > "$TMP/out" 2>&1 || true
jq -e '.clusters.c1.instances["orders-db"] | .ferret.enabled == true and ((.backup // {}) | has("operatorSchedules") or has("scheduled") | not)' /tmp/fleet.json >/dev/null \
  && ok "12 a Day 0 re-run with the defaults keeps FerretDB (ferret empty) and returns to the CronWorkflows (backupSchedule fleet)" \
  || bad "12 re-run" "$(jq -c '.clusters.c1.instances["orders-db"]' /tmp/fleet.json)"
reset
yq -i '.clusters.c1.instances["orders-db"].ferret = {"enabled": true, "readOnlyReplicas": 1}' "$TMP/fleet.yaml"
S_OPERATOR=ours S_RUNNING="orders-db" env P_CLUSTERS=c1 P_INSTANCES=orders-db P_HA=false P_OPERATOR_VERSION=v4.5.0 \
  P_POSTGRES_VERSION=postgres-17.6 bash "$TMP/fleet-day0.sh" wf '["c1"]' > "$TMP/out" 2>&1 || true
rec "result.git|FAILED|INVALID_INPUT" | grep -q "runs 1 read-only proxies, which need highAvailability=true" \
  && ok "12 highAvailability=false with ferret empty is refused while the entry's FerretDB runs read-only proxies" \
  || bad "12 ferret kept ro" "$(cat "$TMP/records") $(tail -5 "$TMP/out")"
reset
yq -i '.clusters.c1.instances["orders-db"].ferret = {"enabled": true}' "$TMP/fleet.yaml"
S_OPERATOR=ours S_RUNNING="orders-db" env P_CLUSTERS=c1 P_INSTANCES=orders-db P_HA=true P_READ_REPLICAS=1 P_OPERATOR_VERSION=v4.5.0 \
  P_POSTGRES_VERSION=postgres-17.6 P_FERRET=false bash "$TMP/fleet-day0.sh" wf '["c1"]' > "$TMP/out" 2>&1 || true
jq -e '.clusters.c1.instances["orders-db"] | has("ferret") | not' /tmp/fleet.json >/dev/null \
  && ok "12 ferret=false removes the ferret block" || bad "12 ferret false" "$(jq -c '.clusters.c1.instances["orders-db"]' /tmp/fleet.json)"
# pre-check
inv '[{"name":"docs-db","postgresVersion":"postgres-16.10","highAvailability":false,"readReplicas":0,"enableSSL":false,"ferret":true}]'
: > "$TMP/records"
S_OPERATOR=ours S_TRACKED=yes S_APPRES=yes bash "$TMP/day0-precheck.sh" wf c1 > "$TMP/out" 2>&1 || true
rec "precheck.c1|BLOCKED" | grep -q "FERRET_VERSION_UNSUPPORTED:docs-db runs postgres-16.10" \
  && ok "12 FerretDB below Postgres 17.5: FERRET_VERSION_UNSUPPORTED" || bad "12 ferret version" "$(cat "$TMP/records")"
inv '[{"name":"docs-db","postgresVersion":"postgres-17.6","highAvailability":false,"readReplicas":0,"enableSSL":false,"ferret":true}]'
: > "$TMP/records"
S_OPERATOR=ours S_TRACKED=yes S_APPRES=yes S_FERRET_CRD=no bash "$TMP/day0-precheck.sh" wf c1 > "$TMP/out" 2>&1 || true
rec "precheck.c1|BLOCKED" | grep -q "FERRET_CRD_MISSING" && ok "12 an operator without the FerretDB CRD: FERRET_CRD_MISSING" || bad "12 ferret crd" "$(cat "$TMP/records")"
: > "$TMP/records"
S_OPERATOR=ours S_TRACKED=yes S_APPRES=yes bash "$TMP/day0-precheck.sh" wf c1 > "$TMP/out" 2>&1 || true
rec "precheck.c1|MANAGED" | grep -q . && ok "12 FerretDB on postgres-17.6 with the CRD passes" || bad "12 ferret pass" "$(cat "$TMP/records")"
# discover: a values patch file switches the scheduler; the inventory follows it
reset
printf 'backup:\n  scheduled: false\n  operatorSchedules: {full: "0 0 * * 0"}\nferret: {enabled: true}\n' > "$REPO/charts/tpg-instance/patches/sched.yaml"
cp "$TMP/fleet.base.yaml" "$REPO/clusters/fleet.yaml"
yq -i '.clusters.c1.instances["orders-db"].patches.values.current = "patches/sched.yaml"' "$TMP/fleet.yaml"
RC=0; P_FILTER=none bash "$TMP/discover.sh" wf c1 > "$TMP/out" 2>&1 || RC=$?
jq -e '.[0].instances[0] | .scheduledBackups == false and .backupMode == "operator" and .ferret == true' /tmp/inventory.json >/dev/null \
  && jq -e '.[0] | .cluster == "c1" and .scheduled == "false"' /tmp/instance-items.json >/dev/null \
  && ok "12 discover: a values patch that switches to operator schedules takes the instance out of the CronWorkflows" \
  || bad "12 discover patch" "$(cat /tmp/inventory.json) $(cat "$TMP/out")"
rm -f "$REPO/charts/tpg-instance/patches/sched.yaml"
# discover after a tpg-create-instance plan: the stored file exists only in the plan
# step's clone; discover writes it from patchFiles (Round 14), so the scheduler follows it
reset
printf 'backup:\n  scheduled: false\n  operatorSchedules: {full: "0 0 * * 0"}\n' > "$TMP/sched-src.yaml"
PF_SCHED="$(jq -cn --arg b "$(base64 < "$TMP/sched-src.yaml" | tr -d '\n')" '{"sched-src.yaml": $b}')"
S_OPERATOR=ours S_RUNNING="orders-db" env FLEET_MODE=create P_CLUSTERS=c1 P_INSTANCES=new-db P_HA=false P_POSTGRES_VERSION=postgres-17.6 \
  P_VALUES_PATCH_FILES=sched-src.yaml P_PATCH_FILES="$PF_SCHED" bash "$TMP/fleet-day0.sh" wf '["c1"]' > "$TMP/out" 2>&1 || true
rm -rf "$TMP/work/repo" "$TMP/work/patch-files.json"
RC=0; P_PATCH_FILES="$PF_SCHED" P_FILTER=pairs P_INSTANCES=new-db bash "$TMP/discover.sh" wf c1 "$(cat /tmp/fleet.json)" > "$TMP/out" 2>&1 || RC=$?
jq -e '.[0].instances[] | select(.name == "new-db") | .backupMode == "operator" and .scheduledBackups == false' /tmp/inventory.json >/dev/null \
  && ok "12 discover writes the planned patch file of a new instance: its backup scheduler is seen" \
  || bad "12 discover materialize" "$(cat /tmp/inventory.json 2>/dev/null) $(cat "$TMP/out")"

echo
echo "day0-plan: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
