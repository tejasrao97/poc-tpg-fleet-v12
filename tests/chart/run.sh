#!/usr/bin/env bash
# charts/tpg-instance rendering of the Round 12 values (design decisions D63 to D65):
#   exposure        serviceType and the Azure load balancer annotations; an empty
#                   map is never rendered (F7); instance.serviceType is refused
#   caBundle        written with enableSSL: true, and only then; enableSSL: true
#                   without a bundle fails the render
#   network policy  none renders nothing; baseline renders NetworkPolicy
#                   tpg-ingress and CiliumNetworkPolicy tpg-egress; a rule is
#                   rendered only for a non-empty input, and no peer list is
#                   empty (an empty peer list allows every source: F9)
#   Round 13 (D69 to D71)
#   zero defaults   highAvailability only for an HA instance (enabled true,
#                   readReplicas 1 or more), refused combinations, tpg.prune on
#                   patch file content, required fields kept, enableSSL false kept
#   schedules       PostgresBackupSchedule objects only with backup.scheduled false
#   FerretDB        PostgresFerretDocumentDB (version, read-only proxies, exposure)
#                   and its client rule on 27017
#   reference       every rendered object is what charts/crd-reference renders
#                   for the same spec (already pruned), and passes kubeconform
#                   -strict against the CRD schemas when kubeconform is installed
#   Round 14 (D78)
#   patch files     only the current file of each kind is applied; with
#                   clusters/fleet.yaml as a value file (the tpg-instances
#                   ApplicationSet) the instance's entry there decides, not the
#                   patches the inline values carry; a Round 11 list of one file
#                   counts, a longer list fails the render
# Requires: helm (v3 or v4), yq (mikefarah), python3 with PyYAML; skipped without them.
# shellcheck disable=SC2015
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
for t in helm yq; do command -v "$t" >/dev/null || { echo "SKIP tests/chart: $t not installed" >&2; exit 0; }; done
python3 -c "import yaml" 2>/dev/null || { echo "SKIP tests/chart: python3 PyYAML not installed" >&2; exit 0; }
yq --version 2>&1 | grep -q mikefarah || { echo "SKIP tests/chart: yq is not mikefarah yq v4" >&2; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/       | /' | tail -12; FAIL=$((FAIL + 1)); }
CHART="$ROOT/charts/tpg-instance"
render() {  # render VALUES_YAML -> $OUT (rendered manifests) and $RC
  printf 'cluster: {name: c1}\ninstance: {name: i1, postgresVersion: postgres-17.6}\nbackup: {container: pg-backups-c1}\n' > "$TMP/base.yaml"
  printf '%s\n' "$1" > "$TMP/v.yaml"
  RC=0
  OUT="$(helm template i1 "$CHART" -f "$ROOT/clusters/_template/cluster.yaml" \
    -f "$ROOT/clusters/_template/instance.yaml" -f "$TMP/base.yaml" -f "$TMP/v.yaml" --namespace pg-i1 2>&1)" || RC=$?
}
pg() { yq "select(.kind == \"Postgres\") | $1" <<<"$OUT"; }
f9() {  # every NetworkPolicy ingress rule has a non-empty from, and no peer is all
        # empty selectors ({namespaceSelector: {}} alone would admit every pod of
        # every namespace); {podSelector: {}} alone is the instance namespace itself
  pycheck 'all(r.get("from") and all(p == {"podSelector": {}} or any(p.values()) for p in r["from"])
           for r in K("NetworkPolicy")["spec"]["ingress"])'
}

pycheck() {  # pycheck PYTHON_EXPR: true when the expression holds; K(kind) is the rendered object of that kind
  python3 -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
def K(kind):
    return next(d for d in docs if d.get("kind") == kind)
def egress(): return K("CiliumNetworkPolicy")["spec"]["egress"]
def ports(rule): return [p["port"] for p in rule["toPorts"][0]["ports"]]
sys.exit(0 if eval("(" + sys.argv[1] + ")") else 1)
' "$1" <<<"$OUT" 2>/dev/null
}

# ---- exposure
render ''
[[ "$(pg '.spec.serviceType')" == "ClusterIP" && "$(pg '.spec | has("serviceAnnotations")')" == "false" \
   && "$(pg '.spec | has("readOnlyServiceType")')" == "false" ]] \
  && ok "default: ClusterIP, no annotations, no readOnlyServiceType (existing specs unchanged)" || bad "default" "$OUT"
