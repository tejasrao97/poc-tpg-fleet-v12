#!/usr/bin/env bash
# Static validation of tpg-fleet. Requires: yamllint, shellcheck, kustomize,
# helm, kubeconform, python3 (PyYAML), jq, yq v4.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
CATALOG='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

echo "== yamllint";   yamllint -s .
echo "== shellcheck"; shellcheck -x -e SC1091 workflows/scripts/*.sh scripts/*.sh scripts/submit/*.sh tests/*.sh tests/*/*.sh monitoring/grafana/import-azure-grafana.sh

# Flags the pinned CLIs no longer accept (helm list -a under Helm 4, and the
# rest of tests/cli-flags/rules.yaml), plus helm-addons.sh against a Helm 4 CLI.
echo "== tests"; tests/run-all.sh

echo "== kustomize build"
for d in workflows platform/base monitoring/azure/targets monitoring/azure/hub monitoring/standalone/targets monitoring/standalone/hub; do
  kustomize build "$d" > "$OUT/$(tr / _ <<<"$d").yaml"
  echo "ok $d"
done

echo "== CRD reference (zero-default registry, reference templates and schemas up to date)"
python3 tools/crd-defaults/generate.py --check
echo "ok charts/crd-reference and charts/tpg-instance/files/zero-defaults.yaml"

echo "== workflow input types and patch file schemas (generated files up to date)"
python3 workflows/params/generate.py --check
echo "ok workflows/admission/workflow-parameters.yaml and workflows/params/patch-schemas.json"

