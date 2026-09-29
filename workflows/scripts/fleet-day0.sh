#!/usr/bin/env bash
# fleet-day0.sh WORKFLOW_NAME CLUSTERS_JSON
# Plan the tpg-day0 inputs into clusters/fleet.yaml for every selected cluster.
# Nothing is pushed here: the plan goes to the pre-check first, and
# fleet-commit.sh writes only the clusters whose pre-check is PASSED or MANAGED
# (design decision D61), so a BLOCKED cluster never gets entries in Git.
#
# The targets and their values come from clusterMap (P_CLUSTER_MAP) or from the
# clusters and instances inputs; the other inputs are the defaults of every
# target and a clusterMap key overrides them for one cluster or instance. Each
# value is written to the clusters/fleet.yaml paths listed for its key in
# workflows/params/cluster-map-keys.yaml ("fleet"), so a new Day 0 key needs no
# change here:
#   clusters.<cluster>.operator.version                 operatorVersion
#   clusters.<cluster>.cluster.maxReadReplicas          maxReadReplicas
#   clusters.<cluster>.instances.<instance>.instance.*  postgresVersion, highAvailability,
#                                                       readReplicas, sizing, storageClass,
#                                                       exposure (service type and annotations)
#   clusters.<cluster>.instances.<instance>.backup.*    enableSSL, caBundle, backupSchedule (scheduled,
#                                                       operatorSchedules with operator, D70)
#   clusters.<cluster>.instances.<instance>.ferret.*    ferret and its keys (D71; false removes the block)
#   clusters.<cluster>.instances.<instance>.network.*   networkPolicy and its rules
# Existing entries keep their other settings.
#
# Versions (design decision D49): the cluster decides, not clusters/fleet.yaml.
#   - The operator (or an instance) does not run on the target yet: the input wins
#     and replaces whatever fleet.yaml declares (FLEET_OVERRIDDEN, logged and in
#     the result).
#   - It runs the requested version: nothing to change.
#   - It runs another version: the cluster is BLOCKED (UPGRADE_REQUIRED when the
#     input is newer, DOWNGRADE_NOT_ALLOWED when it is older, VERSION_UNKNOWN when
#     the running version cannot be read), fleet.yaml is not changed for it, and
#     the pre-check reports it; the other clusters go ahead. tpg-upgrade moves a
#     running operator or instance to another version.
#
# FLEET_MODE=create (tpg-create-instance runs this script with it): the operator
# must already run on the cluster (OPERATOR_NOT_INSTALLED otherwise), no operator
# key is written, patch files are checked with the creation rules (D60), stored
# under their name plus a UID (the contents come in patchFiles, Round 14) and
# recorded as current, the rendered instance is dry-run on the cluster, and an
# instance that exists is
# compared with the request instead of being written again (ALREADY_EXISTS,
# INSTANCE_EXISTS).
#
# Outputs:
#   /tmp/fleet.json       the planned clusters/fleet.yaml as JSON (discover reads it)
#   /tmp/fleet-base.json  clusters/fleet.yaml as cloned, as JSON (fleet-commit.sh
#                         refuses to write a cluster whose entry changed since)
# Both carry a caBundle equal to the tpg-settings bundle as CA_PLACEHOLDER, so
# the parameters stay under the 128 KiB limit of one container argument.
# Notes (FLEET_OVERRIDDEN, blocked clusters) are recorded as plan.git.
# Inputs (environment): P_CLUSTER_MAP P_INSTANCES P_HA P_OPERATOR_VERSION
#   P_POSTGRES_VERSION P_READ_REPLICAS P_STORAGE_SIZE P_WAL_STORAGE_SIZE
#   P_STORAGE_CLASS P_CPU P_MEMORY P_BACKUP_SCHEDULE P_BACKUP_ENABLE_SSL
#   P_EXPOSURE P_SERVICE_ANNOTATIONS P_ALLOWED_SOURCE_RANGES P_READ_ONLY_EXPOSURE
#   P_READ_ONLY_SERVICE_ANNOTATIONS P_NETWORK_POLICY P_INGRESS_FROM_NAMESPACES
#   P_INGRESS_FROM_CIDRS P_EGRESS_TO_CIDRS P_OPERATOR_FULL_SCHEDULE P_OPERATOR_INCR_SCHEDULE
#   P_FERRET P_FERRET_REPLICAS P_FERRET_RO_REPLICAS P_FERRET_EXPOSURE P_FERRET_SECRET
#   P_FERRET_RO_SECRET P_DRY_RUN
WF="$1"; CLUSTERS_JSON="$2"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh
MODE="${FLEET_MODE:-day0}"          # day0 | create (tpg-create-instance)
WF_ID="day0"; [[ "$MODE" == "create" ]] && WF_ID="create-instance"
result_guard result.git

REPO="$WORK/repo"
F="$REPO/clusters/fleet.yaml"
git_clone "$REPO"
cp "$F" "$WORK/fleet.before.yaml"
CA_BUNDLE="$(setting backupCaBundle 2>/dev/null || true)"
plan_json "$F" "$CA_BUNDLE" > /tmp/fleet-base.json   # CA bundle as CA_PLACEHOLDER (lib.sh)
FAILED=(); NOTES=(); BLOCKED=()