render 'instance: {exposure: internalLoadBalancer, internalLoadBalancerSubnet: apps-subnet, allowedSourceRanges: [10.0.0.0/8, 192.168.0.0/16]}'
pg '.spec' | yq -e '.serviceType == "LoadBalancer"
  and .serviceAnnotations["service.beta.kubernetes.io/azure-load-balancer-internal"] == "true"
  and .serviceAnnotations["service.beta.kubernetes.io/azure-load-balancer-internal-subnet"] == "apps-subnet"
  and .serviceAnnotations["service.beta.kubernetes.io/azure-allowed-ip-ranges"] == "10.0.0.0/8,192.168.0.0/16"' >/dev/null \
  && ok "internalLoadBalancer: internal annotation, subnet and allowed ranges" || bad "internal" "$(pg '.spec')"
render 'instance: {exposure: loadBalancer, serviceAnnotations: {service.beta.kubernetes.io/azure-dns-label-name: orders}, readOnlyExposure: loadBalancer}'
pg '.spec' | yq -e '.serviceType == "LoadBalancer" and .readOnlyServiceType == "LoadBalancer"
  and (.serviceAnnotations | has("service.beta.kubernetes.io/azure-load-balancer-internal") | not)
  and .serviceAnnotations["service.beta.kubernetes.io/azure-dns-label-name"] == "orders"
  and (has("readOnlyServiceAnnotations") | not)' >/dev/null \
  && ok "loadBalancer: public, extra annotations kept, no empty read-only annotations" || bad "public" "$(pg '.spec')"
render 'instance: {exposure: nodePort}'
[[ "$RC" -ne 0 ]] && grep -q "must be clusterIP, internalLoadBalancer or loadBalancer" <<<"$OUT" && ok "an unknown exposure fails the render" || bad "unknown exposure" "$OUT"
render 'instance: {serviceType: LoadBalancer}'
[[ "$RC" -ne 0 ]] && grep -q "instance.serviceType is replaced by instance.exposure" <<<"$OUT" && ok "instance.serviceType fails with the replacement named" || bad "serviceType" "$OUT"

# ---- caBundle
render 'backup: {enableSSL: true}'
[[ "$RC" -ne 0 ]] && grep -q "caBundle is empty" <<<"$OUT" && ok "enableSSL: true without caBundle fails the render" || bad "no bundle" "$OUT"
render 'backup: {enableSSL: true, caBundle: "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"}'
pycheck 'K("PostgresBackupLocation")["spec"]["storage"]["azure"]["enableSSL"] is True and K("PostgresBackupLocation")["spec"]["storage"]["azure"]["caBundle"].startswith("-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----")' \
  && ok "enableSSL: true writes the bundle" || bad "bundle" "$(yq 'select(.kind == "PostgresBackupLocation")' <<<"$OUT")"
render 'backup: {enableSSL: false, caBundle: "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"}'
pycheck 'K("PostgresBackupLocation")["spec"]["storage"]["azure"]["enableSSL"] is False and "caBundle" not in K("PostgresBackupLocation")["spec"]["storage"]["azure"]' \
  && ok "enableSSL: false writes no caBundle" || bad "no ca with ssl false" "$OUT"

# ---- network policy
render ''
[[ -z "$(yq 'select(.kind == "NetworkPolicy" or .kind == "CiliumNetworkPolicy") | .kind' <<<"$OUT")" ]] \
  && ok "policy none: no policy objects" || bad "none" "$OUT"
render 'network: {policy: baseline}'
[[ "$(yq 'select(.kind == "NetworkPolicy") | .spec.ingress | length' <<<"$OUT")" == "3" ]] && f9 \
  && ok "baseline: ingress rules for the namespace, the operator and metrics only, no empty peer list" || bad "baseline ingress" "$OUT"
pycheck 'any(r.get("toEntities") == ["kube-apiserver"] for r in egress())
  and any(r.get("toEntities") == ["world"] and ports(r) == ["443", "80"] for r in egress())
  and not any("toFQDNs" in r for r in egress())' \
  && ok "baseline: API server, and backup egress to any address on 443 and 80 (enableSSL false, no ACNS)" || bad "baseline egress" "$(yq 'select(.kind == "CiliumNetworkPolicy")' <<<"$OUT")"
