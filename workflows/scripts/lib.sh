#!/usr/bin/env bash
# Shared functions for tpg workflow steps. Sourced by every step script.
# Runs in the tools image (alpine/k8s): bash, kubectl, jq, yq (v4), git, curl, helm.
# Hub operations use the pod ServiceAccount (tpg-workflow); target operations
# use the kubeconfig-<cluster> Secret through tk().
# Credentials (Broadcom registry, GitHub read/write PAT, backup storage key) come
# from Vault: Vault Agent renders them into /vault/secrets/*.json before the step
# starts (workflows/vault-agent/config-init.hcl); read them with vault_secret.

# Variables such as SYNC_FAIL_REASON and POD_WATCH_REASON are read by the step scripts.
# shellcheck disable=SC2034
set -euo pipefail
PUSHED_REVISION=""

# Retrying kubectl/helm/curl wrappers, pods_watch and the Helm release helpers
# (shared with tpg-aks-infra scripts/lib/common.sh).
# shellcheck source=workflows/scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ARGO_NS="argo"
ARGOCD_URL="${ARGOCD_URL:-https://argocd-server.argocd.svc.cluster.local}"
WORK="${TPG_WORK:-/tmp/work}"   # TPG_WORK: offline tests only
mkdir -p "$WORK"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# ----------------------------------------------------------------- settings
setting() {
  kubectl -n "$ARGO_NS" get configmap tpg-settings -o json | jq -r --arg k "$1" '.data[$k] // empty'
}

# The fleet plan (/tmp/fleet.json, /tmp/fleet-base.json) travels between steps
# as a workflow parameter, and one container argument is limited to 128 KiB.
# A backup.caBundle equal to the tpg-settings bundle (design decision D63) is
# carried as CA_PLACEHOLDER and restored where the plan becomes a file again.
CA_PLACEHOLDER='@tpg-settings:backupCaBundle@'
plan_json() {      # plan_json YAML_FILE CA_BUNDLE -> compact JSON, bundle replaced
  yq -o=json -I=0 '.' "$1" | jq -c --arg v "${2:-}" --arg p "$CA_PLACEHOLDER" '
    if $v == "" then . else
      (.clusters[]?.instances[]?.backup | objects | select(.caBundle == $v) | .caBundle) |= $p
    end'
}
plan_restore() {   # plan_restore YAML_FILE CA_BUNDLE: put the bundle back in place
  grep -qF "$CA_PLACEHOLDER" "$1" || return 0
  [[ -n "${2:-}" ]] || { log "the plan uses the tpg-settings CA bundle and backupCaBundle is empty"; return 1; }
  V="$2" P="$CA_PLACEHOLDER" yq -i \
    '(.. | select(tag == "!!map" and .caBundle == strenv(P))) |= (.caBundle = strenv(V) | .caBundle style="literal")' "$1"
}

secret_val() {
  kubectl -n "$ARGO_NS" get secret "$1" -o json | jq -r --arg k "$2" '.data[$k] // empty' | base64 -d
}

# ----------------------------------------------------------------- Vault
VAULT_SECRETS_DIR="${VAULT_SECRETS_DIR:-/vault/secrets}"

vault_secret() {
  # vault_secret NAME KEY: value from /vault/secrets/NAME.json (broadcom-registry,
  # github-push, backup-storage). Fails when Vault Agent did not render the file.
  local f="${VAULT_SECRETS_DIR}/$1.json" v
  if [[ ! -s "$f" ]]; then
    log "Vault secret $1 is not available at $f: the pod was started without Vault Agent (vault-agent-injector down, or Vault sealed or unreachable)"
    return 1
  fi
  v="$(jq -r --arg k "$2" '.[$k] // empty' "$f")"
  [[ -n "$v" ]] || { log "Vault secret $1 has no key $2 (tpg/shared/$1)"; return 1; }
  printf '%s' "$v"
}

vault_check() {
  # vault_check: 0 when Vault (tpg-settings vaultAddr) is initialized and unsealed.
  # Prints VAULT_SEALED, VAULT_NOT_INITIALIZED or VAULT_UNREACHABLE otherwise.
  local addr ca st
  addr="$(setting vaultAddr)"; addr="${addr:-https://vault.vault.svc:8200}"
  ca="$(mktemp)"
  secret_val vault-ca ca.crt > "$ca" 2>/dev/null || true
  if [[ ! -s "$ca" ]] || ! st="$(curl -sS --max-time 10 --cacert "$ca" "${addr}/v1/sys/seal-status" 2>&1)"; then
    rm -f "$ca"; printf 'VAULT_UNREACHABLE %s' "${st:-Secret argo/vault-ca missing}"; return 1
  fi
  rm -f "$ca"
  if [[ "$(jq -r '.initialized' <<<"$st" 2>/dev/null)" != "true" ]]; then printf 'VAULT_NOT_INITIALIZED %s' "$addr"; return 1; fi
  if [[ "$(jq -r '.sealed' <<<"$st")" != "false" ]]; then
    printf 'VAULT_SEALED unseal it: tpg-aks-infra scripts/run.sh ... --only vault-unseal'; return 1
  fi
  return 0
}

# ----------------------------------------------------------------- Azure Blob
blob_shared_key_auth() {
  # blob_shared_key_auth ACCOUNT KEY DATE CANONICAL_RESOURCE
  # SharedKey Authorization header value for a GET without body (Blob service,
  # x-ms-version 2021-08-06). CANONICAL_RESOURCE is the canonicalized resource
  # after /<account>, for example "/pg-backups-c1\nrestype:container" (with \n
  # escapes). python3 (in the tools image) computes the HMAC; the key is passed
  # in the environment, not as an argument.
  local sts
  sts="$(printf 'GET\n\n\n\n\n\n\n\n\n\n\n\nx-ms-date:%s\nx-ms-version:2021-08-06\n/%s%b' "$3" "$1" "$4")"
  printf 'SharedKey %s:%s' "$1" "$(STS="$sts" BLOB_KEY="$2" python3 -c '
import base64, hashlib, hmac, os
key = base64.b64decode(os.environ["BLOB_KEY"])
print(base64.b64encode(hmac.new(key, os.environ["STS"].encode(), hashlib.sha256).digest()).decode(), end="")')"
}

blob_container_status() {
  # blob_container_status ACCOUNT KEY CONTAINER -> HTTP status of Get Container Properties
  # (200: the key is valid and the container exists; 403: key rejected; 404: no container)
  local account="$1" key="$2" container="$3" date auth
  date="$(LC_ALL=C TZ=GMT date '+%a, %d %b %Y %H:%M:%S GMT')"
  auth="$(blob_shared_key_auth "$account" "$key" "$date" "/${container}\nrestype:container")"
  printf 'Authorization: %s\n' "$auth" | curl -sS -o /dev/null -w '%{http_code}' -H @- \
    -H "x-ms-date: ${date}" -H "x-ms-version: 2021-08-06" \
    "https://${account}.blob.core.windows.net/${container}?restype=container" || printf '000'
}

# ----------------------------------------------------------------- run results
# Every step records one result per target in ConfigMap tpg-run-<workflow>.
run_cm() { printf 'tpg-run-%s' "$WF"; }

record() {
  # record KEY STATUS [REASON] [DETAIL] [PREVIOUS]
  #
  # /tmp/result is written first and on its own. It is the step's Argo output
  # parameter (outputs.parameters[].valueFrom.path), and the Prometheus metric
  # and the exit-handler report read it. Writing it before the ConfigMap patch
  # means a hub API error while recording the result can no longer hide the
  # result itself: the step would otherwise exit 1 with no /tmp/result, and the
  # run would report the default UNKNOWN instead of the real status.
  local key="$1" status="$2" reason="${3:-}" detail="${4:-}" previous="${5:-}" value patch
  printf '%s' "$status" > /tmp/result
  RESULT_RECORDED=1
  value="$(jq -cn --arg s "$status" --arg r "$reason" --arg d "$detail" --arg p "$previous" \
    --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{status:$s, reason:$r, detail:$d, previous:$p, time:$t}')"
  patch="$(jq -cn --arg k "$key" --arg v "$value" '{data: {($k): $v}}')"
  if ! kubectl -n "$ARGO_NS" patch configmap "$(run_cm)" --type merge -p "$patch" >/dev/null 2>&1; then
    log "WARNING: could not write ${key} to ConfigMap $(run_cm); the step result stays ${status}"
  fi
  log "RESULT ${key} ${status} ${reason} ${detail}"
}

# result_guard KEY: install an EXIT trap that records KEY as FAILED with the
# failing line when the step script exits non-zero without having recorded a
# result. Without it such a step ends as "sub-process exited: exit status 1"
# with the output parameter falling back to its default (UNKNOWN), which says
# nothing about what went wrong.
RESULT_RECORDED=0
result_guard() {
  local key="$1"
  # shellcheck disable=SC2064  # key and the line number are captured now, on purpose
  trap "_result_guard_exit \$? \$LINENO '$key'" EXIT
}
_result_guard_exit() {
  local rc="$1" line="$2" key="$3"
  [[ "$rc" -ne 0 ]] || return 0
  [[ "$RESULT_RECORDED" -eq 0 ]] || return 0
  trap - EXIT
  record "$key" FAILED UNEXPECTED_ERROR "${BASH_SOURCE[1]##*/} exited ${rc} near line ${line}; see the step logs" || true
  exit "$rc"
}

record_entry() {
  # record_entry KEY STATUS [REASON] [DETAIL]: an entry in tpg-run-<workflow> that
  # is not the step's own result (a warning, or a cluster blocked by an earlier
  # step). Unlike record, it leaves /tmp/result and the result_guard alone.
  local value patch
  value="$(jq -cn --arg s "$2" --arg r "${3:-}" --arg d "${4:-}" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{status:$s, reason:$r, detail:$d, previous:"", time:$t}')"
  patch="$(jq -cn --arg k "$1" --arg v "$value" '{data: {($k): $v}}')"
  kubectl -n "$ARGO_NS" patch configmap "$(run_cm)" --type merge -p "$patch" >/dev/null 2>&1 \
    || log "WARNING: could not write $1 to ConfigMap $(run_cm)"
  log "${2} $1 ${3:-} ${4:-}"
}

record_status() {
  kubectl -n "$ARGO_NS" get configmap "$(run_cm)" -o json \
    | jq -r --arg k "$1" '(.data[$k] // "{}") | fromjson | .status // ""'
}

run_data() {
  kubectl -n "$ARGO_NS" get configmap "$(run_cm)" -o json | jq -r --arg k "$1" '.data[$k] // empty'
}