# ---- the effective targets: clusterMap, or the clusters x instances inputs,
# with the inputs as defaults of every key the workflow uses
yq -o=json -I=0 '.' "$(cmap_keys_file)" > "$WORK/keys.json"
if cmap_set; then
  cmap_load
  cp "$WORK/cmap.json" "$WORK/targets.json"
else
  jq -cn --argjson cl "$CLUSTERS_JSON" --arg inst "$(split_list "${P_INSTANCES:-}" | paste -sd,)" '
    ($inst | split(",") | map(select(length > 0))) as $il
    | reduce $cl[] as $c ({}; .[$c] = {instances: (reduce $il[] as $i ({}; .[$i] = {}))})' > "$WORK/targets.json"
fi
opv_flag=""; [[ -z "${P_OPERATOR_VERSION:-}" ]] || opv_flag="$(norm_operator_version "$P_OPERATOR_VERSION")"
pgv_flag=""; [[ -z "${P_POSTGRES_VERSION:-}" ]] || pgv_flag="$(norm_postgres_version "$P_POSTGRES_VERSION")"
map_flag() {  # map_flag TEXT -> the YAML or JSON mapping as compact JSON ("" when empty)
  [[ -n "$(tr -d '[:space:]' <<<"${1:-}")" ]] || { printf ''; return; }
  printf '%s\n' "$1" | yq -o=json -I=0 '.' 2>/dev/null || printf '%s' "$1"
}
jq -cn --arg operatorVersion "$opv_flag" --arg postgresVersion "$pgv_flag" --arg highAvailability "${P_HA:-}" \
  --arg readReplicas "${P_READ_REPLICAS:-}" --arg storageSize "${P_STORAGE_SIZE:-}" \
  --arg walStorageSize "${P_WAL_STORAGE_SIZE:-}" --arg storageClass "${P_STORAGE_CLASS:-}" \
  --arg cpu "${P_CPU:-}" --arg memory "${P_MEMORY:-}" --arg backupSchedule "${P_BACKUP_SCHEDULE:-fleet}" \
  --arg backupEnableSSL "${P_BACKUP_ENABLE_SSL:-false}" \
  --arg exposure "${P_EXPOSURE:-}" --arg serviceAnnotations "$(map_flag "${P_SERVICE_ANNOTATIONS:-}")" \
  --arg readOnlyExposure "${P_READ_ONLY_EXPOSURE:-}" \
  --arg readOnlyServiceAnnotations "$(map_flag "${P_READ_ONLY_SERVICE_ANNOTATIONS:-}")" \
  --arg allowedSourceRanges "${P_ALLOWED_SOURCE_RANGES:-}" --arg internalLoadBalancerSubnet "${P_INTERNAL_LB_SUBNET:-}" \
  --arg networkPolicy "${P_NETWORK_POLICY:-}" --arg ingressFromNamespaces "${P_INGRESS_FROM_NAMESPACES:-}" \
  --arg ingressFromPodLabels "$(map_flag "${P_INGRESS_FROM_POD_LABELS:-}")" \
  --arg ingressFromCidrs "${P_INGRESS_FROM_CIDRS:-}" --arg egressToCidrs "${P_EGRESS_TO_CIDRS:-}" \
  --arg egressToFqdns "${P_EGRESS_TO_FQDNS:-}" \
  --arg postgresPatchFilePath "${P_POSTGRES_PATCH_FILES:-}" --arg valuesPatchFilePath "${P_VALUES_PATCH_FILES:-}" \
  --arg operatorFullSchedule "${P_OPERATOR_FULL_SCHEDULE-0 0 * * 0}" \
  --arg operatorIncrementalSchedule "${P_OPERATOR_INCR_SCHEDULE-0 0 * * 1-6}" \
  --arg ferret "${P_FERRET:-}" --arg ferretReplicas "${P_FERRET_REPLICAS:-1}" \
  --arg ferretReadOnlyReplicas "${P_FERRET_RO_REPLICAS:-0}" --arg ferretExposure "${P_FERRET_EXPOSURE:-}" \
  --arg ferretSecretName "${P_FERRET_SECRET:-}" --arg ferretReadOnlySecretName "${P_FERRET_RO_SECRET:-}" \
  '$ARGS.named' > "$WORK/flags.json"