render 'network: {policy: baseline, acns: true}
backup: {enableSSL: true, caBundle: "x"}'
pycheck 'any(r.get("toFQDNs") == [{"matchPattern": "*.blob.core.windows.net"}] and ports(r) == ["443"] for r in egress())
  and any(r.get("toPorts", [{}])[0].get("rules", {}).get("dns") == [{"matchPattern": "*"}] for r in egress())
  and not any(r.get("toEntities") == ["world"] for r in egress())' \
  && ok "ACNS: backup egress by FQDN on 443 only (enableSSL true), with the DNS proxy rule" || bad "acns" "$(yq 'select(.kind == "CiliumNetworkPolicy")' <<<"$OUT")"
render 'network: {policy: baseline, ingressFromNamespaces: [app], ingressFromPodLabels: {role: api}, ingressFromCidrs: [10.1.0.0/16], egressToCidrs: [10.2.0.0/24], egressToFqdns: [api.example.com, "*.example.org"]}
instance: {exposure: loadBalancer, allowedSourceRanges: [10.1.0.0/16]}'
pycheck 'K("NetworkPolicy")["spec"]["ingress"][3] == {"from": [
    {"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "app"}}, "podSelector": {"matchLabels": {"role": "api"}}},
    {"ipBlock": {"cidr": "10.1.0.0/16"}}, {"ipBlock": {"cidr": "168.63.129.16/32"}}],
  "ports": [{"protocol": "TCP", "port": 5432}]}' && f9 \
  && ok "client rules: namespace with pod labels, CIDR, and the Azure health probe for a load balancer" || bad "client rules" "$(yq 'select(.kind == "NetworkPolicy")' <<<"$OUT")"
pycheck 'any(r.get("toCIDR") == ["10.2.0.0/24"] for r in egress())
  and any(r.get("toFQDNs") == [{"matchName": "api.example.com"}, {"matchPattern": "*.example.org"}] for r in egress())' \
  && ok "egress rules: toCIDR and toFQDNs (matchName and matchPattern)" || bad "egress rules" "$(yq 'select(.kind == "CiliumNetworkPolicy")' <<<"$OUT")"
render 'network: {policy: baseline, ingressFromNamespaces: [], ingressFromPodLabels: {}, ingressFromCidrs: [], egressToCidrs: [], egressToFqdns: [], monitoringNamespaces: []}'
[[ "$(yq 'select(.kind == "NetworkPolicy") | .spec.ingress | length' <<<"$OUT")" == "2" ]] && f9 \
  && pycheck 'not any("toFQDNs" in r or ("toCIDR" in r and r["toCIDR"] != ["169.254.10.0/24"]) for r in egress())' \
  && ok "empty rule lists and maps render no rule at all (F9)" || bad "empty lists" "$OUT"
render 'network: {policy: baseline, ingressFromPodLabels: {role: api}}'
pycheck 'K("NetworkPolicy")["spec"]["ingress"][3]["from"] == [{"namespaceSelector": {}, "podSelector": {"matchLabels": {"role": "api"}}}]' \
  && ok "pod labels without namespaces: those pods in any namespace" || bad "labels only" "$(yq 'select(.kind == "NetworkPolicy")' <<<"$OUT")"

# ---- Round 13: zero defaults (D69)
kindspec() { yq "select(.kind == \"$1\") | .spec" <<<"$OUT"; }
render 'instance: {highAvailability: {enabled: false, readReplicas: 0}}'
[[ "$RC" -eq 0 && "$(pg '.spec | has("highAvailability")')" == "false" ]] \
  && ok "single node (false, 0): no highAvailability block (D69)" || bad "single node" "$OUT"
render 'instance: {highAvailability: {enabled: true, readReplicas: 2}}'
[[ "$(pg '.spec.highAvailability' | yq '.enabled == true and .readReplicas == 2')" == "true" ]] \
  && ok "HA: enabled true and readReplicas 2 are written" || bad "ha" "$OUT"