run_records() {
  # run_records -> every entry of the run ConfigMap as a JSON object {key: "<json>"}
  kubectl -n "$ARGO_NS" get configmap "$(run_cm)" -o json | jq -c '.data // {}'
}

# ----------------------------------------------------------------- clusters
use_cluster() {
  CLUSTER="$1"
  mkdir -p /tmp/kube
  secret_val "kubeconfig-${CLUSTER}" config > "/tmp/kube/${CLUSTER}"
  chmod 600 "/tmp/kube/${CLUSTER}"
  [[ -s "/tmp/kube/${CLUSTER}" ]] || { log "kubeconfig-${CLUSTER} not found"; return 1; }
}

tk() { kubectl --kubeconfig "/tmp/kube/${CLUSTER}" --request-timeout=60s "$@"; }

inventory_cluster() {
  # inventory_cluster NAME -> JSON object for the cluster from the run inventory
  run_data inventory | jq -c --arg c "$1" '.[] | select(.name == $c)'
}

inventory_instances() {
  run_data inventory | jq -r --arg c "$1" '.[] | select(.name == $c) | .instances[].name'
}

# ----------------------------------------------------------------- Argo CD API
argocd_token() { secret_val argocd-workflow-token token; }

acd() {
  # acd METHOD PATH [JSON_BODY]: Argo CD API call. A connection error or an HTTP
  # 502/503/504 is retried (tpg_retry); an HTTP 4xx is returned at once with the
  # body on stdout, for the caller to read .message.
  local method="$1" path="$2" body="${3:-}" token
  token="$(argocd_token)"
  local args=(-sSk --fail-with-body -X "$method" -H "Authorization: Bearer ${token}")
  if [[ -n "$body" ]]; then
    args+=(-H 'Content-Type: application/json' -d "$body")
  fi
  tpg_retry curl "${args[@]}" "${ARGOCD_URL}${path}"
}

app_list() {
  # app_list SELECTOR -> application names
  local token
  token="$(argocd_token)"
  tpg_retry curl -sSk --fail-with-body -G -H "Authorization: Bearer ${token}" \
    --data-urlencode "selector=$1" "${ARGOCD_URL}/api/v1/applications" \
    | jq -r '.items[]?.metadata.name'
}

# ----------------------------------------------------------------- Argo CD sync engine
# One sync routine for every workflow (day0, operator and Postgres upgrade,
# scale, restore adoption). It
#   1. waits for an operation that is already running on the Application
#      (another workflow, or someone in the UI) instead of failing on it,
#   2. syncs, with --revision exactly the fleet commit the workflow pushed, and
#      follows only the operation this request started (the startedAt of the
#      previous operation is remembered, so an old "Succeeded" is never read as
#      the answer),
#   3. sorts a failed operation: a permanent error (admission webhook denied,
#      invalid or immutable field, schema) fails at once with Argo CD's message;
#      a transient one (another operation running, API timeouts, a CRD the Argo
#      CD cache does not know yet, repo-server errors) is synced again with
#      backoff (SYNC_ATTEMPTS, default 4; SYNC_RETRY_DELAY 15 s, doubled: 15, 30, 60 s),
#   4. waits until the Application is Healthy, printing the pods of the given
#      namespace every 5 seconds (pods_watch) and failing fast when one cannot
#      start, and finally checks that the Application is Synced.
#      With --ready-fn the target itself is the judge: FN checks the cluster
#      directly (CRDs Established, operator Deployment available, Postgres
#      Running). Argo CD can take minutes to rediscover the API resources after
#      new CRDs appear; once FN passes, the Application is hard-refreshed and a
#      Health status that still lags after 2 minutes is reported, not failed.
# Returns 0 on success; 1 sync failed, 2 timeout, 3 a pod cannot start. Sets
# SYNC_FAIL_REASON and SYNC_FAIL_DETAIL for the step result.
: "${SYNC_ATTEMPTS:=4}"
: "${SYNC_POLL_SECONDS:=5}"     # how often the engine reads the Application
: "${SYNC_RETRY_DELAY:=15}"     # first wait before syncing again (doubled each time)
SYNC_FAIL_REASON=""
SYNC_FAIL_DETAIL=""
SYNC_PERMANENT_PATTERN='admission webhook .*denied|denied the request|is invalid|Invalid value|is forbidden|Forbidden:|field is immutable|cannot be changed|Required value|Unsupported value|unknown field|error validating data|strict decoding error|failed to create typed patch object|admission webhook .* rejected'
SYNC_TRANSIENT_PATTERN="another operation is already in progress|${TPG_RETRY_PATTERN}|context deadline exceeded|could not find the requested resource|no matches for kind|ensure CRDs are installed first|ComparisonError|failed to load live state|rpc error: code = (Unavailable|DeadlineExceeded)|cluster cache"

app_get() {
  local o
  if o="$(acd GET "/api/v1/applications/$1" 2>/dev/null)" && [[ -n "$o" ]]; then printf '%s' "$o"; else echo '{}'; fi
}

app_exists() { acd GET "/api/v1/applications/$1" >/dev/null 2>&1; }

app_refresh() { acd GET "/api/v1/applications/$1?refresh=hard" >/dev/null 2>&1 || true; }

app_resources() {
  # app_resources APP -> the objects Argo CD manages for the Application
  # (status.resources), one "group/kind/namespace/name" per line; empty when the
  # Application does not exist or the API cannot be reached
  app_get "$1" | jq -r '.status.resources[]? | "\(.group // "")/\(.kind)/\(.namespace // "")/\(.name)"'
}