# patch_current FLEET_FILE CLUSTER INSTANCE KIND -> the current patch file (Round 14:
# {current, previous}; a Round 11 list of one file counts; a longer list stops here)
patch_current() {
  local p v
  if [[ "$4" == operator ]]; then p=".clusters[\"$2\"].operator.patches.values"
  else p=".clusters[\"$2\"].instances[\"$3\"].patches.$4"; fi
  v="$(yq -o=json -I=0 "$p // null" "$1" | jq -r 'if type == "array" then (if length <= 1 then (.[0] // "") else "LIST:\(length)" end)
    elif type == "object" then (.current // "") elif type == "string" then . else "" end')"
  if [[ "$v" == LIST:* ]]; then
    echo "$1: ${2}${3:+/$3} lists ${v#LIST:} ${4} patch files: Round 14 applies one current file;" >&2
    echo "  merge them into one file and apply it with tpg-patch (tpg-fleet README, Upgrading to Round 14)" >&2
    exit 1
  fi
  printf '%s' "$v"
}

echo "== fleet.yaml structure (clusters/fleet.yaml and clusters/fleet.example.yaml)"
for ff in clusters/fleet.yaml clusters/fleet.example.yaml; do
  yq -e '.clusters | type == "!!map"' "$ff" >/dev/null
  for c in $(yq -r '.clusters | keys | .[]' "$ff"); do
    C="$c" yq -e '.clusters[strenv(C)].operator.version | type == "!!str"' "$ff" >/dev/null \
      || { echo "${ff}: clusters.${c}.operator.version is required" >&2; exit 1; }
    # Round 14 (D76): operator manifest patches are gone
    if C="$c" yq -e '.clusters[strenv(C)].operator.patches | has("manifests")' "$ff" >/dev/null 2>&1; then
      echo "${ff}: clusters.${c}.operator.patches.manifests: operator manifest patches were removed in Round 14;" >&2
      echo "  move the change to an operator values file (tpg-patch operatorValuesPatchFilePath) or delete the entry," >&2
      echo "  then release the fields the tpg-patch field manager still owns (tpg-fleet README, Upgrading to Round 14)" >&2
      exit 1
    fi
    f="$(patch_current "$ff" "$c" "" operator)"
    if [[ -n "$f" ]]; then
      [[ -f "$f" ]] || { echo "${ff}: clusters.${c}.operator.patches.values.current is ${f}, which does not exist" >&2; exit 1; }
      # clusters/fleet.yaml only: the tpg-operator Application reads the effective copy
      if [[ "$ff" == clusters/fleet.yaml ]]; then
        e="patches/operator/clusters/${c}.yaml"
        [[ -f "$e" ]] || { echo "${ff}: ${e} is missing: it must hold the values of ${f} (tpg-patch writes it)" >&2; exit 1; }
        [[ "$(yq -o=json -I=0 '.' "$e")" == "$(yq -o=json -I=0 '.' "$f")" ]] \
          || { echo "${e} differs from ${f}, the current operator values of ${c}; do not edit it by hand (run tpg-patch)" >&2; exit 1; }
      fi
    fi
    for i in $(C="$c" yq -r '.clusters[strenv(C)].instances // {} | keys | .[]' "$ff"); do
      C="$c" I="$i" yq -e '.clusters[strenv(C)].instances[strenv(I)].instance.postgresVersion | test("^postgres-[0-9]")' "$ff" >/dev/null \
        || { echo "${ff}: clusters.${c}.instances.${i}.instance.postgresVersion is required (postgres-<version>)" >&2; exit 1; }
      for k in postgres values; do
        f="$(patch_current "$ff" "$c" "$i" "$k")"
        [[ -z "$f" || -f "charts/tpg-instance/$f" ]] \
          || { echo "${ff}: ${c}/${i} patches.${k} is charts/tpg-instance/${f}, which does not exist" >&2; exit 1; }
      done
    done
  done
  echo "ok ${ff}"
done
# every effective operator values file belongs to a cluster with a current file
for e in patches/operator/clusters/*.yaml; do
  [[ -f "$e" ]] || continue
  c="$(basename "$e" .yaml)"
  [[ -n "$(patch_current clusters/fleet.yaml "$c" "" operator)" ]] \
    || { echo "${e}: ${c} has no current operator values file in clusters/fleet.yaml; remove it (tpg-patch patchMode=clear does)" >&2; exit 1; }
done

# values_for FLEET_FILE CLUSTER INSTANCE -> the Helm values the tpg-instances ApplicationSet passes
# shellcheck disable=SC2016  # yq variables, not shell
values_for() {
  C="$2" I="$3" yq '.clusters[strenv(C)] as $c | ($c.instances[strenv(I)] // {}) as $i
    | ($c | with_entries(select(.key != "instances" and .key != "operator")))
    * {"cluster": {"name": strenv(C)}, "backup": {"container": "pg-backups-" + strenv(C)}}
    * $i * {"instance": {"name": strenv(I)}}' "$1"
}

echo "== helm lint / template (every instance of fleet.yaml and fleet.example.yaml, patch files included)"
mkdir -p "$OUT/values"
render_failed=()   # every entry that does not render, named, before the script stops
for ff in clusters/fleet.yaml clusters/fleet.example.yaml; do
for c in $(yq -r '.clusters | keys | .[]' "$ff"); do
  for i in $(C="$c" yq -r '.clusters[strenv(C)].instances // {} | keys | .[]' "$ff"); do
    values_for "$ff" "$c" "$i" | yq 'del(.patches)' > "$OUT/values/$c-$i.yaml"
    # the value files of the tpg-instances ApplicationSet: the fleet file carries the patch references (Round 14)
    set -- -f clusters/_template/cluster.yaml -f clusters/_template/instance.yaml -f "$ff" -f "$OUT/values/$c-$i.yaml"
    if ! helm template "$i" charts/tpg-instance "$@" --namespace "pg-$i" > "$OUT/chart_${c}_${i}.yaml" 2> "$OUT/render.err"; then
      render_failed+=("${ff}: ${c}/${i}: $(grep -v '^[[:space:]]*$' "$OUT/render.err" | tail -n 2 | tr '\n' ' ')")
      continue
    fi
    helm lint charts/tpg-instance "$@" >/dev/null
    # PostgresBackupLocation must not carry the two fields the CRD drops on
    # apply (spec.additionalParameters when empty, spec.storage.azure.forcePathStyle
    # when false). Rendering them makes the Application OutOfSync for good.
    if yq 'select(.kind == "PostgresBackupLocation") | .spec
           | ((has("additionalParameters") and ((.additionalParameters // {}) | length) == 0),
              ((.storage.azure | has("forcePathStyle")) and .storage.azure.forcePathStyle != true))' \
         "$OUT/chart_${c}_${i}.yaml" | grep -qx true; then
      echo "PostgresBackupLocation for ${c}/${i} renders an empty additionalParameters or forcePathStyle: false;" >&2
      echo "the CRD drops both on apply and the Application never reaches Synced" >&2
      exit 1
    fi
    echo "ok ${ff}: ${c}/${i}"
  done
done
done
if [[ "${#render_failed[@]}" -gt 0 ]]; then
  echo "These fleet.yaml entries do not render, each with the chart's message. An entry with highAvailability" >&2
  echo "enabled true and readReplicas 0 (tpg-scale-instance replicas=0 before Round 13) needs tpg-scale-instance" >&2
  echo "with replicas=0 (single node) or replicas=1:" >&2
  printf '  %s\n' "${render_failed[@]}" >&2
  exit 1
fi

echo "== chart: patch files are merged"
# The example patches of clusters/fleet.example.yaml reach the rendered objects
got="$(helm template orders-db charts/tpg-instance -f clusters/_template/cluster.yaml -f clusters/_template/instance.yaml \
  -f clusters/fleet.example.yaml -f "$OUT/values/aks-tpg-poc-01-orders-db.yaml" --namespace pg-orders-db \
  | yq 'select(.kind == "Postgres") | .spec.resources.data.limits.memory')"
[[ "$got" == "8Gi" ]] || { echo "postgres patch not merged: limits.memory is '${got}', expected 8Gi" >&2; exit 1; }
got="$(helm template orders-db charts/tpg-instance -f clusters/_template/cluster.yaml -f clusters/_template/instance.yaml \
  -f clusters/fleet.example.yaml -f "$OUT/values/aks-tpg-poc-02-orders-db.yaml" --namespace pg-orders-db \
  | yq 'select(.kind == "PostgresBackupLocation") | .spec.retentionPolicy.fullRetention.number')"
[[ "$got" == "6" ]] || { echo "values patch not merged: fullRetention is '${got}', expected 6" >&2; exit 1; }
echo "ok postgres and values patch files (the current file of clusters/fleet.example.yaml)"

echo "== chart: enableSSL of the backup location"
# Always rendered, false by default (clusters/_template/cluster.yaml and the
# chart), true when a cluster or instance sets backup.enableSSL: true.
base=(-f clusters/_template/cluster.yaml -f clusters/_template/instance.yaml
      --set cluster.name=c1 --set instance.name=i1 --set instance.postgresVersion=postgres-17.6
      --set backup.container=pg-backups-c1)
for want in false true; do
  extra=(); [[ "$want" == "false" ]] || extra=(--set backup.enableSSL=true --set backup.caBundle=PEM)
  got="$(helm template i1 charts/tpg-instance "${base[@]}" "${extra[@]}" --namespace pg-i1 \
    | yq 'select(.kind == "PostgresBackupLocation") | .spec.storage.azure.enableSSL')"
  [[ "$got" == "$want" ]] || { echo "PostgresBackupLocation enableSSL renders '${got}', expected ${want}" >&2; exit 1; }
  echo "ok enableSSL ${want}"
done
# The ApplicationSet must leave spec.postgresVersion of a running instance to
# the PostgresVersionUpgrade (tpg-upgrade), and ignore enableSSL false.
yq -e '.spec.template.spec.ignoreDifferences[] | select(.kind == "Postgres") | .jsonPointers[] | select(. == "/spec/postgresVersion")' \
  bootstrap/appsets/tpg-instances.yaml >/dev/null
yq -e '.spec.template.spec.syncPolicy.syncOptions[] | select(. == "RespectIgnoreDifferences=true")' \
  bootstrap/appsets/tpg-instances.yaml >/dev/null
echo "ok tpg-instances ignores Postgres spec.postgresVersion (RespectIgnoreDifferences)"

echo "== chart: exposure and network policy"
# Detailed cases in tests/chart; here one render of every new object for kubeconform
printf 'instance: {exposure: internalLoadBalancer}\nnetwork: {policy: baseline, ingressFromNamespaces: [app]}\n' > "$OUT/values/exposure-netpol.yaml"
helm template i1 charts/tpg-instance "${base[@]}" -f "$OUT/values/exposure-netpol.yaml" --namespace pg-i1 > "$OUT/chart_exposure_netpol.yaml"
for k in NetworkPolicy CiliumNetworkPolicy; do
  K="$k" yq -e 'select(.kind == strenv(K)) | .metadata.name' "$OUT/chart_exposure_netpol.yaml" >/dev/null \
    || { echo "network.policy baseline renders no ${k}" >&2; exit 1; }
done
[[ "$(yq 'select(.kind == "Postgres") | .spec.serviceType' "$OUT/chart_exposure_netpol.yaml")" == "LoadBalancer" ]] \
  || { echo "exposure internalLoadBalancer does not render serviceType LoadBalancer" >&2; exit 1; }
if helm template i1 charts/tpg-instance "${base[@]}" --set instance.serviceType=LoadBalancer --namespace pg-i1 >/dev/null 2>&1; then
  echo "instance.serviceType must fail the render (replaced by instance.exposure)" >&2; exit 1
fi
echo "ok exposure, NetworkPolicy tpg-ingress, CiliumNetworkPolicy tpg-egress"

echo "== chart: backup schedules and FerretDB (D70, D71)"
# Detailed cases in tests/chart; here one render of both new kinds for kubeconform
printf 'instance: {highAvailability: {enabled: true, readReplicas: 1}}\nbackup: {scheduled: false, operatorSchedules: {full: "0 0 * * 0", incremental: "0 0 * * 1-6"}}\nferret: {enabled: true, readOnlyReplicas: 1}\n' > "$OUT/values/schedule-ferret.yaml"
helm template i1 charts/tpg-instance "${base[@]}" -f "$OUT/values/schedule-ferret.yaml" --namespace pg-i1 > "$OUT/chart_schedule_ferret.yaml"
for k in PostgresBackupSchedule PostgresFerretDocumentDB; do
  K="$k" yq -e 'select(.kind == strenv(K)) | .metadata.name' "$OUT/chart_schedule_ferret.yaml" >/dev/null \
    || { echo "the schedule and FerretDB values render no ${k}" >&2; exit 1; }
done
# A single node renders no highAvailability block (D69)
got="$(helm template i1 charts/tpg-instance "${base[@]}" --set instance.highAvailability.enabled=false \
  --set instance.highAvailability.readReplicas=0 --namespace pg-i1 | yq 'select(.kind == "Postgres") | .spec | has("highAvailability")')"
[[ "$got" == "false" ]] || { echo "a single-node instance must not render spec.highAvailability (D69)" >&2; exit 1; }
echo "ok PostgresBackupSchedule, PostgresFerretDocumentDB, no highAvailability for a single node"
# The 9 reference templates with their examples (kubeconform checks them below)
refargs=(); for f in charts/crd-reference/examples/*.yaml; do refargs+=(-f "$f"); done
helm template ref charts/crd-reference "${refargs[@]}" > "$OUT/crd_reference.yaml"
echo "ok charts/crd-reference renders the 9 examples"

echo "== kubeconform"
cp bootstrap/*.yaml bootstrap/appsets/*.yaml "$OUT/"
for f in bootstrap/monitoring/*/*.yaml; do cp "$f" "$OUT/$(tr / _ <<<"$f")"; done
# The Tanzu Postgres kinds against the live 4.5 CRD schemas (charts/crd-reference/schemas)
kubeconform -strict -summary -ignore-missing-schemas \
  -schema-location default -schema-location 'charts/crd-reference/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  -schema-location "$CATALOG" "$OUT"/*.yaml

echo "== JSON"
for d in tpg-fleet tpg-instance tpg-replication tpg-backup tpg-alerts; do
  jq -e --arg u "$d" '.uid == $u and (.panels | length > 0)' "monitoring/standalone/hub/dashboards/${d}.json" >/dev/null \
    || { echo "dashboard ${d} is missing or empty (run monitoring/grafana/generate.py)" >&2; exit 1; }
  grep -q "dashboards/${d}.json" monitoring/standalone/hub/kustomization.yaml \
    || { echo "dashboard ${d} is not in monitoring/standalone/hub/kustomization.yaml" >&2; exit 1; }
done
for f in monitoring/grafana/alerts/api/*.json; do jq -e '.uid and .data' "$f" >/dev/null; done
echo "ok dashboards and alert payloads"

echo "== generated files are up to date"
python3 monitoring/grafana/generate.py >/dev/null
git diff --quiet -- monitoring || { echo "run monitoring/grafana/generate.py and commit the result" >&2; exit 1; }
echo "All checks passed"