render 'instance: {highAvailability: {enabled: true, readReplicas: 0}}'
[[ "$RC" -ne 0 ]] && grep -q "an HA instance needs readReplicas 1 or more" <<<"$OUT" && ok "enabled true with readReplicas 0 fails the render" || bad "ha 0" "$OUT"
render 'instance: {highAvailability: {enabled: false, readReplicas: 2}}'
[[ "$RC" -ne 0 ]] && grep -q "read replicas need highAvailability.enabled true" <<<"$OUT" && ok "readReplicas without enabled fails the render" || bad "rr only" "$OUT"
# patch file content is pruned too; a required field inside a kept object stays
CHART="$TMP/tpg-instance"; cp -r "$ROOT/charts/tpg-instance" "$CHART"
printf 'kind: Postgres\nspec:\n  dataPodConfig: {tolerations: []}\n  deploymentOptions: {continuousRestoreTarget: false}\n  customConfig: {initDb: {checksum: false}}\n' > "$CHART/patches/zero.yaml"
printf 'kind: Postgres\nspec:\n  deploymentOptions: {continuousRestoreTarget: false, sourceStanzaName: pg-src-0}\n' > "$CHART/patches/keep.yaml"
render 'patches: {postgres: [patches/zero.yaml]}'
[[ "$(pg '.spec' | yq 'has("dataPodConfig") or has("deploymentOptions") or has("customConfig")')" == "false" ]] \
  && ok "patch content holding zero defaults is left out, with the parents it empties" || bad "patch prune" "$(pg '.spec')"
render 'patches: {postgres: [patches/keep.yaml]}'
[[ "$(pg '.spec.deploymentOptions' | yq '.continuousRestoreTarget == false and .sourceStanzaName == "pg-src-0"')" == "true" ]] \
  && ok "continuousRestoreTarget false is kept when deploymentOptions holds more (required by the schema)" || bad "required kept" "$(pg '.spec')"
CHART="$ROOT/charts/tpg-instance"
render 'backup: {additionalParameters: {}, forcePathStyle: false}'
pycheck 'K("PostgresBackupLocation")["spec"]["storage"]["azure"]["enableSSL"] is False
  and "forcePathStyle" not in K("PostgresBackupLocation")["spec"]["storage"]["azure"]
  and "additionalParameters" not in K("PostgresBackupLocation")["spec"]
  and K("PostgresBackupLocation")["spec"]["backupSync"] == {"enabled": True}' \
  && ok "backup location: enableSSL false kept (CRD default true), forcePathStyle false and {} left out" || bad "bl" "$(kindspec PostgresBackupLocation)"

# ---- Round 13: operator backup schedules (D70)
render 'backup: {scheduled: false, operatorSchedules: {full: "0 0 * * 0", incremental: "0 0 * * 1-6"}}'
[[ "$(yq 'select(.kind == "PostgresBackupSchedule") | (.metadata.name + " " + .spec.schedule + " " + .spec.backupTemplate.spec.type)' <<<"$OUT" | grep -v '^---' | paste -sd';')" \
   == "i1-backup-full 0 0 * * 0 full;i1-backup-incremental 0 0 * * 1-6 incremental" ]] \
  && ok "operatorSchedules: a full and an incremental PostgresBackupSchedule (sync wave 2)" || bad "schedules" "$OUT"
render 'backup: {scheduled: false, operatorSchedules: {full: "0 0 * * 0"}}'
[[ "$(yq 'select(.kind == "PostgresBackupSchedule") | .metadata.name' <<<"$OUT")" == "i1-backup-full" ]] \
  && ok "operatorSchedules without incremental: the full schedule only" || bad "full only" "$OUT"
render 'backup: {operatorSchedules: {full: "0 0 * * 0"}}'
[[ "$RC" -ne 0 ]] && grep -q "needs backup.scheduled: false" <<<"$OUT" && ok "operatorSchedules while the CronWorkflows still back up: refused" || bad "both" "$OUT"
render 'backup: {scheduled: false, operatorSchedules: {full: "weekly"}}'
[[ "$RC" -ne 0 ]] && grep -q "is not a cron schedule of 5 fields" <<<"$OUT" && ok "a schedule that is not cron fails the render" || bad "cron" "$OUT"
render ''
[[ -z "$(yq 'select(.kind == "PostgresBackupSchedule") | .kind' <<<"$OUT")" ]] && ok "no operatorSchedules: no PostgresBackupSchedule" || bad "none" "$OUT"