obj_key() {
  # obj_key OBJECT_JSON -> "group/kind/namespace/name", the app_resources format
  jq -r '(.apiVersion | if test("/") then split("/")[0] else "" end) + "/" + .kind + "/"
    + (.metadata.namespace // "") + "/" + .metadata.name' <<<"$1"
}

owned_by_app() {
  # owned_by_app OBJECT_JSON APP APP_RESOURCES -> 0 when Argo CD manages the object
  # for APP (design decision D62):
  #   CustomResourceDefinition  the Application lists it in status.resources
  #                             (APP_RESOURCES, from app_resources), or its
  #                             tracking annotation names APP. The Tanzu Postgres
  #                             CRDs (the chart's crds/ directory) do not keep
  #                             the annotation.
  #   any other kind            the tracking annotation names APP. The list is
  #                             not proof here: status.resources also names an
  #                             object that someone else created under the same
  #                             name, which Argo CD shows as OutOfSync.
  local key
  key="$(obj_key "$1")"
  if [[ "$key" == apiextensions.k8s.io/CustomResourceDefinition/* && -n "$3" ]]; then
    grep -qxF "$key" <<<"$3" && return 0
  fi
  jq -e --arg a "$2:" '(.metadata.annotations["argocd.argoproj.io/tracking-id"] // "") | startswith($a)' <<<"$1" >/dev/null
}

operator_deployments() {
  # operator_deployments -> the Tanzu Postgres operator Deployments of the current
  # cluster, one compact JSON object per line: label app=postgres-operator, or a
  # container image named postgres-operator (an install with other labels)
  tk get deploy -A -o json | jq -c '.items[]
    | select(.metadata.labels.app == "postgres-operator"
        or any(.spec.template.spec.containers[]?; .image | test("(^|/)postgres-operator[:@]")))'
}

exposure_warning_rendered() {
  # exposure_warning_rendered CLUSTER INSTANCE RENDERED_MANIFESTS: warning
  # EXPOSURE_UNRESTRICTED for a public load balancer Service (LoadBalancer
  # without the internal annotation) that has no azure-allowed-ip-ranges
  local kind
  for kind in serviceType readOnlyServiceType; do
    local ann="serviceAnnotations"; [[ "$kind" == "serviceType" ]] || ann="readOnlyServiceAnnotations"
    if K="$kind" A="$ann" yq -e 'select(.kind == "Postgres") | .spec[strenv(K)] == "LoadBalancer"
         and (.spec[strenv(A)]["service.beta.kubernetes.io/azure-load-balancer-internal"] // "") != "true"
         and (.spec[strenv(A)]["service.beta.kubernetes.io/azure-allowed-ip-ranges"] // "") == ""' <<<"$3" >/dev/null 2>&1; then
      record_entry "warning.$1.$2.${kind}" WARNING EXPOSURE_UNRESTRICTED \
        "${2}: ${kind}=LoadBalancer on a public IP without allowedSourceRanges; anyone on the internet can try to connect on 5432"
    fi
  done
}

exposure_follow() {
  # exposure_follow INSTANCE TIMEOUT_SECONDS: after a sync, wait until the
  # Services of pg-<instance> match the exposure of the live Postgres spec
  # (design decision D64): as many LoadBalancer Services with an address as the
  # spec asks for (serviceType, and readOnlyServiceType when high availability
  # is on, plus the FerretDB Services of a PostgresFerretDocumentDB), and none
  # when all are ClusterIP. Sets EXPOSURE_DETAIL; returns 1
  # on timeout. (use_cluster first)
  local i="$1" timeout="$2" start want have spec fspec
  spec="$(tk -n "pg-$i" get postgres "$i" -o json 2>/dev/null || echo '{}')"
  want="$(jq '[(.spec.serviceType == "LoadBalancer"),
                ((.spec.readOnlyServiceType == "LoadBalancer") and (.spec.highAvailability.enabled == true))]
              | map(select(.)) | length' <<<"$spec")"
  # FerretDB Services (D71): ferretdb-rw-<instance>, and ferretdb-ro-<instance> with read-only proxies
  fspec="$(tk -n "pg-$i" get postgresferretdocumentdb "$i" -o json 2>/dev/null || echo '{}')"
  want=$(( want + $(jq '[(.spec.service.serviceType == "LoadBalancer"),
                ((.spec.service.readOnlyServiceType == "LoadBalancer") and ((.spec.readOnly.replicas // 0) > 0))]
              | map(select(.)) | length' <<<"$fspec") ))
  start="$(date +%s)"
  while true; do
    have="$(tk -n "pg-$i" get svc -o json 2>/dev/null | jq -r '[.items[] | select(.spec.type == "LoadBalancer")
      | {n: .metadata.name, a: ((.status.loadBalancer.ingress // [])[0] | (.ip // .hostname // ""))}]')"
    if [[ "$(jq 'length' <<<"$have")" -eq "$want" ]] && jq -e 'all(.[]; .a != "")' <<<"$have" >/dev/null; then
      if [[ "$want" -eq 0 ]]; then EXPOSURE_DETAIL="ClusterIP only"
      else EXPOSURE_DETAIL="$(jq -r 'map(.n + " " + .a) | join(", ")' <<<"$have")"; fi
      return 0
    fi
    if (( $(date +%s) - start >= timeout )); then
      EXPOSURE_DETAIL="expected ${want} LoadBalancer Service(s) with an address in pg-${i}, found: $(jq -c '.' <<<"$have")"
      return 1
    fi
    log "${i}: waiting for the Services to follow the exposure (${want} load balancer(s) expected)"
    sleep 10
  done
}

ferret_follow() {
  # ferret_follow INSTANCE TIMEOUT_SECONDS: after a sync, when pg-<instance> has a
  # PostgresFerretDocumentDB (D71): the connection Secrets it names exist (the
  # operator creates them with the instance), then its Deployments
  # (app=ferretdb-rw-<instance>, and ferretdb-ro-<instance> with read-only
  # proxies) are available. Sets FERRET_REASON and FERRET_DETAIL ("" without
  # FerretDB); returns 1 on failure. (use_cluster first)
  local i="$1" timeout="$2" f sec missing found start want ready sel
  FERRET_REASON=""; FERRET_DETAIL=""
  f="$(tk -n "pg-$i" get postgresferretdocumentdb "$i" -o json 2>/dev/null)" || return 0
  start="$(date +%s)"
  while true; do
    missing=""
    for sec in $(jq -r '.spec.postgres.connectionDetails | .readWrite.secretName, (.readOnly.secretName // empty)' <<<"$f"); do
      tk -n "pg-$i" get secret "$sec" >/dev/null 2>&1 || missing="${missing:+${missing},}${sec}"
    done
    [[ -n "$missing" ]] || break
    if (( $(date +%s) - start >= 120 )); then
      found="$(tk -n "pg-$i" get secret -o name 2>/dev/null | sed 's#^secret/##' | grep -- '-db-secret$' | paste -sd, -)"
      FERRET_REASON=FERRET_SECRET_MISSING
      FERRET_DETAIL="${i}: connection Secret(s) ${missing} not found in pg-${i}; the db Secrets there: ${found:-none} (set ferretSecretName / ferretReadOnlySecretName)"
      return 1
    fi
    sleep 10
  done
  want=1; [[ "$(jq -r '.spec.readOnly.replicas // 0' <<<"$f")" -gt 0 ]] && want=2
  sel="app in (ferretdb-rw-${i},ferretdb-ro-${i})"
  while true; do
    ready="$(tk -n "pg-$i" get deployment -l "$sel" -o json 2>/dev/null \
      | jq '[.items[] | select((.status.availableReplicas // 0) >= (if .spec.replicas == null then 1 else .spec.replicas end))] | length')"
    if [[ "${ready:-0}" -ge "$want" ]]; then
      FERRET_DETAIL="FerretDB ready (${want} Deployment(s))"
      return 0
    fi
    if (( $(date +%s) - start >= timeout )); then
      FERRET_REASON=FERRET_NOT_READY
      FERRET_DETAIL="${i}: ${ready:-0} of ${want} FerretDB Deployment(s) available; pods: $(tk -n "pg-$i" get pods -l "$sel" --no-headers 2>/dev/null \
        | awk '{printf "%s%s=%s", (n++ ? ", " : ""), $1, $3}'); is the documentdb extension prepared (FERRET_EXTENSION_REQUIRED)?"
      return 1
    fi
    log "${i}: waiting for the FerretDB Deployments (${ready:-0}/${want} available)"
    sleep 10
  done
}
pgdata_pool_shape() {
  # pgdata_pool_shape -> "<ready nodes> <zones>" of the Postgres data pool of the
  # current cluster: nodes labelled tpg.fleet/pool=postgres, else agentpool=pgdata,
  # else every node without the CriticalAddonsOnly taint (a pre-created cluster)
  local nodes ready zones
  nodes="$(tk get nodes -l tpg.fleet/pool=postgres -o json 2>/dev/null | jq -c '.items')"
  [[ "$(jq 'length' <<<"${nodes:-[]}")" -gt 0 ]] \
    || nodes="$(tk get nodes -l agentpool=pgdata -o json 2>/dev/null | jq -c '.items')"
  if [[ "$(jq 'length' <<<"${nodes:-[]}")" -eq 0 ]]; then
    nodes="$(tk get nodes -o json 2>/dev/null | jq -c '[.items[]
      | select(any(.spec.taints[]? ; .key == "CriticalAddonsOnly") | not)]')"
  fi
  ready="$(jq '[.[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' <<<"${nodes:-[]}")"
  zones="$(jq -r '[.[] | .metadata.labels["topology.kubernetes.io/zone"] // empty] | unique | length' <<<"${nodes:-[]}")"
  printf '%s %s' "${ready:-0}" "${zones:-0}"
}

azure_backup_supported() {
  # azure_backup_supported [with-ca] -> 0 when the PostgresBackupLocation CRD of
  # the current cluster has spec.storage.azure (and caBundle with "with-ca").
  # The 4.5 documentation lists only S3 and GCS; the fleet relies on the live
  # CRD (design decision D63). Sets AZURE_BACKUP_DETAIL.
  local props
  props="$(tk get crd postgresbackuplocations.sql.tanzu.vmware.com -o json 2>/dev/null \
    | jq -c '[.spec.versions[] | select(.storage)][0].schema.openAPIV3Schema.properties.spec.properties.storage.properties.azure.properties // null')"
  if [[ -z "$props" || "$props" == "null" ]]; then
    AZURE_BACKUP_DETAIL="the PostgresBackupLocation CRD has no spec.storage.azure (Azure Blob backups are not available with this operator version)"
    return 1
  fi
  if [[ "${1:-}" == "with-ca" ]] && ! jq -e 'has("caBundle")' <<<"$props" >/dev/null; then
    AZURE_BACKUP_DETAIL="the PostgresBackupLocation CRD has no spec.storage.azure.caBundle"
    return 1
  fi
  AZURE_BACKUP_DETAIL="spec.storage.azure: $(jq -r 'keys | join(",")' <<<"$props")"
}

appset_refresh() {
  # Ask the ApplicationSet controller to re-read Git now instead of waiting for the poll.
  kubectl -n argocd annotate applicationset "$1" \
    argocd.argoproj.io/application-set-refresh=true --overwrite >/dev/null
}

_app_line() {
  # _app_line APP_JSON -> "sync=S health=H operation=P (message)"
  jq -r '"sync=\(.status.sync.status // "?") health=\(.status.health.status // "?")"
    + (if .status.operationState then " operation=\(.status.operationState.phase)" else "" end)
    + (if (.status.health.message // "") != "" then " (\(.status.health.message | .[0:120]))" else "" end)' <<<"$1"
}

_app_busy() {
  # _app_busy APP_JSON -> 0 when an operation is requested or running
  jq -e '(.operation != null) or ((.status.operationState.phase // "") | test("^(Running|Terminating)$"))' <<<"$1" >/dev/null
}

_app_wait_idle() {
  # _app_wait_idle APP MAX_SECONDS -> 0 when no operation is running
  local app="$1" max="$2" start j
  start="$(date +%s)"
  while true; do
    j="$(app_get "$app")"
    _app_busy "$j" || return 0
    if (( $(date +%s) - start >= max )); then return 1; fi
    log "${app}: another operation is running ($(jq -r '.status.operationState.operation.initiatedBy.username // .status.operationState.operation.initiatedBy.automated // "unknown"' <<<"$j")); waiting: $(_app_line "$j")"
    sleep "$SYNC_POLL_SECONDS"
  done
}

_app_op_wait() {
  # _app_op_wait APP PREVIOUS_STARTED_AT DEADLINE -> 0 Succeeded, 1 Failed/Error
  # (message in SYNC_OP_MESSAGE), 2 timeout. Only an operation whose startedAt
  # differs from PREVIOUS_STARTED_AT is ours.
  local app="$1" prev="$2" deadline="$3" j started phase
  SYNC_OP_MESSAGE=""
  while true; do
    j="$(app_get "$app")"
    started="$(jq -r '.status.operationState.startedAt // ""' <<<"$j")"
    phase="$(jq -r '.status.operationState.phase // ""' <<<"$j")"
    if [[ -n "$started" && "$started" != "$prev" ]]; then
      case "$phase" in
        Succeeded) log "${app}: sync operation Succeeded at $(jq -r '.status.operationState.syncResult.revision // "" | .[0:12]' <<<"$j")"; return 0 ;;
        Failed|Error)
          SYNC_OP_MESSAGE="$(jq -r '.status.operationState.message // ""' <<<"$j")"
          log "${app}: sync operation ${phase}: ${SYNC_OP_MESSAGE}"
          return 1 ;;
      esac
      log "${app}: sync operation ${phase:-Running}: $(jq -r '.status.operationState.message // "" | .[0:160]' <<<"$j")"
    else
      log "${app}: sync requested, waiting for the operation to start: $(_app_line "$j")"
    fi
    if (( $(date +%s) >= deadline )); then return 2; fi
    sleep "$SYNC_POLL_SECONDS"
  done
}

_APP_WATCHED=""
_app_healthy() {
  # done-fn for pods_watch: 0 when the watched Application is Healthy; prints its state
  local j
  j="$(app_get "$_APP_WATCHED")"
  printf '%s: %s' "$_APP_WATCHED" "$(_app_line "$j")"
  [[ "$(jq -r '.status.health.status // ""' <<<"$j")" == "Healthy" ]]
}

app_sync_wait() {
  # app_sync_wait APP TIMEOUT_SECONDS [--revision SHA] [--revisions POSITION SHA]
  #               [--pods NAMESPACE SELECTOR] [--ready-fn FN] [--sync-options OPT,OPT]
  #               [--prune] [--off-branch]
  # --revisions syncs one source of a multi-source Application at SHA (POSITION
  # counts from 1; the operator Applications read the fleet repository as source 2).
  # --off-branch: SHA is not on the fleet branch (a tpg-patch pull request branch,
  # Round 14), so the Application compares Git on the fleet branch with objects
  # synced from another commit and shows OutOfSync until the merge; the end check
  # is then that the operation synced SHA, not that the Application is Synced.
  # --prune deletes the resources Git no longer renders (tpg-network-policy
  # mode=remove); objects annotated Prune=false (Postgres, backup location) stay.
  # --sync-options replaces the Application's sync options for this one operation
  # (Argo CD takes the options of the sync request instead of spec.syncPolicy).
  local app="$1" timeout="$2" rev="" pns="" psel="" ready_fn="" sopts="" prune=false start deadline body out msg prev j rc
  local attempt=1 delay="$SYNC_RETRY_DELAY" remaining oos spos="" off=false
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --revision) rev="$2"; shift 2 ;;
      --revisions) spos="$2"; rev="$3"; shift 3 ;;
      --pods) pns="$2"; psel="$3"; shift 3 ;;
      --ready-fn) ready_fn="$2"; shift 2 ;;
      --sync-options) sopts="$2"; shift 2 ;;
      --prune) prune=true; shift ;;
      --off-branch) off=true; shift ;;
      *) log "app_sync_wait: unknown option $1"; return 1 ;;
    esac
  done
  SYNC_FAIL_REASON=""; SYNC_FAIL_DETAIL=""
  start="$(date +%s)"; deadline=$((start + timeout))
  app_refresh "$app"
  body="$(jq -cn --arg r "$rev" --arg sp "$spos" --arg o "$sopts" --argjson p "$prune" '{prune: $p,
      retryStrategy: {limit: 2, backoff: {duration: "5s", factor: 2, maxDuration: "30s"}}}
    | if $r != "" and $sp != "" then .revisions = [$r] | .sourcePositions = [($sp | tonumber)]
      elif $r != "" then .revision = $r else . end
    | if $o != "" then .syncOptions = {items: ($o | split(","))} else . end')"
  while true; do
    if ! _app_wait_idle "$app" 300; then
      SYNC_FAIL_REASON=SYNC_BUSY
      SYNC_FAIL_DETAIL="${app}: an operation started by someone else is still running after 300s"
      return 1
    fi
    j="$(app_get "$app")"
    prev="$(jq -r '.status.operationState.startedAt // ""' <<<"$j")"
    [[ "$attempt" -gt 1 ]] || manual_sync_check "$app" "$j" || true
    msg=""
    if out="$(acd POST "/api/v1/applications/${app}/sync" "$body" 2>&1)"; then
      log "sync requested for ${app}${rev:+ at revision ${rev:0:12}} (attempt ${attempt}/${SYNC_ATTEMPTS})"
      rc=0; _app_op_wait "$app" "$prev" "$deadline" || rc=$?
      case "$rc" in
        0) break ;;
        2) SYNC_FAIL_REASON=SYNC_TIMEOUT
           SYNC_FAIL_DETAIL="${app}: the sync operation did not finish in ${timeout}s ($(_app_line "$(app_get "$app")"))"
           return 2 ;;
      esac
      msg="$SYNC_OP_MESSAGE"
    else
      msg="$(grep -m1 '^{' <<<"$out" | jq -r '.message // empty' 2>/dev/null || true)"
      [[ -n "$msg" ]] || msg="$(tr '\n' ' ' <<<"$out")"
      log "sync request for ${app} rejected: ${msg}"
    fi
    if grep -Eqi -- "$SYNC_PERMANENT_PATTERN" <<<"$msg" && ! grep -Eqi 'another operation is already in progress' <<<"$msg"; then
      SYNC_FAIL_REASON=SYNC_REJECTED
      SYNC_FAIL_DETAIL="${app}: ${msg}"
      log "${app}: permanent sync error, not retried: ${msg}"
      return 1
    fi
    if [[ "$attempt" -ge "$SYNC_ATTEMPTS" ]] || (( $(date +%s) + delay >= deadline )) \
       || ! grep -Eqi -- "$SYNC_TRANSIENT_PATTERN" <<<"$msg"; then
      SYNC_FAIL_REASON=SYNC_FAILED
      SYNC_FAIL_DETAIL="${app}: ${msg} (after ${attempt} attempt(s))"
      return 1
    fi
    log "${app}: transient sync error (attempt ${attempt}/${SYNC_ATTEMPTS}), syncing again in ${delay}s"
    sleep "$delay"
    attempt=$((attempt + 1)); delay=$((delay * 2))
    app_refresh "$app"
  done

  # Health: the pods of the Application every 5 seconds, or its health status
  remaining=$((deadline - $(date +%s))); [[ "$remaining" -ge 60 ]] || remaining=60
  if [[ -n "$pns" ]]; then
    _APP_WATCHED="$app"
    rc=0; pods_watch "$pns" "$remaining" --selector "$psel" --kubectl tk --label "$app" --done-fn "${ready_fn:-_app_healthy}" || rc=$?
    case "$rc" in
      0) ;;
      1) SYNC_FAIL_REASON="$POD_WATCH_REASON"; SYNC_FAIL_DETAIL="$POD_WATCH_DETAIL"; return 3 ;;
      *) SYNC_FAIL_REASON=HEALTH_TIMEOUT
         SYNC_FAIL_DETAIL="${app} not Healthy after ${timeout}s: $(_app_line "$(app_get "$app")")"
         return 2 ;;
    esac
  else
    while true; do
      j="$(app_get "$app")"
      [[ "$(jq -r '.status.health.status // ""' <<<"$j")" == "Healthy" ]] && break
      if (( $(date +%s) >= deadline )); then
        SYNC_FAIL_REASON=HEALTH_TIMEOUT; SYNC_FAIL_DETAIL="${app} not Healthy after ${timeout}s: $(_app_line "$j")"
        return 2
      fi
      log "${app}: $(_app_line "$j")"
      sleep "$SYNC_POLL_SECONDS"
    done
  fi
  if [[ -n "$ready_fn" ]]; then
    # The target is verified; let Argo CD catch up instead of waiting for its
    # reconciliation loop (timeout.reconciliation) to notice the new resources.
    app_refresh "$app"
    for _ in $(seq 1 24); do
      j="$(app_get "$app")"
      [[ "$(jq -r '.status.health.status // ""' <<<"$j")" == "Healthy" ]] && break
      sleep "$SYNC_POLL_SECONDS"
    done
    [[ "$(jq -r '.status.health.status // ""' <<<"$j")" == "Healthy" ]] \
      || log "WARNING: ${app}: the target is ready (checked directly) but Argo CD still reports $(_app_line "$j")"
  fi
  if [[ "$off" == "true" ]]; then
    # synced from a commit off the fleet branch: OutOfSync is expected until the merge
    j="$(app_get "$app")"
    if jq -e --arg r "$rev" '.status.operationState.syncResult | ((.revision // "") == $r) or ((.revisions // []) | index($r) != null)' <<<"$j" >/dev/null; then
      log "${app}: Healthy, synced at ${rev:0:12} (off the fleet branch: OutOfSync against it until the merge)"
      return 0
    fi
    SYNC_FAIL_REASON=SYNC_FAILED
    SYNC_FAIL_DETAIL="${app}: the last sync did not use ${rev:0:12} ($(jq -r '.status.operationState.syncResult | (.revision // (.revisions // [] | join(",")))' <<<"$j"))"
    return 1
  fi
  # Synced at the end (a diff that no sync can settle shows up here)
  for _ in $(seq 1 12); do
    j="$(app_get "$app")"
    if [[ "$(jq -r '.status.sync.status // ""' <<<"$j")" == "Synced" ]]; then
      log "${app}: Synced/Healthy$( [[ -n "$rev" ]] && printf ' at %s' "$(jq -r '.status.sync.revision // "" | .[0:12]' <<<"$j")")"
      return 0
    fi
    sleep "$SYNC_POLL_SECONDS"
    app_refresh "$app"
  done
  oos="$(jq -r '[.status.resources[]? | select(.status == "OutOfSync") | .kind + "/" + .name] | join(", ")' <<<"$j")"
  SYNC_FAIL_REASON=SYNC_DRIFT
  SYNC_FAIL_DETAIL="${app} is Healthy but stays OutOfSync after the sync: ${oos:-no resource listed}"
  return 1
}

app_deployed_revision() {
  # app_deployed_revision APP [POSITION] -> the Git commit the Application was last
  # synced at (its newest history entry; POSITION picks a source of a multi-source
  # Application), empty when it was never synced
  app_get "$1" | jq -r --argjson p "${2:-0}" '(.status.history // []) | last // {}
    | if $p > 0 then ((.revisions // [])[$p - 1] // "") else (.revision // "") end'
}

app_sync_status() {  # app_sync_status APP -> Synced, OutOfSync, Unknown or empty
  app_get "$1" | jq -r '.status.sync.status // ""'
}

app_expect_synced() {
  # app_expect_synced APP TIMEOUT_SECONDS: after a tpg-patch pull request is merged,
  # the Application compares the new fleet branch head with the objects synced from
  # the branch: the same objects, so it turns Synced without another sync (Round
  # 14). Refreshes and waits; 1 with SYNC_FAIL_DETAIL listing what stays OutOfSync.
  local app="$1" deadline j oos
  deadline=$(( $(date +%s) + $2 ))
  SYNC_FAIL_REASON=""; SYNC_FAIL_DETAIL=""
  while true; do
    app_refresh "$app"
    j="$(app_get "$app")"
    if [[ "$(jq -r '.status.sync.status // ""' <<<"$j")" == "Synced" ]]; then
      log "${app}: Synced at $(jq -r '.status.sync.revision // (.status.sync.revisions // [] | join(",")) | .[0:40]' <<<"$j") (no second sync)"
      return 0
    fi
    (( $(date +%s) < deadline )) || break
    sleep "$SYNC_POLL_SECONDS"
  done
  oos="$(jq -r '[.status.resources[]? | select(.status == "OutOfSync") | .kind + "/" + .name] | join(", ")' <<<"$j")"
  SYNC_FAIL_REASON=MERGED_CONTENT_DIFFERS
  SYNC_FAIL_DETAIL="${app} stays OutOfSync after the merge (${oos:-no resource listed}): the merged fleet branch renders other objects than the ones synced from the pull request"
  return 1
}

app_target_revision() {
  # the chart version of an Application: spec.source, or the first of spec.sources
  # (the operator Applications are multi-source: the OCI chart and the fleet repository)
  acd GET "/api/v1/applications/$1" | jq -r '(.spec.source // .spec.sources[0] // {}).targetRevision // ""'
}

MANUAL_SYNC_NOTE=""
manual_sync_check() {
  # manual_sync_check APP [APP_JSON]: warn when the last operation on a tpg target Application
  # was not started by the workflows (workflow-bot) - someone synced it from the UI
  # or CLI, which Argo CD RBAC and the admission policy tpg-application-sync
  # refuse. Records warning.<app> = WARNING MANUAL_SYNC_DETECTED and returns 1;
  # the caller carries on (the workflow re-syncs the Application itself).
  local j="${2:-}" who auto at
  MANUAL_SYNC_NOTE=""
  [[ -n "$j" ]] || j="$(app_get "$1")"
  who="$(jq -r '.status.operationState.operation.initiatedBy.username // ""' <<<"$j")"
  auto="$(jq -r '.status.operationState.operation.initiatedBy.automated // false' <<<"$j")"
  at="$(jq -r '.status.operationState.startedAt // ""' <<<"$j")"
  [[ -n "$at" ]] || return 0
  if [[ "$auto" == "true" || -z "$who" || "$who" == "workflow-bot" || "$who" == workflow-bot:* ]]; then
    [[ "$auto" != "true" ]] || MANUAL_SYNC_NOTE="$1 was last synced automatically at ${at} (automated sync is not allowed on tpg target Applications)"
    [[ "$auto" == "true" ]] || return 0
  else
    MANUAL_SYNC_NOTE="$1 was last synced by ${who} at ${at}, not by the tpg workflows"
  fi
  log "WARNING MANUAL_SYNC_DETECTED: ${MANUAL_SYNC_NOTE}"
  record_entry "warning.$1" WARNING MANUAL_SYNC_DETECTED "$MANUAL_SYNC_NOTE"
  return 1
}

# ----------------------------------------------------------------- Git
git_clone() {
  local dest="$1" url rev user token auth
  url="$(setting fleetRepoURL)"
  rev="$(setting fleetRevision)"
  user="$(vault_secret github-push username)"
  token="$(vault_secret github-push token)"
  auth="$(printf '%s:%s' "$user" "$token" | base64 | tr -d '\n')"
  rm -rf "$dest"
  git -c credential.helper= -c "http.extraHeader=Authorization: Basic ${auth}" \
    clone --quiet --depth 50 --branch "$rev" "$url" "$dest"
  git -C "$dest" config http.extraHeader "Authorization: Basic ${auth}"
  git -C "$dest" config credential.helper ""
  git -C "$dest" config user.name "tpg-workflow"
  git -C "$dest" config user.email "tpg-workflow@users.noreply.github.com"
}

git_commit_push() {
  # git_commit_push REPO_DIR MESSAGE FILE... -> 0 when published or nothing to commit
  # Sets PUSHED_REVISION to the commit that carries the change (the merge result
  # in pull request mode), empty when there was nothing to commit.
  # PUSH_MODE=direct (default): push to the fleet revision, rebasing on conflicts.
  # PUSH_MODE=pr: push a branch, open a GitHub pull request and wait until it is
  # merged (PR_TIMEOUT_SECONDS, default 3600); a closed pull request fails.
  local dir="$1" msg="$2" rev i
  shift 2
  rev="$(setting fleetRevision)"
  if [[ "${FLEET_CLONE:-}" == "$dir" && -d "$WORK/fleet" ]]; then
    fleet_flush "$dir"
  fi
  # clusters/fleet.yaml is committed in block YAML, whatever wrote it (Round 13 addendum)
  for i in "$@"; do
    [[ "$i" == "$FLEET_REL" && -f "$dir/$i" ]] && fleet_yaml_style "$dir/$i"
  done
  git -C "$dir" add -- "$@"
  PUSHED_REVISION=""
  if git -C "$dir" diff --cached --quiet; then
    log "no Git change needed"
    return 0
  fi
  if [[ "${PUSH_MODE:-direct}" == "pr" ]]; then
    git_publish_pr "$dir" "$msg" "$rev"
    return
  fi
  git -C "$dir" commit --quiet -m "$msg"
  git_push_head "$dir"
}

git_push_head() {
  # git_push_head REPO_DIR: push the checked-out commits to the fleet revision,
  # rebasing when the push is rejected (5 attempts); sets PUSHED_REVISION
  local dir="$1" rev i
  rev="$(setting fleetRevision)"
  for i in 1 2 3 4 5; do
    if git -C "$dir" push --quiet origin "HEAD:${rev}"; then
      PUSHED_REVISION="$(git -C "$dir" rev-parse HEAD)"
      log "pushed: $(git -C "$dir" log -1 --format=%s) (${PUSHED_REVISION:0:12})"
      return 0
    fi
    log "push rejected (attempt ${i}), rebasing"
    git -C "$dir" pull --quiet --rebase origin "$rev"
  done
  return 1
}

github_repo() {
  # owner/repo from the fleet repository URL (https://github.com/<owner>/<repo>.git)
  setting fleetRepoURL | sed -E 's#^https?://[^/]+/##; s#\.git$##; s#/$##'
}

github_api() {
  # github_api METHOD PATH [JSON_BODY]
  local base token args
  base="$(setting githubApiUrl)"; base="${base:-https://api.github.com}"
  token="$(vault_secret github-push token)"
  args=(-sS --fail-with-body -X "$1" -H "Authorization: Bearer ${token}"
        -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
  [[ -z "${3:-}" ]] || args+=(-H 'Content-Type: application/json' -d "$3")
  curl "${args[@]}" "${base}$2"
}

fleet_head() {
  # fleet_head -> commit SHA at the head of the fleet branch (git ls-remote), empty on error
  local url rev user token auth
  url="$(setting fleetRepoURL)"; rev="$(setting fleetRevision)"
  user="$(vault_secret github-push username 2>/dev/null)" || return 0
  token="$(vault_secret github-push token 2>/dev/null)" || return 0
  auth="$(printf '%s:%s' "$user" "$token" | base64 | tr -d '\n')"
  git -c credential.helper= -c "http.extraHeader=Authorization: Basic ${auth}" \
    ls-remote "$url" "refs/heads/${rev}" 2>/dev/null | awk 'NR == 1 {print $1}'
}

pr_open() {
  # pr_open REPO_DIR MESSAGE BASE_REVISION BRANCH BODY: commit the staged changes on
  # BRANCH, push it and open a pull request into BASE_REVISION. Sets PR_NUMBER,
  # PR_URL, PR_BRANCH and PR_SHA (the commit on the branch); writes /tmp/pull-request.
  local dir="$1" msg="$2" rev="$3" pr
  PR_BRANCH="$4"; PR_NUMBER=""; PR_URL=""; PR_SHA=""
  git -C "$dir" checkout --quiet -b "$PR_BRANCH"
  git -C "$dir" commit --quiet -m "$msg"
  git -C "$dir" push --quiet origin "HEAD:refs/heads/${PR_BRANCH}" || { log "push of branch ${PR_BRANCH} failed"; return 1; }
  PR_SHA="$(git -C "$dir" rev-parse HEAD)"
  pr="$(github_api POST "/repos/$(github_repo)/pulls" "$(jq -cn --arg t "$msg" --arg h "$PR_BRANCH" --arg b "$rev" \
    --arg body "$5" '{title:$t, head:$h, base:$b, body:$body}')")" || { log "could not open a pull request: ${pr:-}"; return 1; }
  PR_NUMBER="$(jq -r '.number' <<<"$pr")"; PR_URL="$(jq -r '.html_url' <<<"$pr")"
  printf '%s' "$PR_URL" > /tmp/pull-request
  log "pull request #${PR_NUMBER} opened: ${PR_URL} (branch ${PR_BRANCH}, ${PR_SHA:0:12})"
}

pr_wait() {
  # pr_wait NUMBER TIMEOUT_SECONDS -> 0 merged (PR_MERGE_SHA), 1 closed without
  # merging, 2 not merged in time
  local number="$1" timeout="$2" start pr state merged
  PR_MERGE_SHA=""
  start="$(date +%s)"
  log "waiting up to ${timeout}s for pull request #${number} to be merged"
  while true; do
    pr="$(github_api GET "/repos/$(github_repo)/pulls/${number}" 2>/dev/null || echo '{}')"
    state="$(jq -r '.state // ""' <<<"$pr")"; merged="$(jq -r '.merged // false' <<<"$pr")"
    if [[ "$merged" == "true" ]]; then
      PR_MERGE_SHA="$(jq -r '.merge_commit_sha // ""' <<<"$pr")"
      log "pull request #${number} merged (${PR_MERGE_SHA:0:12})"
      return 0
    fi
    if [[ "$state" == "closed" ]]; then log "pull request #${number} was closed without merging"; return 1; fi
    if (( $(date +%s) - start > timeout )); then log "pull request #${number} not merged after ${timeout}s"; return 2; fi
    sleep "${PR_POLL_SECONDS:-30}"
  done
}

pr_merged() {
  # pr_merged NUMBER -> 0 when the pull request is merged (sets PR_MERGE_SHA), else 1
  local pr
  pr="$(github_api GET "/repos/$(github_repo)/pulls/$1" 2>/dev/null || echo '{}')"
  [[ "$(jq -r '.merged // false' <<<"$pr")" == "true" ]] || return 1
  PR_MERGE_SHA="$(jq -r '.merge_commit_sha // ""' <<<"$pr")"
}

pr_close() {  # pr_close NUMBER COMMENT: comment on the pull request and close it
  github_api POST "/repos/$(github_repo)/issues/$1/comments" "$(jq -cn --arg b "$2" '{body:$b}')" >/dev/null 2>&1 || true
  github_api PATCH "/repos/$(github_repo)/pulls/$1" '{"state":"closed"}' >/dev/null 2>&1 \
    || log "WARNING: could not close pull request #$1"
}

branch_delete() {  # branch_delete REPO_DIR BRANCH: delete the branch on the remote (its commit goes with it)
  git -C "$1" push --quiet origin --delete "$2" 2>/dev/null || log "WARNING: could not delete branch $2"
}

git_publish_pr() {
  # git_publish_pr REPO_DIR MESSAGE BASE_REVISION: commit staged changes to a branch,
  # open a pull request and wait for it to be merged, then fast-forward the clone.
  local dir="$1" msg="$2" rev="$3" rc
  pr_open "$dir" "$msg" "$rev" "tpg/${WF:-manual}-$(date -u +%Y%m%d%H%M%S)-${RANDOM}" \
    "Opened by Argo Workflow ${WF:-manual}. The workflow continues when this pull request is merged." || return 1
  rc=0; pr_wait "$PR_NUMBER" "${PR_TIMEOUT_SECONDS:-3600}" || rc=$?
  [[ "$rc" -eq 0 ]] || return 1
  git -C "$dir" fetch --quiet origin "$rev"
  git -C "$dir" checkout --quiet -B "$rev" "origin/${rev}"
  PUSHED_REVISION="$(git -C "$dir" rev-parse HEAD)"
  if [[ "${FLEET_CLONE:-}" == "$dir" && -d "$WORK/fleet" ]]; then
    fleet_materialize "$dir"
  fi
}

# ----------------------------------------------------------------- fleet (clusters/fleet.yaml)
# clusters/_template/cluster.yaml   cluster defaults
# clusters/_template/instance.yaml  instance defaults
# clusters/fleet.yaml               clusters.<cluster>.{operator,cluster,backup,instances.<instance>}
FLEET_REL="clusters/fleet.yaml"
TEMPLATE_CLUSTER_REL="clusters/_template/cluster.yaml"
TEMPLATE_INSTANCE_REL="clusters/_template/instance.yaml"

registered_clusters() {
  # Clusters registered by tpg-aks-infra (Secret argo/kubeconfig-<cluster>), one per line
  kubectl -n "$ARGO_NS" get secret -l tpg.fleet/cluster -o json \
    | jq -r '.items[].metadata.labels["tpg.fleet/cluster"]' | sort -u
}

registered_wave() {
  # registered_wave CLUSTER -> tpg.fleet/wave label of argo/kubeconfig-<cluster> (default 1)
  local w
  w="$(kubectl -n "$ARGO_NS" get secret "kubeconfig-$1" -o json 2>/dev/null \
    | jq -r '.metadata.labels["tpg.fleet/wave"] // ""')"
  [[ "$w" =~ ^[0-9]+$ ]] && printf '%s' "$w" || printf '1'
}

fleet_has_cluster() { C="$2" yq -e '.clusters | has(strenv(C))' "$1/$FLEET_REL" >/dev/null 2>&1; }       # REPO CLUSTER
fleet_has_instance() { C="$2" I="$3" yq -e '.clusters[strenv(C)].instances | has(strenv(I))' "$1/$FLEET_REL" >/dev/null 2>&1; }  # REPO CLUSTER INSTANCE
fleet_has_instance_file() { C="$2" I="$3" yq -e '.clusters[strenv(C)].instances | has(strenv(I))' "$1" >/dev/null 2>&1; }  # FILE CLUSTER INSTANCE
fleet_clusters() { yq -r '.clusters // {} | keys | .[]' "$1/$FLEET_REL"; }                               # REPO
fleet_instances() { C="$2" yq -r '.clusters[strenv(C)].instances // {} | keys | .[]' "$1/$FLEET_REL"; }   # REPO CLUSTER

fleet_cluster_value() {
  # fleet_cluster_value REPO CLUSTER YQ_PATH DEFAULT -> fleet.yaml override, else _template/cluster.yaml, else DEFAULT
  local v
  # select(. != null) instead of // so that an explicit false is kept
  v="$(C="$2" yq -r ".clusters[strenv(C)]$3 | select(. != null)" "$1/$FLEET_REL")"
  [[ -n "$v" && "$v" != "null" ]] || v="$(yq -r "$3 | select(. != null)" "$1/$TEMPLATE_CLUSTER_REL")"
  [[ -n "$v" && "$v" != "null" ]] || v="$4"
  printf '%s' "$v"
}

fleet_instance_value() {
  # fleet_instance_value REPO CLUSTER INSTANCE YQ_PATH DEFAULT -> instance override, else _template/instance.yaml, else DEFAULT
  local v
  v="$(C="$2" I="$3" yq -r ".clusters[strenv(C)].instances[strenv(I)]$4 | select(. != null)" "$1/$FLEET_REL")"
  [[ -n "$v" && "$v" != "null" ]] || v="$(yq -r "$4 | select(. != null)" "$1/$TEMPLATE_INSTANCE_REL")"
  [[ -n "$v" && "$v" != "null" ]] || v="$5"
  printf '%s' "$v"
}

fleet_materialize() {
  # fleet_materialize REPO: write every instance entry to $WORK/fleet/<cluster>/<instance>.yaml
  # in the chart values layout (instance.name and backup.container filled in). Scripts edit
  # those files with yq; git_commit_push writes changed or new files back into fleet.yaml.
  local repo="$1" f="$1/$FLEET_REL" c i
  FLEET_CLONE="$repo"
  rm -rf "$WORK/fleet" "$WORK/fleet.orig"
  mkdir -p "$WORK/fleet"
  for c in $(fleet_clusters "$repo"); do
    mkdir -p "$WORK/fleet/$c"
    for i in $(fleet_instances "$repo" "$c"); do
      C="$c" I="$i" yq '(.clusters[strenv(C)].instances[strenv(I)] // {})
        | .instance.name = strenv(I)
        | .backup.container = (.backup.container // ("pg-backups-" + strenv(C)))' "$f" > "$WORK/fleet/$c/$i.yaml"
    done
  done
  cp -r "$WORK/fleet" "$WORK/fleet.orig"
}

fleet_yaml_style() {
  # fleet_yaml_style FILE (Round 13 addendum): clusters/fleet.yaml in block YAML.
  # Every flow map and list becomes block style: the JSON a workflow copies from
  # its plan ({"operator": {"version": ...}}) and a hand-written {a: b} alike.
  # Keys and strings lose their JSON quotes, and YAML keeps quotes only where a
  # value needs them ("true", "0", '*'). A line comment of a flow node moves
  # above its content; other comments stay. caBundle stays a literal block.
  yq -i 'with(... | select((tag == "!!map" or tag == "!!seq") and style == "flow" and line_comment != "");
           . head_comment = (. | line_comment) | . line_comment = "")
    | (... | select(tag == "!!map" or tag == "!!seq")) style=""
    | (... | select(tag == "!!str" and (style == "double" or style == "single"))) style=""
    | (.. | select(tag == "!!map" and has("caBundle")) | .caBundle | select(tag == "!!str")) style="literal"' "$1"
}

fleet_flush() {
  # fleet_flush REPO: copy edited or new materialized instance files back into fleet.yaml
  local repo="$1" f="$1/$FLEET_REL" p c i
  for p in "$WORK"/fleet/*/*.yaml; do
    [[ -f "$p" ]] || continue
    c="$(basename "$(dirname "$p")")"; i="$(basename "$p" .yaml)"
    cmp -s "$p" "$WORK/fleet.orig/$c/$i.yaml" 2>/dev/null && continue
    C="$c" I="$i" P="$p" yq -i '.clusters[strenv(C)].instances[strenv(I)] = (load(strenv(P)) | del(.instance.name))' "$f"
    mkdir -p "$WORK/fleet.orig/$c"
    cp "$p" "$WORK/fleet.orig/$c/$i.yaml"
    log "fleet.yaml: updated ${c}/${i}"
  done
}

# ----------------------------------------------------------------- Postgres helpers
pg_state() { tk -n "pg-$1" get postgres "$1" -o jsonpath='{.status.currentState}' 2>/dev/null || true; }

sts_ready() {
  # sts_ready INSTANCE -> 0 when readyReplicas equals spec.replicas
  local j
  j="$(tk -n "pg-$1" get statefulset "$1" -o json 2>/dev/null || echo '{}')"
  jq -e '(.spec.replicas // -1) == (.status.readyReplicas // -2)' <<<"$j" >/dev/null
}

_PG_WATCHED=""
_pg_ready() {
  # done-fn for pods_watch: Postgres currentState Running and the StatefulSet ready
  local s
  s="$(pg_state "$_PG_WATCHED")"
  printf 'Postgres %s: currentState=%s' "$_PG_WATCHED" "${s:-<none>}"
  [[ "$s" == "Running" ]] && sts_ready "$_PG_WATCHED"
}

pg_wait_ready() {
  # pg_wait_ready INSTANCE TIMEOUT_SECONDS: print the instance pods every 5 seconds
  # until the Postgres object is Running and every pod is ready. Fails fast when a
  # pod cannot start (pods_watch). Sets POD_WATCH_REASON / POD_WATCH_DETAIL.
  _PG_WATCHED="$1"
  pods_watch "pg-$1" "$2" --selector "postgres-instance=$1" --kubectl tk --label "Postgres $1" --done-fn _pg_ready
}

operator_wait_ready() {
  # operator_wait_ready TIMEOUT_SECONDS: the operator pods ready and its Postgres CRD established
  pods_watch tanzu-postgres-operator "$1" --kubectl tk --label "Tanzu Postgres operator" --done-fn _operator_ready
}
_operator_ready() {
  if tk wait --for=condition=Established --timeout=5s crd/postgres.sql.tanzu.vmware.com >/dev/null 2>&1; then
    printf 'CRD postgres.sql.tanzu.vmware.com Established'
    tk -n tanzu-postgres-operator get deploy -l app=postgres-operator -o json 2>/dev/null \
      | jq -e '(.items | length) > 0 and all(.items[]; (.status.availableReplicas // 0) >= 1)' >/dev/null
  else
    printf 'CRD postgres.sql.tanzu.vmware.com not established yet'
    return 1
  fi
}

latest_cr() {
  # latest_cr KIND NAMESPACE JQ_FILTER -> newest matching object as JSON, or empty
  tk -n "$2" get "$1" -o json 2>/dev/null \
    | jq -c "[.items[] | select($3)] | sort_by(.metadata.creationTimestamp) | last // empty"
}

major_of() { sed -E 's/^[^0-9]*([0-9]+).*/\1/' <<<"$1"; }

# ----------------------------------------------------------------- instance operations
busy_operations() {
  # busy_operations INSTANCE -> kinds with an unfinished operation (empty when idle)
  local ns="pg-$1" kind n
  for kind in postgresbackup postgresrestore postgresversionupgrade; do
    n="$(tk -n "$ns" get "$kind" -o json 2>/dev/null \
      | jq -r '[.items[] | select((.status.phase // "") | test("^(Succeeded|Failed|PreCheckFailed)$") | not)] | length')"
    [[ "${n:-0}" -eq 0 ]] || printf '%s ' "$kind"
  done
}

sync_instance_app() {
  # sync_instance_app CLUSTER INSTANCE TIMEOUT [REVISION] [app_sync_wait options...]:
  # generate the Application when the instance is new, sync it (at REVISION,
  # default the fleet branch head) and watch the instance pods until it is
  # Healthy. Returns app_sync_wait's code, or 4 when the Application was not generated.
  local app="tpg-$1-$2" inst="$2" timeout="$3" rev="${4:-}" i
  shift 3; [[ $# -gt 0 ]] && shift
  if ! app_exists "$app"; then
    appset_refresh tpg-instances
    for i in $(seq 1 40); do
      app_exists "$app" && break
      log "waiting for the ApplicationSet tpg-instances to generate ${app}"
      sleep 15
    done
    app_exists "$app" || { SYNC_FAIL_REASON=APP_NOT_GENERATED; SYNC_FAIL_DETAIL="$app"; return 4; }
  fi
  [[ -n "$rev" ]] || rev="$(fleet_head)"
  _PG_WATCHED="$inst"
  app_sync_wait "$app" "$timeout" ${rev:+--revision "$rev"} --pods "pg-$inst" "postgres-instance=$inst" --ready-fn _pg_ready "$@"
}

# ----------------------------------------------------------------- input parameters
norm_operator_version() {
  # 4.5.0 | v4.5.0 -> v4.5.0 (operator chart OCI tag)
  local v="${1#v}"
  printf 'v%s' "$v"
}

norm_postgres_version() {
  # 17.6 | postgres-17.6 -> postgres-17.6 (PostgresVersion name)
  local v="${1#postgres-}"
  printf 'postgres-%s' "$v"
}

split_list() {
  # split_list "a, b,,c" -> one trimmed item per line
  tr ',' '\n' <<<"$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true
}

# ----------------------------------------------------------------- clusterMap
# The optional clusterMap input (P_CLUSTER_MAP, YAML or JSON) selects clusters and
# instances and carries per-cluster and per-instance values. The validate step
# checks it against workflows/params/cluster-map-keys.yaml (clustermap.py
# validate); the step scripts read it through these functions. Values come back
# as strings; a key that is not set returns the DEFAULT argument, which the
# caller passes from the matching workflow input, so an input is the default for
# every target and a map key overrides it for one cluster or instance.
TPG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cmap_keys_file() {
  if [[ -n "${CMAP_KEYS:-}" ]]; then printf '%s' "$CMAP_KEYS"
  elif [[ -f "$TPG_LIB_DIR/cluster-map-keys.yaml" ]]; then printf '%s' "$TPG_LIB_DIR/cluster-map-keys.yaml"
  else printf '%s' "$TPG_LIB_DIR/../params/cluster-map-keys.yaml"; fi
}

cmap_set() { [[ -n "$(tr -d '[:space:]' <<<"${P_CLUSTER_MAP:-}")" ]]; }

cmap_to_json() {
  # cmap_to_json TEXT -> the map as JSON. Parsed as YAML (JSON is YAML), and every
  # float is kept as its text, so an unquoted 16.10 stays "16.10" and is not
  # read as 16.1.
  printf '%s\n' "$1" | yq -o=json -I=0 '(.. | select(tag == "!!float")) tag = "!!str"'
}

cmap_load() {
  # cmap_load: normalized map in $WORK/cmap.json ({} without clusterMap)
  [[ -s "$WORK/cmap.json" ]] && return 0
  if ! cmap_set; then echo '{}' > "$WORK/cmap.json"; return 0; fi
  cmap_to_json "$P_CLUSTER_MAP" > "$WORK/cmap.raw.json" || { log "clusterMap is not valid YAML or JSON"; return 1; }
  yq -o=json -I=0 '.' "$(cmap_keys_file)" > "$WORK/cmap-keys.json"
  python3 "$TPG_LIB_DIR/clustermap.py" normalize --map "$WORK/cmap.raw.json" \
    --keys "$WORK/cmap-keys.json" --out "$WORK/cmap.json"
}

cmap_clusters() { cmap_load && jq -r 'keys[]' "$WORK/cmap.json"; }
cmap_instances() { cmap_load && jq -r --arg c "$1" '.[$c].instances // {} | keys[]' "$WORK/cmap.json"; }   # CLUSTER
cmap_has_cluster() { cmap_load && jq -e --arg c "$1" 'has($c)' "$WORK/cmap.json" >/dev/null; }              # CLUSTER
cmap_has_instance() { cmap_load && jq -e --arg c "$1" --arg i "$2" '.[$c].instances // {} | has($i)' "$WORK/cmap.json" >/dev/null; }

cmap_cval() {
  # cmap_cval CLUSTER KEY [DEFAULT] -> cluster value (a list joined with commas)
  local v
  cmap_load || return 1
  v="$(jq -r --arg c "$1" --arg k "$2" '.[$c][$k] // empty | if type == "array" then join(",") else . end' "$WORK/cmap.json")"
  printf '%s' "${v:-${3:-}}"
}

cmap_ival() {
  # cmap_ival CLUSTER INSTANCE KEY [DEFAULT] -> instance value (a list joined with commas)
  local v
  cmap_load || return 1
  v="$(jq -r --arg c "$1" --arg i "$2" --arg k "$3" \
    '.[$c].instances[$i][$k] // empty | if type == "array" then join(",") else . end' "$WORK/cmap.json")"
  printf '%s' "${v:-${4:-}}"
}

selected_instances() {
  # selected_instances REPO CLUSTER -> instances this run acts on, one per line:
  # the clusterMap entries of the cluster, else the instances input (a list, or
  # all/empty for every instance declared for the cluster in clusters/fleet.yaml)
  if cmap_set; then cmap_instances "$2"; return; fi
  if [[ -z "${P_INSTANCES:-}" || "${P_INSTANCES}" == "all" ]]; then fleet_instances "$1" "$2"; return; fi
  split_list "$P_INSTANCES"
}

cmap_guard() {
  # cmap_guard CLUSTER INSTANCE -> 0 when the clusterMap sets no postgresVersion
  # for the instance or the live instance runs that version (use_cluster first).
  # Otherwise prints the mismatch and returns 1: the caller records
  # SKIPPED_VERSION_MISMATCH and leaves the instance alone.
  local want live
  cmap_set || return 0
  want="$(cmap_ival "$1" "$2" postgresVersion)"
  [[ -n "$want" ]] || return 0
  live="$(tk -n "pg-$2" get postgres "$2" -o jsonpath='{.spec.postgresVersion.name}' 2>/dev/null || true)"
  [[ "$live" == "$want" ]] && return 0
  printf 'clusterMap postgresVersion is %s, the live instance runs %s' "$want" "${live:-nothing}"
  return 1
}

# ----------------------------------------------------------------- patch files (Round 14, D76 to D78)
# tpg-patch and tpg-create-instance take patch files from the machine that submits
# the run: the path inputs (postgresPatchFilePath, valuesPatchFilePath,
# operatorValuesPatchFilePath, and the clusterMap keys of the same names) keep the
# path as the user gave it, and the input patchFiles carries the contents,
# {"<path>": "<base64>"} (scripts/submit fill it; scripts/submit/pack-patch-files.sh
# prints it for a plain argo submit). The workflow stores each file in the fleet
# repository under its own name plus a 5-character UID:
#   postgres, values   charts/tpg-instance/patches/<name>-<uid>.yaml
#   operator values    patches/operator/<name>-<uid>.yaml
# and records it per target in clusters/fleet.yaml, one current file per kind and
# the one before it:
#   clusters.<c>.instances.<i>.patches.<postgres|values>:
#     current: patches/<name>-<uid>.yaml          (relative to charts/tpg-instance)
#     previous: {path: patches/<old>.yaml, commit: <sha that added it>}
#   clusters.<c>.operator.patches.values:
#     current: patches/operator/<name>-<uid>.yaml  (repository path)
#     previous: {path: ..., commit: ...}
# Only current is applied. The operator Application reads a fixed file per
# cluster, patches/operator/clusters/<c>.yaml, a copy of its current file, so a
# sync at the commit of a pull request branch sees the new file (the ApplicationSet
# itself reads clusters/fleet.yaml on the fleet branch). The instance chart reads
# clusters/fleet.yaml at the synced commit for the same reason.
OPERATOR_NS="tanzu-postgres-operator"
PATCH_INSTANCE_DIR="charts/tpg-instance/patches"
PATCH_OPERATOR_DIR="patches/operator"
PATCH_EFFECTIVE_DIR="patches/operator/clusters"

patch_norm() {  # patch_norm PATH -> PATH without leading ./
  local p="$1"
  while [[ "$p" == ./* ]]; do p="${p#./}"; done
  printf '%s' "$p"
}

patch_files_json() {
  # patch_files_json -> the patchFiles input, {"<path>": "<base64>"} ({} when empty).
  # Read from this run's Workflow object: the value may be larger than one
  # environment variable or container argument can be (128 KiB). P_PATCH_FILES,
  # when set, is used instead (offline tests).
  local v
  if [[ -s "$WORK/patch-files.json" ]]; then cat "$WORK/patch-files.json"; return 0; fi
  mkdir -p "$WORK"
  if [[ -n "${P_PATCH_FILES+x}" ]]; then
    v="$P_PATCH_FILES"
  else
    v="$(kubectl -n "$ARGO_NS" get workflow "${WF:-}" -o json 2>/dev/null \
      | jq -r '[.spec.arguments.parameters[]? | select(.name == "patchFiles") | (.value // "")][0] // ""')" || v=""
  fi
  [[ -n "$(tr -d '[:space:]' <<<"$v")" ]] || v='{}'
  jq -c 'with_entries(.key |= sub("^(\\./)+"; ""))' <<<"$v" > "$WORK/patch-files.json" || return 1
  cat "$WORK/patch-files.json"
}

patch_file_write() {
  # patch_file_write PATH DEST: the contents patchFiles carries for PATH, into DEST;
  # 1 when patchFiles has no entry for PATH or it is not base64
  local b
  b="$(patch_files_json | jq -r --arg p "$(patch_norm "$1")" '.[$p] // empty')"
  [[ -n "$b" ]] || return 1
  printf '%s' "$b" | base64 -d > "$2" 2>/dev/null
}

patch_stored_name() {  # patch_stored_name PATH UID -> <name>-<uid>.<ext> (the base name only)
  local b ext
  b="${1##*/}"; ext="${b##*.}"
  printf '%s-%s.%s' "${b%.*}" "$2" "$ext"
}

patch_uid() {  # 5 characters, lowercase letters and digits
  LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 5
}

patch_names() {
  # patch_names -> {"<path as given>": "<repository path of the stored file>"} of
  # this run (run record patch.names)
  local d
  d="$(run_data patch.names | jq -r '.detail // empty' 2>/dev/null)"
  [[ -n "$d" ]] && printf '%s' "$d" || printf '{}'
}

patch_names_plan() {
  # patch_names_plan REPO KIND=PATH...: a stored name for every PATH that has none
  # yet in this run (one UID per file, unused in REPO), recorded as patch.names.
  # KIND postgres or values: charts/tpg-instance/patches/; operator: patches/operator/
  local repo="$1" names a kind p n uid dir
  shift
  names="$(patch_names)"
  for a in "$@"; do
    kind="${a%%=*}"; p="$(patch_norm "${a#*=}")"
    [[ -n "$p" ]] || continue
    jq -e --arg p "$p" 'has($p)' <<<"$names" >/dev/null && continue
    if [[ "$kind" == operator ]]; then dir="$PATCH_OPERATOR_DIR"; else dir="$PATCH_INSTANCE_DIR"; fi
    n=""
    for _ in 1 2 3 4 5 6 7 8; do
      uid="$(patch_uid)"; n="${dir}/$(patch_stored_name "$p" "$uid")"
      [[ -e "$repo/$n" ]] && { n=""; continue; }
      jq -e --arg n "$n" 'any(.[]; . == $n)' <<<"$names" >/dev/null && { n=""; continue; }
      break
    done
    [[ -n "$n" ]] || { log "no unused name for ${p} after 8 tries"; return 1; }
    names="$(jq -c --arg p "$p" --arg n "$n" '. + {($p): $n}' <<<"$names")"
  done
  record_entry patch.names SET "" "$names"
}

patch_store() {
  # patch_store REPO PATH KIND -> the path clusters/fleet.yaml records (chart-relative
  # patches/<n> for postgres and values, patches/operator/<n> for operator); writes
  # the file from patchFiles under its stored name (once per checkout)
  local repo="$1" p dest
  p="$(patch_norm "$2")"
  dest="$(patch_names | jq -r --arg p "$p" '.[$p] // empty')"
  [[ -n "$dest" ]] || { log "patch_store: no stored name for ${p} (patch.names)"; return 1; }
  mkdir -p "$repo/${dest%/*}"
  [[ -f "$repo/$dest" ]] || patch_file_write "$p" "$repo/$dest" || { log "patch_store: patchFiles has no content for ${p}"; return 1; }
  if [[ "$3" == operator ]]; then printf '%s' "$dest"; else printf '%s' "${dest#charts/tpg-instance/}"; fi
}

patch_materialize() {
  # patch_materialize REPO: write the stored files of this run that REPO's
  # clusters/fleet.yaml references and REPO does not have yet (tpg-create-instance:
  # discover and fleet-commit work on their own clones); prints the paths written
  local repo="$1" p dest rel
  while IFS=$'\t' read -r p dest; do
    [[ -n "$dest" ]] || continue
    rel="${dest#charts/tpg-instance/}"
    grep -qF -- "$rel" "$repo/$FLEET_REL" 2>/dev/null || continue
    [[ -f "$repo/$dest" ]] && continue
    mkdir -p "$repo/${dest%/*}"
    patch_file_write "$p" "$repo/$dest" || { log "patch_materialize: no content for ${p}"; return 1; }
    printf '%s\n' "$dest"
  done < <(patch_names | jq -r 'to_entries[] | [.key, .value] | @tsv')
}

patch_kind_path() {  # patch_kind_path CLUSTER INSTANCE KIND -> yq path of the kind node
  if [[ "$3" == operator ]]; then printf '.clusters["%s"].operator.patches.values' "$1"
  else printf '.clusters["%s"].instances["%s"].patches.%s' "$1" "$2" "$3"; fi
}

patch_ref() {
  # patch_ref FLEET_FILE CLUSTER INSTANCE KIND -> the current file of KIND (postgres,
  # values: chart-relative; operator: repository path), empty when none. A Round 11
  # list with one file counts as current; a longer list returns 2 (not applied:
  # merge the files into one and run tpg-patch; README, Upgrading to Round 14)
  local v
  v="$(yq -o=json -I=0 "$(patch_kind_path "$2" "$3" "$4") // null" "$1" 2>/dev/null | jq -r '
    if type == "array" then (if length <= 1 then (.[0] // "") else "LIST:\(length)" end)
    elif type == "object" then (.current // "")
    elif type == "string" then .
    else "" end' 2>/dev/null)"
  [[ "$v" == LIST:* ]] && return 2
  [[ "$v" == null ]] && v=""
  printf '%s' "$v"
}

patch_commit_of() {
  # patch_commit_of REPO PATH -> the newest commit that touched PATH (the one that
  # added a stored patch file, which is never changed afterwards); the clone is
  # deepened when it is too shallow to have it
  local sha
  sha="$(git -C "$1" log -1 --format=%H -- "$2" 2>/dev/null)"
  if [[ -z "$sha" && -f "$1/.git/shallow" ]]; then
    git -C "$1" fetch --quiet --unshallow origin 2>/dev/null || true
    sha="$(git -C "$1" log -1 --format=%H -- "$2" 2>/dev/null)"
  fi
  printf '%s' "$sha"
}

patch_set_current() {
  # patch_set_current REPO CLUSTER INSTANCE KIND NEW: NEW becomes current (empty:
  # clear), the former current becomes previous with the commit that added it
  local repo="$1" path old full commit=""
  path="$(patch_kind_path "$2" "$3" "$4")"
  old="$(patch_ref "$repo/$FLEET_REL" "$2" "$3" "$4")" || old=""
  [[ "$old" != "$5" ]] || return 0
  if [[ -n "$old" ]]; then
    full="$old"; [[ "$4" == operator ]] || full="charts/tpg-instance/$old"
    commit="$(patch_commit_of "$repo" "$full")"
  fi
  OLD="$old" NEW="$5" SHA="$commit" yq -i "
    ${path} = ((${path} // {}) | select(tag == \"!!map\") // {})
    | ${path}.current = strenv(NEW)
    | (select(strenv(NEW) == \"\") | ${path}) |= del(.current)
    | (select(strenv(OLD) != \"\") | ${path}.previous) = {\"path\": strenv(OLD), \"commit\": strenv(SHA)}" "$repo/$FLEET_REL"
}

operator_effective_rel() { printf '%s/%s.yaml' "$PATCH_EFFECTIVE_DIR" "$1"; }   # CLUSTER

operator_effective_write() {
  # operator_effective_write REPO CLUSTER: patches/operator/clusters/<c>.yaml follows
  # the cluster's current operator values file (removed when there is none)
  local repo="$1" cur eff
  cur="$(patch_ref "$repo/$FLEET_REL" "$2" "" operator)" || cur=""
  eff="$(operator_effective_rel "$2")"
  if [[ -z "$cur" ]]; then rm -f "$repo/$eff"; return 0; fi
  mkdir -p "$repo/$PATCH_EFFECTIVE_DIR"
  { printf '# Operator values of %s, read by the tpg-operator Application (Round 14).\n' "$2"
    printf '# Written by tpg-patch from %s (clusters/fleet.yaml\n' "$cur"
    printf '# clusters.%s.operator.patches.values.current); do not edit.\n' "$2"
    cat "$repo/$cur"; } > "$repo/$eff"
}

# ----------------------------------------------------------------- chart rendering (tpg-patch dry runs)
instance_values() {
  # instance_values REPO CLUSTER INSTANCE -> the Helm values the tpg-instances
  # ApplicationSet passes for the instance (after the two template value files):
  # the cluster overrides, cluster.name and backup.container, then the instance
  # entry (with its patches lists) and instance.name
  # shellcheck disable=SC2016  # yq variables, not shell
  C="$2" I="$3" yq '.clusters[strenv(C)] as $c | ($c.instances[strenv(I)] // {}) as $i
    | ($c | with_entries(select(.key != "instances" and .key != "operator")))
    * {"cluster": {"name": strenv(C)}, "backup": {"container": "pg-backups-" + strenv(C)}}
    * $i * {"instance": {"name": strenv(I)}}' "$1/$FLEET_REL"
}

instance_effective() {
  # instance_effective REPO CLUSTER INSTANCE YQ_PATH DEFAULT -> the value the chart
  # sees for YQ_PATH: the instance's Helm values (instance_values), then its
  # current values patch file (patch_ref; null removes), then valuesOverride,
  # else DEFAULT. A tpg-patch values file may switch the backup
  # scheduler or FerretDB (D70, D71), which clusters/fleet.yaml alone does not show.
  local d n=0 f v
  d="$(mktemp -d)"
  instance_values "$1" "$2" "$3" > "$d/0.yaml"
  f="$(patch_ref "$1/$FLEET_REL" "$2" "$3" values)" || f=""
  if [[ -n "$f" && -f "$1/charts/tpg-instance/$f" ]]; then
    n=$((n + 1)); cp "$1/charts/tpg-instance/$f" "$d/${n}.yaml"
  fi
  # valuesOverride (written by tpg-restore) wins over the patch files, as in tpg.ctx
  n=$((n + 1)); yq '.valuesOverride // {}' "$d/0.yaml" > "$d/${n}.yaml"
  # shellcheck disable=SC2046  # the numbered files, in order
  v="$(yq eval-all ". as \$x ireduce ({}; . * \$x) | $4 | select(. != null)" $(for f in $(seq 0 "$n"); do echo "$d/${f}.yaml"; done) 2>/dev/null)"
  rm -rf "$d"
  [[ -n "$v" && "$v" != "null" ]] || v="$5"
  printf '%s' "$v"
}
instance_render() {
  # instance_render REPO CLUSTER INSTANCE -> the manifests Argo CD will apply for
  # the instance, rendered with helm from the repository checkout (patch files included)
  # The value files in the order the tpg-instances ApplicationSet gives them: the
  # two templates, clusters/fleet.yaml (the chart reads the patch files of the
  # instance from it, Round 14), then the instance values without patches
  local vals
  vals="$(mktemp)"
  instance_values "$1" "$2" "$3" | yq 'del(.patches)' > "$vals"
  helm template "$3" "$1/charts/tpg-instance" --namespace "pg-$3" \
    -f "$1/$TEMPLATE_CLUSTER_REL" -f "$1/$TEMPLATE_INSTANCE_REL" -f "$1/$FLEET_REL" -f "$vals"
  local rc=$?
  rm -f "$vals"
  return "$rc"
}

qty_bytes() {
  # qty_bytes QUANTITY -> bytes (integer), for comparing storage sizes
  awk -v q="$1" 'BEGIN {
    if (match(q, /^[0-9.]+/) == 0) { print -1; exit }
    n = substr(q, 1, RLENGTH); u = substr(q, RLENGTH + 1)
    m["Ki"] = 1024; m["Mi"] = 1024^2; m["Gi"] = 1024^3; m["Ti"] = 1024^4; m["Pi"] = 1024^5
    m["k"] = 1000; m["M"] = 1000^2; m["G"] = 1000^3; m["T"] = 1000^4; m["P"] = 1000^5; m[""] = 1
    if (!(u in m)) { print -1; exit }
    printf "%.0f\n", n * m[u] }'
}