# shellcheck disable=SC2016  # jq program
jq -c --arg w "$WF_ID" --slurpfile keys "$WORK/keys.json" --slurpfile flags "$WORK/flags.json" '
  $keys[0] as $k | $flags[0] as $f
  | def fill($level; $entry):
      reduce ($level | to_entries[] | select(.value.workflows[$w] != null)) as $e ($entry;
        if has($e.key) then .
        # an input readReplicas is a default for HA instances only: not for an
        # entry that sets highAvailability: false itself (Round 13 addendum)
        elif $e.key == "readReplicas" and ($entry | has("highAvailability"))
             and (($entry.highAvailability | tostring) == "false") then .
        else ((if ($e.value | has("flag")) then $e.value.flag else $e.key end)) as $fl
          | (if $fl == "" then "" else ($f[$fl] // "") end) as $v
          | if $v != "" then .[$e.key] = $v else . end
        end);
    with_entries(.value |= (fill($k.cluster; .)
      | .instances = ((.instances // {}) | with_entries(.value |= fill($k.instance; .)))))
' "$WORK/targets.json" > "$WORK/effective.raw.json"
# Lists and maps given as inputs are checked and normalized like clusterMap values
if ! errs="$(python3 "$TPG_LIB_DIR/clustermap.py" normalize --map "$WORK/effective.raw.json" \
      --keys "$WORK/keys.json" --out "$WORK/effective.json")"; then
  record result.git FAILED INVALID_INPUT "$(tr '\n' ';' <<<"$errs")"
  exit 1
fi

# ---- what runs on the target now
live_operator() {
  # live_operator -> "none", "unknown" or the running operator version (vX.Y.Z)
  # of the current cluster (use_cluster first, in this shell: tk reads CLUSTER)
  local img tag
  img="$(operator_deployments 2>/dev/null \
    | jq -rs '[.[].spec.template.spec.containers[] | select(.image | test("postgres-operator")) | .image][0] // ""')"
  [[ -n "$img" ]] || { echo none; return; }
  tag="${img##*:}"; tag="${tag%%@*}"
  if [[ "$tag" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then norm_operator_version "$tag"; else echo unknown; fi
}
live_postgres() {
  # live_postgres INSTANCE -> "none" or the spec.postgresVersion.name of the running instance (use_cluster first)
  local v
  v="$(tk -n "pg-$1" get postgres "$1" -o jsonpath='{.spec.postgresVersion.name}' 2>/dev/null || true)"
  if tk -n "pg-$1" get postgres "$1" >/dev/null 2>&1; then printf '%s' "${v:-unknown}"; else echo none; fi
}
newer() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]; }   # A newer than B
block() {  # block CLUSTER REASON DETAIL: the cluster keeps its fleet.yaml entry; the pre-check reports it
  record_entry "block.$1" BLOCKED "$2" "$3"
  BLOCKED+=("$1: $2 $3")
}

write_value() {  # write_value BASE_YQ_PATH FLEET_PATH FORMAT VALUE (paths from cluster-map-keys.yaml)
  local base="$1" path="$2" fmt="$3" v="$4" expr
  [[ "$path" =~ ^(\.[A-Za-z0-9_]+)+$ ]] || { FAILED+=("cluster-map-keys.yaml: invalid fleet path ${path}"); return; }
  case "$fmt" in
    number)   expr="(strenv(V) | tonumber)" ;;
    boolean)  expr="(strenv(V) == \"true\")" ;;
    list|map) expr="(strenv(V) | from_yaml)" ;;   # normalized JSON list or object
    *)        expr="strenv(V)" ;;
  esac
  V="$v" C="$CUR_C" I="${CUR_I:-}" yq -i "${base}${path} = ${expr}" "$F"
}
key_rows() {  # key_rows LEVEL -> "key<TAB>format<TAB>paths" for the keys this workflow writes
  jq -r --arg w "$WF_ID" --arg l "$1" '.[$l] | to_entries[]
    | select(.value.workflows[$w] != null and (.value.fleet // [] | length) > 0)
    | [.key, (.value.format // "string"), (.value.fleet | join(" "))] | @tsv' "$WORK/keys.json"
}
entry_value() {  # entry_value JSON KEY -> string value, or compact JSON for a list or map
  jq -r --arg k "$2" '.[$k] // "" | if type == "string" then . else tojson end' <<<"$1"
}
ACNS="$(setting acnsEnabled 2>/dev/null || true)"
CHART_PREFIX="charts/tpg-instance/"

# ---- tpg-create-instance: patch files at creation (design decision D60, creation rules)
# The same files as tpg-patch, with the rules of a new instance: sizes, the
# storage class and the backup location fields may be set, because nothing runs
# yet; the fields owned by inputs (name, postgresVersion, highAvailability) are
# refused, so each value has one source.
create_patch_errors() {  # create_patch_errors KIND FILE(repo path) NAME -> one error per line
  # (the validate step has checked the type of the file: patchcheck.py)
  local kind="$1" f="$2" n="$3"
  if [[ "$kind" == "postgres" ]]; then
    yq -e '.spec.postgresVersion == null' "$REPO/$f" >/dev/null || echo "$n: spec.postgresVersion comes from the postgresVersion input or map key"
    yq -e '.spec.highAvailability == null' "$REPO/$f" >/dev/null || echo "$n: spec.highAvailability comes from the highAvailability and readReplicas inputs or map keys"
    for k in serviceType serviceAnnotations readOnlyServiceType readOnlyServiceAnnotations; do
      yq -e ".spec.${k} == null" "$REPO/$f" >/dev/null || echo "$n: spec.${k} comes from the exposure inputs or map keys"
    done
  else
    for k in .instance.name .instance.postgresVersion .instance.highAvailability .instance.serviceType .cluster .patches .valuesOverride; do
      yq -e "${k} == null" "$REPO/$f" >/dev/null || echo "$n: ${k#.} cannot be set by a values patch (it comes from the inputs; instance.serviceType is replaced by instance.exposure)"
    done
  fi
}
# Patch files at creation (Round 14): the contents come from patchFiles; each is
# stored under its own name plus a UID and becomes the instance's current file.
# A declared instance whose current file holds the same contents keeps it, so a
# repeated tpg-create-instance stays ALREADY_EXISTS.
if [[ "$MODE" == "create" ]]; then
  mapfile -t pairs < <(jq -r '[.[] | .instances // {} | .[] | (if .postgresPatchFilePath then "postgres=" + .postgresPatchFilePath else empty end),
    (if .valuesPatchFilePath then "values=" + .valuesPatchFilePath else empty end)] | unique | .[]' "$WORK/effective.json")
  if [[ "${#pairs[@]}" -gt 0 ]] && ! patch_names_plan "$REPO" "${pairs[@]}"; then
    record result.git FAILED UNEXPECTED_ERROR "no stored names for the patch files"; exit 1
  fi
fi
create_patch_store() {  # create_patch_store CLUSTER INSTANCE KIND PATH -> the chart-relative path to record
  local cur tmp
  cur="$(patch_ref "$F" "$1" "$2" "$3" 2>/dev/null)" || cur=""
  if [[ -n "$cur" && -f "$REPO/${CHART_PREFIX}${cur}" ]]; then
    tmp="$(mktemp)"
    if patch_file_write "$4" "$tmp" && cmp -s "$tmp" "$REPO/${CHART_PREFIX}${cur}"; then
      rm -f "$tmp"; printf '%s' "$cur"; return 0
    fi
    rm -f "$tmp"
  fi
  patch_store "$REPO" "$4" "$3"
}
exposure_warnings() {  # exposure_warnings CLUSTER INSTANCE: a public load balancer without allowedSourceRanges
  local e
  for e in exposure readOnlyExposure; do
    [[ "$(C="$1" I="$2" K="$e" yq -r '.clusters[strenv(C)].instances[strenv(I)].instance[strenv(K)] // ""' "$F")" == "loadBalancer" ]] || continue
    if [[ "$(C="$1" I="$2" yq -r '.clusters[strenv(C)].instances[strenv(I)].instance.allowedSourceRanges // [] | length' "$F")" -eq 0 ]]; then
      record_entry "warning.$1.$2.${e}" WARNING EXPOSURE_UNRESTRICTED \
        "${2}: ${e}=loadBalancer publishes port 5432 on a public IP without allowedSourceRanges; anyone on the internet can try to connect"
    fi
  done
}
create_render_check() {  # create_render_check CLUSTER INSTANCE -> 0, or 1 with CHECK_REASON/CHECK_DETAIL
  local out pg
  if ! out="$(instance_render "$REPO" "$1" "$2" 2>&1)"; then
    CHECK_REASON=RENDER_FAILED; CHECK_DETAIL="$(tail -n 3 <<<"$out" | tr '\n' ' ')"; return 1
  fi
  printf '%s\n' "$out" > "$WORK/render-$1-$2.yaml"
  # Server-side dry run of the Postgres object through the operator's admission
  # webhooks (the pg-<instance> namespace does not exist yet: the object is sent
  # to the default namespace under a probe name, without its backup location)
  pg="$(yq 'select(.kind == "Postgres") | del(.spec.backupLocation) | .metadata.namespace = "default"
        | .metadata.name = "tpg-create-probe" | del(.metadata.annotations)' "$WORK/render-$1-$2.yaml")"
  if ! out="$(printf '%s\n' "$pg" | tk apply --dry-run=server -f - 2>&1)"; then
    CHECK_REASON=DRY_RUN_REJECTED; CHECK_DETAIL="$(tr '\n' ' ' <<<"$out" | cut -c1-400)"; return 1
  fi
}

for c in $(jq -r 'keys[]' "$WORK/effective.json"); do
  CUR_C="$c"; CUR_I=""
  entry="$(jq -c --arg c "$c" '.[$c]' "$WORK/effective.json")"
  opv="$(jq -r '.operatorVersion // ""' <<<"$entry")"
  if [[ "$MODE" == "day0" ]]; then
    [[ -n "$opv" ]] || { FAILED+=("${c}: operatorVersion is required"); continue; }
  fi
  max="$(jq -r '.maxReadReplicas // ""' <<<"$entry")"
  [[ -n "$max" ]] || max="$(fleet_cluster_value "$REPO" "$c" '.cluster.maxReadReplicas' 3)"

  # ---- versions against the live cluster
  cur_opv="$(C="$c" yq -r '.clusters[strenv(C)].operator.version // ""' "$F")"
  if use_cluster "$c" >/dev/null 2>&1 && tk get --raw=/readyz >/dev/null 2>&1; then
    live="$(live_operator)"
  else
    live=unreachable
  fi
  if [[ "$MODE" == "create" ]]; then
    # tpg-create-instance adds instances next to a running operator only
    case "$live" in
      unreachable) block "$c" UNREACHABLE "API server not reachable from the hub"; continue ;;
      none) block "$c" OPERATOR_NOT_INSTALLED "no Tanzu Postgres operator runs on ${c}: run tpg-day0 for this cluster first"; continue ;;
    esac
    [[ -n "$cur_opv" ]] || { block "$c" NOT_IN_FLEET "clusters.${c}.operator.version is not declared in clusters/fleet.yaml (run tpg-day0 for this cluster)"; continue; }
  else
    case "$live" in
      unreachable) block "$c" UNREACHABLE "API server not reachable from the hub"; continue ;;
      none)
        [[ -z "$cur_opv" || "$cur_opv" == "$opv" ]] \
          || NOTES+=("FLEET_OVERRIDDEN ${c} operator ${cur_opv} -> ${opv} (not installed on the cluster)") ;;
      unknown)
        if [[ "$cur_opv" != "$opv" ]]; then
          block "$c" VERSION_UNKNOWN "an operator runs on ${c} but its version cannot be read from its image; fleet.yaml declares ${cur_opv:-none}, the input is ${opv}"
          continue
        fi ;;
      "$opv")
        [[ -z "$cur_opv" || "$cur_opv" == "$opv" ]] \
          || NOTES+=("FLEET_OVERRIDDEN ${c} operator ${cur_opv} -> ${opv} (the cluster runs ${opv})") ;;
      *)
        if newer "${opv#v}" "${live#v}"; then
          block "$c" UPGRADE_REQUIRED "operator ${live} runs on ${c}: use tpg-upgrade component=operator targetVersion=${opv}"
        else
          block "$c" DOWNGRADE_NOT_ALLOWED "operator ${live} runs on ${c}, which is newer than ${opv}"
        fi
        continue ;;
    esac
  fi
  stop=""
  for i in $(jq -r '.instances | keys[]' <<<"$entry"); do
    pgv="$(jq -r --arg i "$i" '.instances[$i].postgresVersion // ""' <<<"$entry")"
    [[ -n "$pgv" ]] || { FAILED+=("${c}/${i}: postgresVersion is required"); continue; }
    cur_pgv="$(C="$c" I="$i" yq -r '.clusters[strenv(C)].instances[strenv(I)].instance.postgresVersion // ""' "$F")"
    lpg="none"; [[ "$live" == "none" ]] || lpg="$(live_postgres "$i")"
    if [[ "$MODE" == "create" ]]; then
      # An instance that already runs is compared with the request after the
      # write (ALREADY_EXISTS or INSTANCE_EXISTS below); a version difference
      # is an INSTANCE_EXISTS for that instance, not a cluster block.
      [[ "$lpg" == "none" || "$lpg" == "$pgv" ]] \
        || { jq -cn --arg i "$i" --arg r "INSTANCE_EXISTS" --arg d "${i} runs ${lpg} on ${c}; tpg-create-instance does not change a running instance (tpg-upgrade changes the version)" \
               '{instance:$i, reason:$r, detail:$d}' >> "$WORK/instance-blocks.$c"; }
      continue
    fi
    case "$lpg" in
      none)
        [[ -z "$cur_pgv" || "$cur_pgv" == "$pgv" ]] \
          || NOTES+=("FLEET_OVERRIDDEN ${c}/${i} ${cur_pgv} -> ${pgv} (not running on the cluster)") ;;
      "$pgv")
        [[ -z "$cur_pgv" || "$cur_pgv" == "$pgv" ]] \
          || NOTES+=("FLEET_OVERRIDDEN ${c}/${i} ${cur_pgv} -> ${pgv} (the instance runs ${pgv})") ;;
      unknown) stop="VERSION_UNKNOWN ${i} runs on ${c} without spec.postgresVersion.name" ;;
      *)
        if newer "${pgv#postgres-}" "${lpg#postgres-}"; then
          stop="UPGRADE_REQUIRED ${i} runs ${lpg} on ${c}: use tpg-upgrade component=postgres targetVersion=${pgv} instances=${i}"
        else
          stop="DOWNGRADE_NOT_ALLOWED ${i} runs ${lpg} on ${c}, which is newer than ${pgv}"
        fi ;;
    esac
    [[ -z "$stop" ]] || break
  done
  if [[ -n "$stop" ]]; then block "$c" "${stop%% *}" "${stop#* }"; continue; fi

  # ---- write the values
  while IFS=$'\t' read -r key fmt paths; do
    v="$(entry_value "$entry" "$key")"
    [[ -n "$v" ]] || continue
    for p in $paths; do write_value '.clusters[strenv(C)]' "$p" "$fmt" "$v"; done
  done < <(key_rows cluster)
  for i in $(jq -r '.instances | keys[]' <<<"$entry"); do
    CUR_I="$i"
    ientry="$(jq -c --arg i "$i" '.instances[$i]' <<<"$entry")"
    if [[ -f "$WORK/instance-blocks.$c" ]] && jq -e --arg i "$i" 'select(.instance == $i)' "$WORK/instance-blocks.$c" >/dev/null 2>&1; then
      continue
    fi
    ha="$(jq -r 'if .highAvailability != null then (.highAvailability | tostring) else "" end' <<<"$ientry")"
    [[ -n "$ha" ]] || { FAILED+=("${c}/${i}: highAvailability is required"); continue; }
    # highAvailability and readReplicas depend on each other (Round 13 addendum):
    # HA needs 1 or more (empty means 1); readReplicas above 0 needs HA. The
    # validate step refuses both first; this is the backstop, nothing is coerced
    rr="$(jq -r 'if has("readReplicas") and .readReplicas != null then (.readReplicas | tostring) else "" end' <<<"$ientry")"
    if [[ "$ha" == "true" ]]; then
      [[ -n "$rr" ]] || rr=1
    elif [[ "$rr" =~ ^0*[1-9][0-9]*$ ]]; then
      FAILED+=("${c}/${i}: readReplicas ${rr} needs highAvailability=true (a single node, highAvailability=false, has no read replicas)"); continue
    else
      rr=0
    fi
    ientry="$(jq -c --arg r "$rr" '.readReplicas = $r' <<<"$ientry")"
    if (( rr > max )); then FAILED+=("${c}/${i}: readReplicas ${rr} exceeds maxReadReplicas ${max}"); continue; fi
    # an HA instance has 1 read replica or more; 0 is a single node (D69)
    if [[ "$ha" == "true" ]] && (( rr < 1 )); then
      FAILED+=("${c}/${i}: highAvailability=true needs readReplicas 1 or more (readReplicas 0 is a single node: highAvailability=false)"); continue
    fi
    # read-only FerretDB proxies connect to the standby (D71)
    fer="$(jq -r 'if .ferret != null then (.ferret | tostring) else "" end' <<<"$ientry")"   # true | false | "" (keep what the entry has)
    fro="$(jq -r '.ferretReadOnlyReplicas // "0"' <<<"$ientry")"
    if [[ "$fer" == "true" && "$ha" != "true" ]] && (( fro > 0 )); then
      FAILED+=("${c}/${i}: ferretReadOnlyReplicas ${fro} needs highAvailability=true (the read-only FerretDB proxies connect to the standby)"); continue
    fi
    # ferret empty keeps the FerretDB the entry (or a values patch) already has:
    # its read-only proxies need highAvailability as well
    if [[ -z "$fer" && "$ha" != "true" ]] \
       && [[ "$(instance_effective "$REPO" "$c" "$i" '.ferret.enabled' false 2>/dev/null)" == "true" ]]; then
      efro="$(instance_effective "$REPO" "$c" "$i" '.ferret.readOnlyReplicas' 0 2>/dev/null)"
      if [[ "$efro" =~ ^[0-9]+$ ]] && (( efro > 0 )); then
        FAILED+=("${c}/${i}: FerretDB of ${i} runs ${efro} read-only proxies, which need highAvailability=true (set ferret.readOnlyReplicas to 0 with a tpg-patch values file, or keep highAvailability=true)"); continue
      fi
    fi
    # enableSSL true needs the CA bundle of the storage account (design decision D63)
    ssl="$(jq -r '.enableSSL // ""' <<<"$ientry")"
    if [[ "$ssl" == "true" && -z "$CA_BUNDLE" ]]; then
      FAILED+=("${c}/${i}: CA_BUNDLE_MISSING enableSSL=true needs the Azure Storage CA bundle in ConfigMap argo/tpg-settings (backupCaBundle), written by tpg-aks-infra run.sh")
      continue
    fi
    [[ "$MODE" != "create" ]] || cp "$F" "$WORK/fleet.pre-$c-$i.yaml"
    while IFS=$'\t' read -r key fmt paths; do
      v="$(entry_value "$ientry" "$key")"
      [[ -n "$v" ]] || continue
      for p in $paths; do write_value '.clusters[strenv(C)].instances[strenv(I)]' "$p" "$fmt" "$v"; done
    done < <(key_rows instance)
    if [[ "$MODE" == "create" ]]; then
      perr=""
      for kind in postgres values; do
        pf="$(jq -r --arg k "${kind}PatchFilePath" '.[$k] // ""' <<<"$ientry")"
        [[ -n "$pf" ]] || continue
        if ! stored="$(create_patch_store "$c" "$i" "$kind" "$pf")"; then
          perr="${perr}${pf}: the file was not received (patchFiles)"$'\n'; continue
        fi
        perr="${perr}$(create_patch_errors "$kind" "${CHART_PREFIX}${stored}" "$pf")"$'\n'
        patch_set_current "$REPO" "$c" "$i" "$kind" "$stored"
      done
      if [[ -n "$(tr -d '[:space:]' <<<"$perr")" ]]; then
        cp "$WORK/fleet.pre-$c-$i.yaml" "$F"
        jq -cn --arg i "$i" --arg d "$(grep -v '^$' <<<"$perr" | paste -sd';')" '{instance:$i, reason:"PATCH_REFUSED", detail:$d}' >> "$WORK/instance-blocks.$c"
        continue
      fi
    fi
    if [[ "$ssl" == "true" ]]; then
      V="$CA_BUNDLE" C="$c" I="$i" yq -i '.clusters[strenv(C)].instances[strenv(I)].backup.caBundle = strenv(V) | .clusters[strenv(C)].instances[strenv(I)].backup.caBundle style="literal"' "$F"
    elif [[ "$ssl" == "false" ]]; then
      C="$c" I="$i" yq -i 'del(.clusters[strenv(C)].instances[strenv(I)].backup.caBundle)' "$F"
    fi
    # Network policy: backup egress by FQDN when the clusters run ACNS (tpg-settings acnsEnabled)
    if [[ "$(C="$c" I="$i" yq -r '.clusters[strenv(C)].instances[strenv(I)].network.policy // "none"' "$F")" == "baseline" ]]; then
      A="$( [[ "$ACNS" == "true" ]] && echo true || echo false)" C="$c" I="$i" \
        yq -i '.clusters[strenv(C)].instances[strenv(I)].network.acns = (strenv(A) == "true")' "$F"
    fi
    # backupSchedule (D70): fleet includes the instance in the backup
    # CronWorkflows; none excludes it; operator excludes it and declares
    # PostgresBackupSchedule objects (backup.operatorSchedules) instead, so the
    # instance is never backed up by both
    bmode="$(jq -r '.backupSchedule // "fleet"' <<<"$ientry")"
    C="$c" I="$i" yq -i 'del(.clusters[strenv(C)].instances[strenv(I)].backup.operatorSchedules)' "$F"
    if [[ "$bmode" == "none" || "$bmode" == "operator" ]]; then
      C="$c" I="$i" yq -i '.clusters[strenv(C)].instances[strenv(I)].backup.scheduled = false' "$F"
    else
      C="$c" I="$i" yq -i 'del(.clusters[strenv(C)].instances[strenv(I)].backup.scheduled)' "$F"
    fi
    if [[ "$bmode" == "operator" ]]; then
      FULL="$(jq -r '.operatorFullSchedule // ""' <<<"$ientry")" INCR="$(jq -r '.operatorIncrementalSchedule // ""' <<<"$ientry")" \
      C="$c" I="$i" yq -i '.clusters[strenv(C)].instances[strenv(I)].backup.operatorSchedules.full = strenv(FULL)
        | with(select(strenv(INCR) != ""); .clusters[strenv(C)].instances[strenv(I)].backup.operatorSchedules.incremental = strenv(INCR))' "$F"
    fi
    C="$c" I="$i" yq -i 'del(.clusters[strenv(C)].instances[strenv(I)].backup | select(length == 0))' "$F"
    # FerretDB (D71): true writes the ferret block, false removes it, empty
    # (the input left unset, no map key) leaves the entry as it is
    if [[ "$fer" == "true" ]]; then
      # shellcheck disable=SC2016  # yq variables, not shell
      E="$ientry" C="$c" I="$i" yq -i '(strenv(E) | from_json) as $e
        | .clusters[strenv(C)].instances[strenv(I)].ferret = {"enabled": true, "replicas": ($e.ferretReplicas // "1" | tonumber),
            "readOnlyReplicas": ($e.ferretReadOnlyReplicas // "0" | tonumber)}
        | with(select(($e.ferretExposure // "") != ""); .clusters[strenv(C)].instances[strenv(I)].ferret.exposure = $e.ferretExposure)
        | with(select(($e.ferretSecretName // "") != ""); .clusters[strenv(C)].instances[strenv(I)].ferret.secretName = $e.ferretSecretName)
        | with(select(($e.ferretReadOnlySecretName // "") != ""); .clusters[strenv(C)].instances[strenv(I)].ferret.readOnlySecretName = $e.ferretReadOnlySecretName)' "$F"
      # and lifts the valuesOverride tpg-restore wrote for a restored copy
      C="$c" I="$i" yq -i 'del(.clusters[strenv(C)].instances[strenv(I)].valuesOverride.ferret)
        | del(.clusters[strenv(C)].instances[strenv(I)].valuesOverride | select(length == 0))' "$F"
    elif [[ "$fer" == "false" ]]; then
      C="$c" I="$i" yq -i 'del(.clusters[strenv(C)].instances[strenv(I)].ferret)' "$F"
    fi
    kept=true   # false when create mode puts the entry back as it was
    if [[ "$MODE" == "create" ]]; then
      # Idempotent create: a declared instance that already runs is left alone
      # when the request matches its entry, and refused when it differs.
      declared=false; fleet_has_instance_file "$WORK/fleet.pre-$c-$i.yaml" "$c" "$i" && declared=true
      running=false; [[ "$(live_postgres "$i")" != "none" ]] && running=true
      same=false
      C="$c" I="$i" yq -e '.clusters[strenv(C)].instances[strenv(I)]' "$WORK/fleet.pre-$c-$i.yaml" > "$WORK/a.yaml" 2>/dev/null || true
      C="$c" I="$i" yq -e '.clusters[strenv(C)].instances[strenv(I)]' "$F" > "$WORK/b.yaml" 2>/dev/null || true
      cmp -s "$WORK/a.yaml" "$WORK/b.yaml" && same=true
      if [[ "$running" == "true" && "$declared" == "true" && "$same" == "true" ]]; then
        jq -cn --arg i "$i" '{instance:$i, status:"SUCCEEDED", reason:"ALREADY_EXISTS", detail:"declared in clusters/fleet.yaml and running with the requested values"}' >> "$WORK/instance-results.$c"
      elif [[ "$running" == "true" ]]; then
        cp "$WORK/fleet.pre-$c-$i.yaml" "$F"; kept=false
        jq -cn --arg i "$i" --arg d "$( [[ "$declared" == "true" ]] && echo "${i} runs on ${c} with values that differ from the request: use tpg-patch, tpg-scale-instance or tpg-upgrade" || echo "a Postgres ${i} runs on ${c} but is not declared in clusters/fleet.yaml")" \
          --arg r "$( [[ "$declared" == "true" ]] && echo INSTANCE_EXISTS || echo INSTANCE_NAME_IN_USE)" \
          '{instance:$i, reason:$r, detail:$d}' >> "$WORK/instance-blocks.$c"
      else
        [[ "$declared" != "true" ]] \
          || NOTES+=("DECLARED_NOT_DEPLOYED ${c}/${i}: declared in clusters/fleet.yaml but absent on the cluster; deployed from the entry")
        if ! create_render_check "$c" "$i"; then
          cp "$WORK/fleet.pre-$c-$i.yaml" "$F"; kept=false
          jq -cn --arg i "$i" --arg r "$CHECK_REASON" --arg d "$CHECK_DETAIL" '{instance:$i, reason:$r, detail:$d}' >> "$WORK/instance-blocks.$c"
        fi
      fi
    fi
    # warnings for what is written only (not for an entry put back above)
    [[ "$kept" == "true" ]] && exposure_warnings "$c" "$i"
    if [[ "$kept" == "true" && "$fer" == "true" ]]; then
      record_entry "warning.${c}.${i}.ferret" WARNING FERRET_EXTENSION_REQUIRED \
        "${i}: FerretDB (Tech Preview) needs the documentdb extension in the instance (shared_preload_libraries, the documentdb database); prepare it by hand (Runbook, FerretDB) or the FerretDB proxies do not start"
    fi
  done
done

printf '{}' > /tmp/fleet.json
if [[ "${#FAILED[@]}" -gt 0 ]]; then
  record result.git FAILED INVALID_INPUT "$(printf '%s; ' "${FAILED[@]}")"
  exit 1
fi
# Per-instance outcomes of tpg-create-instance, read by fleet-commit.sh and the report
for c in $(jq -r 'keys[]' "$WORK/effective.json"); do
  if [[ -f "$WORK/instance-blocks.$c" ]]; then
    while read -r b; do
      record_entry "result.${c}.$(jq -r '.instance' <<<"$b")" BLOCKED "$(jq -r '.reason' <<<"$b")" "$(jq -r '.detail' <<<"$b")"
    done < "$WORK/instance-blocks.$c"
  fi
  if [[ -f "$WORK/instance-results.$c" ]]; then
    while read -r b; do
      record_entry "result.${c}.$(jq -r '.instance' <<<"$b")" "$(jq -r '.status' <<<"$b")" "$(jq -r '.reason' <<<"$b")" "$(jq -r '.detail' <<<"$b")"
    done < "$WORK/instance-results.$c"
  fi
done
for n in "${NOTES[@]}"; do log "$n"; done
for b in "${BLOCKED[@]}"; do log "BLOCKED ${b} (fleet.yaml not changed for this cluster)"; done
note="$( [[ "${#NOTES[@]}" -eq 0 ]] || printf '%s; ' "${NOTES[@]}")$( [[ "${#BLOCKED[@]}" -eq 0 ]] || printf 'blocked: %s; ' "${BLOCKED[@]%%:*}")"
fleet_yaml_style "$F"   # the diff shows the file as fleet-commit.sh writes it: block YAML
changes="$(diff -u "$WORK/fleet.before.yaml" "$F" | tail -n +3 || true)"
if [[ -n "$changes" ]]; then
  log "planned clusters/fleet.yaml changes (written after the pre-check, for the clusters that pass it):"
  printf '%s\n' "$changes" >&2
fi
# The plan: discover and the pre-check read it; fleet-commit.sh writes it
plan_json "$F" "$CA_BUNDLE" > /tmp/fleet.json
summary="$(jq -r 'to_entries | map(.key + "(" + ((.value.instances // {}) | keys | join(",")) + ")") | join(" ")' "$WORK/effective.json")"
record_entry plan.git PLANNED "" "${summary}${note:+; ${note}}"
exit 0