# ---- Round 13: FerretDB (D71)
render 'ferret: {enabled: true}'
[[ "$(kindspec PostgresFerretDocumentDB | yq '.readWrite.replicas == 1 and (has("readOnly") | not)
   and .postgres.connectionDetails.readWrite.secretName == "i1-app-user-db-secret" and .service.serviceType == "ClusterIP"
   and (.service | has("serviceAnnotations") | not)')" == "true" ]] \
  && ok "ferret: one read-write proxy, no readOnly section, the operator Secret by default, ClusterIP" || bad "ferret" "$OUT"
render 'instance: {postgresVersion: postgres-17.4}
ferret: {enabled: true}'
[[ "$RC" -ne 0 ]] && grep -q "needs Postgres 17.5 or later" <<<"$OUT" && ok "ferret below Postgres 17.5 fails the render" || bad "ferret version" "$OUT"
render 'instance: {highAvailability: {enabled: false, readReplicas: 0}}
ferret: {enabled: true, readOnlyReplicas: 1}'
[[ "$RC" -ne 0 ]] && grep -q "needs highAvailability" <<<"$OUT" && ok "read-only proxies on a single node fail the render" || bad "ferret ro" "$OUT"
render 'instance: {highAvailability: {enabled: true, readReplicas: 1}, allowedSourceRanges: [10.0.0.0/8]}
ferret: {enabled: true, replicas: 2, readOnlyReplicas: 1, exposure: internalLoadBalancer, readOnlySecretName: ro-secret}'
[[ "$(kindspec PostgresFerretDocumentDB | yq '.readWrite.replicas == 2 and .readOnly.replicas == 1
   and .postgres.connectionDetails.readOnly.secretName == "ro-secret" and .service.readOnlyServiceType == "LoadBalancer"
   and .service.serviceAnnotations["service.beta.kubernetes.io/azure-load-balancer-internal"] == "true"
   and .service.serviceAnnotations["service.beta.kubernetes.io/azure-allowed-ip-ranges"] == "10.0.0.0/8"')" == "true" ]] \
  && ok "ferret: read-only proxies with their Secret, internal load balancers with the instance's ranges" || bad "ferret ha" "$OUT"
render 'network: {policy: baseline, ingressFromNamespaces: [app]}
ferret: {enabled: true, exposure: loadBalancer}'
pycheck 'K("NetworkPolicy")["spec"]["ingress"][4] == {"from": [
    {"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "app"}}}, {"ipBlock": {"cidr": "168.63.129.16/32"}}],
  "ports": [{"protocol": "TCP", "port": 27017}]}' && f9 \
  && ok "ferret with baseline: 27017 from the same clients, with the probe address for its load balancer" || bad "ferret netpol" "$(yq 'select(.kind == "NetworkPolicy")' <<<"$OUT")"
render 'network: {policy: baseline, ingressFromNamespaces: [app]}'
pycheck 'not any(p["port"] == 27017 for r in K("NetworkPolicy")["spec"]["ingress"] for p in r.get("ports", []))' \
  && ok "no FerretDB: no 27017 rule" || bad "no ferret rule" "$OUT"

# ---- Round 13: the reference chart renders the same objects (already pruned) and they pass the CRD schemas
render 'instance: {highAvailability: {enabled: true, readReplicas: 1}}
backup: {scheduled: false, operatorSchedules: {full: "0 0 * * 0", incremental: "0 0 * * 1-6"}}
ferret: {enabled: true, readOnlyReplicas: 1}'
same=1
for k in Postgres PostgresBackupLocation PostgresBackupSchedule PostgresFerretDocumentDB; do
  key="$(python3 -c 'import sys; k=sys.argv[1]; print(k[0].lower() + k[1:])' "$k")"
  K="$k" yq 'select(.kind == strenv(K)) | {"'"$key"'": {"enabled": true, "name": .metadata.name, "spec": .spec}}' <<<"$OUT" | head -n 200 > "$TMP/ref-$k.yaml"
  [[ "$k" != PostgresBackupSchedule ]] || K="$k" yq 'select(.kind == strenv(K) and .metadata.name == "i1-backup-full")
    | {"postgresBackupSchedule": {"enabled": true, "name": .metadata.name, "spec": .spec}}' <<<"$OUT" > "$TMP/ref-$k.yaml"
  want="$(K="$k" yq 'select(.kind == strenv(K)) | .spec' <<<"$OUT" | head -n 400)"
  [[ "$k" != PostgresBackupSchedule ]] || want="$(yq 'select(.metadata.name == "i1-backup-full") | .spec' <<<"$OUT")"
  got="$(helm template ref "$ROOT/charts/crd-reference" -f "$TMP/ref-$k.yaml" | K="$k" yq 'select(.kind == strenv(K)) | .spec')"
  [[ "$got" == "$want" ]] || { same=0; bad "reference $k" "$(diff <(echo "$want") <(echo "$got"))"; }
done
[[ "$same" -eq 1 ]] && ok "Postgres, backup location, schedule and FerretDB are what charts/crd-reference renders (nothing left to prune)"
if command -v kubeconform >/dev/null; then
  yq 'select(.apiVersion == "sql.tanzu.vmware.com/v1")' <<<"$OUT" > "$TMP/sql.yaml"
  kc="$(kubeconform -strict -summary -schema-location "$ROOT/charts/crd-reference/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" "$TMP/sql.yaml" 2>&1)" \
    && grep -q "Valid: 5, Invalid: 0, Errors: 0, Skipped: 0" <<<"$kc" \
    && ok "the 5 rendered sql.tanzu.vmware.com objects pass kubeconform -strict against the live CRD schemas" || bad "kubeconform" "$kc"
else
  echo "skip kubeconform (not installed)"
fi


# ---- valuesOverride (tpg-restore) wins over a values patch file that turns FerretDB on
cp -r "$ROOT/charts/tpg-instance" "$TMP/chart-copy"
printf 'ferret: {enabled: true}\n' > "$TMP/chart-copy/patches/t-ferret-on.yaml"
CHART="$TMP/chart-copy"
render 'patches: {values: [patches/t-ferret-on.yaml]}'
[[ "$RC" -eq 0 ]] && grep -q 'kind: PostgresFerretDocumentDB' <<<"$OUT" && ok "a values patch turns FerretDB on" || bad "values patch ferret" "$OUT"
render 'patches: {values: [patches/t-ferret-on.yaml]}
valuesOverride: {ferret: {enabled: false}}'
[[ "$RC" -eq 0 ]] && ! grep -q 'kind: PostgresFerretDocumentDB' <<<"$OUT" \
  && ok "valuesOverride (a restored copy) wins over the values patch: no FerretDB" || bad "valuesOverride" "$OUT"
CHART="$ROOT/charts/tpg-instance"

# ---- Round 14: the current patch file, read from clusters/fleet.yaml when it is a value file
cp -r "$ROOT/charts/tpg-instance" "$TMP/chart-r14"
CHART="$TMP/chart-r14"
printf 'backup: {fullRetention: 11}\n' > "$CHART/patches/cur-aaaaa.yaml"
printf 'backup: {fullRetention: 22}\n' > "$CHART/patches/prev-bbbbb.yaml"
printf 'backup: {fullRetention: 33}\n' > "$CHART/patches/inline-ccccc.yaml"
retention() { yq 'select(.kind == "PostgresBackupLocation") | .spec.retentionPolicy.fullRetention.number' <<<"$OUT"; }
render 'patches: {values: {current: patches/cur-aaaaa.yaml, previous: {path: patches/prev-bbbbb.yaml, commit: abc}}}'
[[ "$RC" -eq 0 && "$(retention)" == 11 ]] && ok "only current is applied; previous is a record" || bad "current" "$OUT"
render 'patches: {values: [patches/cur-aaaaa.yaml]}'
[[ "$RC" -eq 0 && "$(retention)" == 11 ]] && ok "a Round 11 list of one file counts as current" || bad "list of one" "$OUT"
render 'patches: {values: [patches/cur-aaaaa.yaml, patches/prev-bbbbb.yaml]}'
[[ "$RC" -ne 0 ]] && grep -q "lists 2 files: Round 14 applies one current file" <<<"$OUT" \
  && ok "a Round 11 list of several files fails the render with the migration note" || bad "list of two" "$OUT"
render 'patches: {values: {current: patches/inline-ccccc.yaml}}
clusters:
  c1:
    instances:
      i1:
        patches: {values: {current: patches/cur-aaaaa.yaml}}'
[[ "$RC" -eq 0 && "$(retention)" == 11 ]] \
  && ok "with clusters/fleet.yaml as a value file its entry wins (a sync at a pull request commit sees the branch)" || bad "fleet file" "$OUT"
render 'patches: {values: {current: patches/inline-ccccc.yaml}}
clusters:
  c1:
    instances:
      i1: {instance: {postgresVersion: postgres-17.6}}'
[[ "$RC" -eq 0 && "$(retention)" == 4 ]] \
  && ok "an entry without patches there: no patch file, whatever the inline values say" || bad "fleet file no patches" "$OUT"
render 'clusters:
  c1:
    instances:
      i1:
        patches: {values: {previous: {path: patches/cur-aaaaa.yaml, commit: abc}}}'
[[ "$RC" -eq 0 && "$(retention)" == 4 ]] && ok "a cleared patch (previous only) renders the chart values" || bad "cleared" "$OUT"
CHART="$ROOT/charts/tpg-instance"

echo
echo "chart: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
