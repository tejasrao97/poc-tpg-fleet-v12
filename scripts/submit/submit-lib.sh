#!/usr/bin/env bash
# submit-lib.sh: the interactive submit helper behind scripts/submit/tpg-*.sh
# (design decision D67). Sourced, not run.
#
# Each tpg-<workflow>.sh sets WF_TEMPLATE, the mandatory inputs and optional
# hooks, then calls sl_main. The inputs themselves (names, defaults, enums,
# descriptions) are read from workflows/templates/<template>.yaml and their types
# from workflows/params/types.yaml, so a script never lists them twice and stays
# in step with the WorkflowTemplate.
#
# Flow: mandatory inputs first (the targets: clusterMap or the clusters and
# instances lists), then a menu of the optional inputs (arrow keys, Enter to
# pick, "Done" to finish), each prompt showing the type and an example; after
# every optional input the script asks whether to pick another. Then a summary,
# the equivalent argo command, a local check (types, clusterMap with
# clustermap.py) and the submit: argo submit when the argo CLI is installed,
# otherwise kubectl create of a Workflow object. Optionally it watches the run
# and prints the run report.
#
# Requirements: bash 3.2 or later (macOS works), yq v4 (mikefarah), jq,
# python3, kubectl with a context for the hub (HUB_CONTEXT, default the current
# context). Plain numbered menus instead of arrow keys: TPG_PLAIN=1, or when the
# terminal is not interactive.
#
# Environment:
#   HUB_CONTEXT    kubectl context of the hub (default: current context)
#   ARGO_NS        namespace of the WorkflowTemplates (default: argo)
#   TPG_PLAIN=1    numbered menus
#   TPG_NO_WATCH=1 do not offer to watch the run

set -u
SL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARGO_NS="${ARGO_NS:-argo}"
SL_TYPES="${SL_ROOT}/workflows/params/types.yaml"
SL_KEYS="${SL_ROOT}/workflows/params/cluster-map-keys.yaml"
SL_TMP="$(mktemp -d "${TMPDIR:-/tmp}/tpg-submit.XXXXXX")"
trap 'rm -rf "$SL_TMP"; sl_cursor_on' EXIT

# ------------------------------------------------------------------ output
if [[ -t 1 ]]; then
  C_B=$'\033[1m'; C_D=$'\033[2m'; C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_C=$'\033[36m'; C_0=$'\033[0m'
else
  C_B=""; C_D=""; C_R=""; C_G=""; C_Y=""; C_C=""; C_0=""
fi
sl_say()  { printf '%s\n' "$*" >&2; }
sl_head() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0" >&2; }
sl_err()  { printf '%s%s%s\n' "$C_R" "$*" "$C_0" >&2; }
sl_ok()   { printf '%s%s%s\n' "$C_G" "$*" "$C_0" >&2; }
sl_die()  { sl_err "$*"; exit 1; }
sl_cursor_on() { if [[ -t 2 ]]; then printf '\033[?25h' >&2; fi; }

sl_plain() { [[ "${TPG_PLAIN:-0}" == "1" || ! -t 0 || ! -t 2 || "${TERM:-dumb}" == "dumb" ]]; }

# ------------------------------------------------------------------ menus
# sl_menu PROMPT OPTION... -> SL_PICK (0-based index). Arrow keys and Enter;
# numbered input when sl_plain.
sl_menu() {
  local prompt="$1"; shift
  local -a opts=("$@")
  local n="${#opts[@]}" sel=0 i key rest
  if sl_plain; then
    sl_say "$prompt"
    for ((i = 0; i < n; i++)); do sl_say "  $((i + 1))) ${opts[$i]}"; done
    while true; do
      printf '  number [1-%s]: ' "$n" >&2
      IFS= read -r key || sl_die "input ended"
      if [[ "$key" =~ ^[0-9]+$ ]] && (( key >= 1 && key <= n )); then SL_PICK=$((key - 1)); return 0; fi
      sl_err "  enter a number from 1 to ${n}"
    done
  fi
  sl_say "$prompt ${C_D}(arrow keys, Enter)${C_0}"
  printf '\033[?25l' >&2
  while true; do
    for ((i = 0; i < n; i++)); do
      if [[ "$i" -eq "$sel" ]]; then printf '  %s> %s%s\033[K\n' "$C_C$C_B" "${opts[$i]}" "$C_0" >&2
      else printf '    %s\033[K\n' "${opts[$i]}" >&2; fi
    done
    IFS= read -rsn1 key
    if [[ "$key" == $'\033' ]]; then
      IFS= read -rsn2 rest
      case "$rest" in
        "[A") sel=$(( (sel + n - 1) % n )) ;;
        "[B") sel=$(( (sel + 1) % n )) ;;
      esac
    elif [[ "$key" == "k" ]]; then sel=$(( (sel + n - 1) % n ))
    elif [[ "$key" == "j" ]]; then sel=$(( (sel + 1) % n ))
    elif [[ -z "$key" ]]; then
      break
    fi
    printf '\033[%sA' "$n" >&2
  done
  printf '\033[?25h' >&2
  SL_PICK="$sel"
}

# sl_yes PROMPT [default y|n] -> 0 for yes
sl_yes() {
  local a d="${2:-n}"
  while true; do
    printf '%s [%s] ' "$1" "$( [[ "$d" == y ]] && echo "Y/n" || echo "y/N")" >&2
    IFS= read -r a || return 1
    a="$(printf '%s' "${a:-$d}" | tr '[:upper:]' '[:lower:]')"
    case "$a" in y|yes) return 0 ;; n|no) return 1 ;; esac
  done
}

sl_read() {  # sl_read PROMPT -> SL_LINE
  printf '%s' "$1" >&2
  IFS= read -r SL_LINE || SL_LINE=""
}

# ------------------------------------------------------------------ inputs
# Parallel arrays (bash 3.2 has no associative arrays)
P_NAME=(); P_DEF=(); P_DESC=(); P_ENUM=(); P_TYPE=(); P_VAL=(); P_SET=()

sl_idx() {  # sl_idx NAME -> index on stdout, 1 when unknown
  local i
  for ((i = 0; i < ${#P_NAME[@]}; i++)); do [[ "${P_NAME[$i]}" == "$1" ]] && { echo "$i"; return 0; }; done
  return 1
}
sl_has() { sl_idx "$1" >/dev/null; }
sl_val() { local i; i="$(sl_idx "$1")" || return 0; [[ "${P_SET[$i]}" == 1 ]] && printf '%s' "${P_VAL[$i]}"; }
sl_isset() { local i; i="$(sl_idx "$1")" || return 1; [[ "${P_SET[$i]}" == 1 ]]; }
sl_setv() { local i; i="$(sl_idx "$1")" || return 1; P_VAL[i]="$2"; P_SET[i]=1; }
sl_unset() { local i; i="$(sl_idx "$1")" || return 1; P_VAL[i]=""; P_SET[i]=0; }

sl_load() {  # sl_load TEMPLATE
  local f="${SL_ROOT}/workflows/templates/$1.yaml" name def desc enum typ
  [[ -f "$f" ]] || sl_die "WorkflowTemplate file $f not found"
  # fields separated by US (0x1f): a tab would collapse empty fields in read
  while IFS=$'\037' read -r name def enum desc; do
    [[ -n "$name" ]] || continue
    typ="$(T="$1" N="$name" yq -r '.templates[strenv(T)][strenv(N)].type // "string"' "$SL_TYPES")"
    P_NAME+=("$name"); P_DEF+=("$def"); P_DESC+=("$desc"); P_ENUM+=("$enum"); P_TYPE+=("$typ"); P_VAL+=(""); P_SET+=(0)
  done < <(yq -o=json -I=0 '.spec.arguments.parameters' "$f" | jq -r '.[]
    | [.name, (.value // "" | tostring), ((.enum // []) | map(select(. != "")) | join(",")), (.description // "")]
    | join("\u001f")')
}

sl_type_text() {  # sl_type_text NAME -> "boolean", "number", "map (YAML or JSON)", ...
  local i t disp desc
  i="$(sl_idx "$1")" || return 0
  t="${P_TYPE[$i]}"
  disp="$(T="$t" yq -r '.types[strenv(T)].display // "String"' "$SL_TYPES")"
  desc="$(T="$t" yq -r '.types[strenv(T)].describe // ""' "$SL_TYPES")"
  case "$t" in
    boolean) printf 'boolean (true or false)' ;;
    integer|posint) printf 'number (%s)' "$desc" ;;
    enum) printf 'enum (one of %s)' "${P_ENUM[$i]//,/, }" ;;
    map) printf 'map (YAML or JSON object)' ;;
    cron) printf 'cron schedule (5 fields: minute hour day month weekday, UTC)' ;;
    jsonMap) printf 'JSON map (a JSON object)' ;;
    patchFile) printf 'file path (%s on this machine; its contents are sent in patchFiles)' "$desc" ;;
    list|listOrAll|components|cidrList|fqdnList) printf 'list (%s)' "$desc" ;;
    *) printf 'string: %s (%s)' "$disp" "$desc" ;;
  esac
}

sl_example() {  # sl_example NAME -> an example value
  case "$1" in
    clusters) echo "aks-tpg-poc-01,aks-tpg-poc-02" ;;
    instances) echo "orders-db,billing-db" ;;
    clusterMap)
      case "$WF_TEMPLATE" in
        tpg-scale-instance) echo "{aks-tpg-poc-01: {maxReadReplicas: 4, instances: {orders-db: {replicas: 3}, billing-db: {replicas: 0}}}, aks-tpg-poc-02: {maxReadReplicas: 2}}" ;;
        *) echo "{aks-tpg-poc-01: {instances: {orders-db: {postgresVersion: postgres-17.6, highAvailability: true}}}}" ;;
      esac ;;
    highAvailability) echo "true" ;;
    operatorVersion) echo "v4.5.0" ;;
    postgresVersion) echo "postgres-17.6" ;;
    targetVersion) echo "v4.5.1 (component=operator) or postgres-17.9 (component=postgres)" ;;
    pushMode) echo "direct" ;;
    readReplicas) echo "2 (only with highAvailability=true; empty means 1)" ;;
    replicas) echo "1 (0 makes a single node)" ;;
    maxReadReplicas) echo "4 (the new cap; not below any instance's read replicas)" ;;
    operatorFullSchedule) echo "0 0 * * 0" ;;
    operatorIncrementalSchedule) echo "0 0 * * 1-6" ;;
    ferretReplicas) echo "2" ;;
    ferretReadOnlyReplicas) echo "1 (needs highAvailability=true)" ;;
    ferretExposure) echo "internalLoadBalancer" ;;
    ferretSecretName) echo "orders-db-app-user-db-secret" ;;
    ferretReadOnlySecretName) echo "orders-db-read-only-user-db-secret" ;;
    storageSize) echo "50Gi" ;;
    walStorageSize) echo "20Gi" ;;
    storageClass) echo "tpg-data-retain" ;;
    cpu) echo "2" ;;
    memory) echo "4Gi" ;;
    exposure|readOnlyExposure) echo "internalLoadBalancer" ;;
    serviceAnnotations|readOnlyServiceAnnotations) echo "{service.beta.kubernetes.io/azure-dns-label-name: orders}" ;;
    allowedSourceRanges|ingressFromCidrs) echo "10.20.0.0/16,192.168.10.0/24" ;;
    internalLoadBalancerSubnet) echo "apps-subnet" ;;
    ingressFromNamespaces) echo "orders-app,reporting" ;;
    ingressFromPodLabels) echo "{app: orders-api}" ;;
    egressToCidrs) echo "10.30.0.0/24" ;;
    egressToFqdns) echo "api.example.com,*.example.org" ;;
    postgresPatchFilePath) echo "./orders-memory.yaml (a file on this machine; patchMode=clear: the current stored file)" ;;
    valuesPatchFilePath) echo "./orders-backup.yaml (a file on this machine; patchMode=clear: the current stored file)" ;;
    operatorValuesPatchFilePath) echo "./operator-resources.yaml (a file on this machine; patchMode=clear: the current stored file)" ;;
    apps) echo '{"aks-tpg-poc-01": ["tpg-instances:orders-db", "tpg-operator"]}' ;;
    confirm) echo "aks-tpg-poc-01 (the same names as the targets)" ;;
    targetTime) echo "2026-09-15T08:30:00Z" ;;
    lsn) echo "0/3000060" ;;
    xid) echo "12345" ;;
    backupName) echo "orders-db-full-20260915" ;;
    sourceCluster|targetCluster) echo "aks-tpg-poc-01" ;;
    instance|targetInstance) echo "orders-db" ;;
    retentionDays) echo "35" ;;
    maxParallel) echo "2" ;;
    *Seconds) echo "1800" ;;
    components) echo "cert-manager,vso" ;;
    toolsImage) echo "alpine/k8s:1.35.8" ;;
    *) local i; i="$(sl_idx "$1")" || return 0
       if [[ -n "${P_ENUM[$i]}" ]]; then echo "${P_ENUM[$i]%%,*}"; else echo "${P_DEF[$i]:-}"; fi ;;
  esac
}

sl_check() {  # sl_check NAME VALUE -> 0 when VALUE matches the input type (types.yaml pattern)
  local i t pat
  i="$(sl_idx "$1")" || return 0
  t="${P_TYPE[$i]}"
  [[ -n "$2" ]] || return 0
  if [[ -n "${P_ENUM[$i]}" ]]; then
    [[ ",${P_ENUM[$i]}," == *",$2,"* ]] && return 0
    SL_WHY="must be one of ${P_ENUM[$i]//,/, }"; return 1
  fi
  pat="$(T="$t" yq -r '.types[strenv(T)].pattern // ""' "$SL_TYPES")"
  [[ -n "$pat" ]] || return 0
  if python3 -c 'import re, sys; sys.exit(0 if re.match(sys.argv[1], sys.argv[2], re.S) else 1)' "$pat" "$2"; then
    if [[ "$t" == "list" ]] && [[ ",$(tr -d ' ' <<<"$2")," == *",all,"* ]]; then SL_WHY="all is not accepted here: list the names"; return 1; fi
    return 0
  fi
  SL_WHY="is not $(T="$t" yq -r '.types[strenv(T)].describe // "valid"' "$SL_TYPES")"
  return 1
}

sl_rules_check() {  # the combination rules of types.yaml for this template -> 0 when none fires
  # (the same rules the admission policy applies: highAvailability=true with
  # readReplicas=0, readReplicas above 0 with highAvailability=false, read-only
  # FerretDB proxies without highAvailability)
  local rules n k ok name rx v fired=0
  rules="$(W="$WF_TEMPLATE" yq -o=json -I=0 '.rules[strenv(W)] // []' "$SL_TYPES")"
  n="$(jq 'length' <<<"$rules")"
  k=0
  while [[ "$k" -lt "$n" ]]; do
    ok=1
    while IFS=$'\t' read -r name rx; do
      sl_isset "$name" || { ok=0; break; }
      v="$(sl_val "$name")"
      python3 -c 'import re, sys; sys.exit(0 if re.fullmatch(sys.argv[1], sys.argv[2]) else 1)' "$rx" "$v" || { ok=0; break; }
    done < <(jq -r --argjson k "$k" '.[$k].when | to_entries[] | [.key, (.value | tostring)] | @tsv' <<<"$rules")
    if [[ "$ok" -eq 1 ]]; then sl_err "  $(jq -r --argjson k "$k" '.[$k].message' <<<"$rules")"; fired=1; fi
    k=$((k + 1))
  done
  return "$fired"
}

sl_read_map() {  # sl_read_map NAME -> SL_LINE: a map from a file, pasted YAML, or one line
  local lines=()
  sl_menu "How do you want to give ${1}?" "Type or paste it on one line (YAML flow or JSON)" \
    "Paste several lines of YAML or JSON (end with a line that says END)" "Read it from a file" "Leave it unset"
  case "$SL_PICK" in
    0) sl_read "  ${1}: " ;;
    1) sl_say "  paste now; finish with a line END"
       while IFS= read -r l; do [[ "$l" == "END" ]] && break; lines+=("$l"); done
       SL_LINE="$(printf '%s\n' ${lines[@]+"${lines[@]}"})" ;;
    2) sl_read "  file path: "
       [[ -f "$SL_LINE" ]] || { sl_err "  ${SL_LINE}: not a file"; SL_LINE=""; return 1; }
       SL_LINE="$(cat "$SL_LINE")" ;;
    3) SL_LINE="" ;;
  esac
  # normalize to compact JSON (the WorkflowTemplate takes YAML or JSON)
  if [[ -n "$(tr -d '[:space:]' <<<"$SL_LINE")" ]]; then
    local j
    if ! j="$(printf '%s\n' "$SL_LINE" | yq -o=json -I=0 '.' 2>/dev/null)" || [[ "${j:0:1}" != "{" ]]; then
      sl_err "  not a YAML or JSON mapping"; SL_LINE=""; return 1
    fi
    SL_LINE="$j"
  fi
}

# sl_prompt NAME [mandatory] -> sets the input (or leaves it unset when empty and optional)
sl_prompt() {
  local name="$1" must="${2:-}" i def v choices=()
  i="$(sl_idx "$name")" || sl_die "unknown input ${name}"
  def="${P_DEF[$i]}"
  sl_say ""
  sl_say "${C_B}${name}${C_0}$( [[ -n "$must" ]] && printf ' %s(mandatory)%s' "$C_Y" "$C_0")"
  [[ -z "${P_DESC[$i]}" ]] || sl_say "  ${P_DESC[$i]}"
  sl_say "  Type:    $(sl_type_text "$name")"
  sl_say "  Example: $(sl_example "$name")"
  [[ -z "$def" ]] || sl_say "  Default: ${def}"
  [[ "${P_SET[$i]}" != 1 ]] || sl_say "  Current: ${P_VAL[$i]}"
  while true; do
    if [[ "$name" == "clusterMap" ]]; then
      sl_clustermap || continue
      v="$SL_LINE"
    elif [[ -n "${P_ENUM[$i]}" ]]; then
      IFS=',' read -r -a choices <<<"${P_ENUM[$i]}"
      [[ -n "$must" ]] || choices+=("(leave unset${def:+: default ${def}})")
      sl_menu "  choose ${name}:" "${choices[@]}"
      if [[ -z "$must" && "$SL_PICK" -eq $((${#choices[@]} - 1)) ]]; then v=""; else v="${choices[$SL_PICK]}"; fi
    elif [[ "${P_TYPE[$i]}" == "map" || "${P_TYPE[$i]}" == "jsonMap" ]]; then
      sl_read_map "$name" || continue
      v="$SL_LINE"
    else
      sl_read "  ${name}$( [[ -n "$def" ]] && printf ' [Enter: default %s]' "$def"): "
      v="$SL_LINE"
    fi
    v="$(printf '%s' "$v" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [[ -z "$v" ]]; then
      if [[ -n "$must" ]]; then sl_err "  ${name} is mandatory"; continue; fi
      sl_unset "$name"; return 0
    fi
    SL_WHY=""
    if sl_check "$name" "$v"; then sl_setv "$name" "$v"; return 0; fi
    sl_err "  '${v}' ${SL_WHY}"
  done
}

# ------------------------------------------------------------------ clusterMap builder
sl_wf_id() {  # the clusterMap workflow id of a template (cluster-map-keys.yaml)
  case "$1" in tpg-scale-instance) echo scale ;; *) echo "${1#tpg-}" ;; esac
}
sl_registered() {  # registered clusters, one per line (hub Secrets argo/kubeconfig-<cluster>)
  kubectl ${HUB_CONTEXT:+--context "$HUB_CONTEXT"} -n "$ARGO_NS" get secret -l tpg.fleet/cluster \
    -o jsonpath='{range .items[*]}{.metadata.labels.tpg\.fleet/cluster}{"\n"}{end}' 2>/dev/null | sort -u
}
sl_flags_json() {  # the current inputs, for clustermap.py --flags
  local i args=()
  for ((i = 0; i < ${#P_NAME[@]}; i++)); do
    [[ "${P_SET[$i]}" == 1 ]] && args+=(--arg "${P_NAME[$i]}" "${P_VAL[$i]}")
  done
  jq -cn ${args[@]+"${args[@]}"} '$ARGS.named'
}
sl_map_validate() {  # sl_map_validate JSON -> 0 when clustermap.py accepts it for this workflow
  local out
  printf '%s' "$1" > "$SL_TMP/map.json"
  yq -o=json -I=0 '.' "$SL_KEYS" > "$SL_TMP/keys.json"
  sl_registered > "$SL_TMP/registered"
  sl_flags_json > "$SL_TMP/flags.json"
  local reg=(); [[ -s "$SL_TMP/registered" ]] && reg=(--registered "$SL_TMP/registered")
  if out="$(python3 "${SL_ROOT}/workflows/scripts/clustermap.py" validate --workflow "$(sl_wf_id "$WF_TEMPLATE")" \
      --map "$SL_TMP/map.json" --keys "$SL_TMP/keys.json" ${reg[@]+"${reg[@]}"} --flags "$SL_TMP/flags.json")"; then
    return 0
  fi
  sl_err "clusterMap is not valid for ${WF_TEMPLATE}:"
  printf '%s\n' "$out" | sed 's/^/  - /' >&2
  return 1
}
sl_key_prompt() {  # sl_key_prompt LEVEL KEY -> SL_LINE (the value; lists and maps as JSON)
  local lvl="$1" k="$2" t vals req
  t="$(L="$lvl" K="$k" yq -r '.[strenv(L)][strenv(K)].type' "$SL_KEYS")"
  SL_JSON=0; case "$t" in stringMap|nameList|cidrList|fqdnList) SL_JSON=1 ;; esac
  vals="$(L="$lvl" K="$k" yq -r '.[strenv(L)][strenv(K)].values // [] | join(",")' "$SL_KEYS")"
  req="$(L="$lvl" K="$k" W="$(sl_wf_id "$WF_TEMPLATE")" yq -r '.[strenv(L)][strenv(K)].workflows[strenv(W)] // ""' "$SL_KEYS")"
  sl_say "  ${C_B}${k}${C_0} (${req}; type ${t}$( [[ -n "$vals" ]] && printf ': %s' "${vals//,/, }"))  example: $(sl_example "$k")"
  case "$t" in
    enum|boolean)
      local choices=()
      if [[ "$t" == boolean ]]; then choices=(true false); else IFS=',' read -r -a choices <<<"$vals"; fi
      sl_menu "  ${k}:" "${choices[@]}"; SL_LINE="${choices[$SL_PICK]}" ;;
    stringMap) sl_read_map "$k" ;;
    nameList|cidrList|fqdnList)
      sl_read "  ${k} (comma-separated): "
      SL_LINE="$(jq -cn --arg v "$SL_LINE" '$v | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')" ;;
    *) sl_read "  ${k}: " ;;
  esac
}
sl_keys_for() {  # sl_keys_for LEVEL -> the keys this workflow accepts, required first
  local w; w="$(sl_wf_id "$WF_TEMPLATE")"
  W="$w" L="$1" yq -r '.[strenv(L)] | to_entries | map(select(.value.workflows[strenv(W)] != null))
    | sort_by(.value.workflows[strenv(W)] != "required") | .[] | .key + " (" + .value.workflows[strenv(W)] + ")"' "$SL_KEYS"
}
sl_build_map() {  # guided builder -> SL_LINE (JSON)
  local map='{}' clusters=() reg c inst keys=() k v i opts
  reg="$(sl_registered)"
  while true; do
    opts=()
    if [[ -n "$reg" ]]; then while IFS= read -r c; do [[ -n "$c" ]] && opts+=("$c"); done <<<"$reg"; fi
    opts+=("(type a cluster name)" "(done with clusters)")
    sl_menu "Add a cluster to clusterMap$( [[ ${#clusters[@]} -gt 0 ]] && printf ' (so far: %s)' "${clusters[*]}"):" "${opts[@]}"
    if [[ "$SL_PICK" -eq $((${#opts[@]} - 1)) ]]; then break; fi
    if [[ "$SL_PICK" -eq $((${#opts[@]} - 2)) ]]; then sl_read "  cluster name: "; c="$SL_LINE"; else c="${opts[$SL_PICK]}"; fi
    [[ -n "$c" ]] || continue
    clusters+=("$c")
    map="$(jq -c --arg c "$c" '.[$c] //= {instances: {}}' <<<"$map")"
    # cluster keys
    keys=(); while IFS= read -r k; do [[ -n "$k" ]] && keys+=("$k"); done < <(sl_keys_for cluster)
    while [[ "${#keys[@]}" -gt 0 ]]; do
      sl_menu "  ${c}: set a cluster key?" "(no more cluster keys)" "${keys[@]}"
      [[ "$SL_PICK" -eq 0 ]] && break
      k="${keys[$((SL_PICK - 1))]%% *}"
      sl_key_prompt cluster "$k"
      [[ -n "$SL_LINE" ]] && map="$(jq -c --arg c "$c" --arg k "$k" --arg v "$SL_LINE" --arg j "$SL_JSON" \
        '.[$c][$k] = (if $j == "1" then ($v | fromjson) else $v end)' <<<"$map")"
    done
    # instances
    local declared=""
    declared="$(C="$c" yq -r '.clusters[strenv(C)].instances // {} | keys | .[]' "${SL_ROOT}/clusters/fleet.yaml" 2>/dev/null || true)"
    while true; do
      opts=()
      if [[ -n "$declared" ]]; then while IFS= read -r i; do [[ -n "$i" ]] && opts+=("$i (declared in your clusters/fleet.yaml)"); done <<<"$declared"; fi
      opts+=("(type an instance name)" "(done with instances of ${c})")
      sl_menu "  ${c}: add an instance:" "${opts[@]}"
      if [[ "$SL_PICK" -eq $((${#opts[@]} - 1)) ]]; then break; fi
      if [[ "$SL_PICK" -eq $((${#opts[@]} - 2)) ]]; then sl_read "  instance name: "; inst="$SL_LINE"; else inst="${opts[$SL_PICK]%% *}"; fi
      [[ -n "$inst" ]] || continue
      map="$(jq -c --arg c "$c" --arg i "$inst" '.[$c].instances[$i] //= {}' <<<"$map")"
      keys=(); while IFS= read -r k; do [[ -n "$k" ]] && keys+=("$k"); done < <(sl_keys_for instance)
      while [[ "${#keys[@]}" -gt 0 ]]; do
        sl_menu "  ${c}/${inst}: set a key? (required keys may also come from the workflow inputs)" "(no more keys for ${inst})" "${keys[@]}"
        [[ "$SL_PICK" -eq 0 ]] && break
        k="${keys[$((SL_PICK - 1))]%% *}"
        sl_key_prompt instance "$k"
        [[ -n "$SL_LINE" ]] && map="$(jq -c --arg c "$c" --arg i "$inst" --arg k "$k" --arg v "$SL_LINE" --arg j "$SL_JSON" \
          '.[$c].instances[$i][$k] = (if $j == "1" then ($v | fromjson) else $v end)' <<<"$map")"
      done
    done
    map="$(jq -c --arg c "$c" 'if (.[$c].instances | length) == 0 then .[$c] |= del(.instances) else . end' <<<"$map")"
  done
  SL_LINE="$map"
}
sl_clustermap() {  # -> SL_LINE, 1 to ask again
  sl_menu "clusterMap:" "Build it step by step (registered clusters, then instances and keys)" \
    "Load it from a YAML or JSON file" "Paste or type it" "Leave it unset (use the clusters and instances lists)"
  case "$SL_PICK" in
    0) sl_build_map ;;
    1) sl_read "  file path: "; [[ -f "$SL_LINE" ]] || { sl_err "  not a file"; return 1; }
       SL_LINE="$(yq -o=json -I=0 '.' "$SL_LINE" 2>/dev/null)" || { sl_err "  not YAML or JSON"; return 1; } ;;
    2) sl_read_map clusterMap || return 1 ;;
    3) SL_LINE=""; return 0 ;;
  esac
  [[ -n "$SL_LINE" && "$SL_LINE" != "{}" ]] || { SL_LINE=""; return 0; }
  sl_say "clusterMap:"; printf '%s\n' "$SL_LINE" | yq -P '.' | sed 's/^/    /' >&2
  sl_map_validate "$SL_LINE" || { sl_yes "Keep it anyway (the workflow's validate step decides)?" n || return 1; }
  return 0
}

# ------------------------------------------------------------------ flow
sl_targets() {  # the target inputs: clusterMap or the lists named in TARGET_LISTS
  local l
  if sl_has clusterMap && [[ "${TARGETS:-lists}" == "map-or-lists" ]]; then
    sl_menu "Targets of ${WF_TEMPLATE}:" "clusterMap: each cluster with its own instances and values" \
      "Lists: ${TARGET_LISTS:-} (every instance on every listed cluster)"
    if [[ "$SL_PICK" -eq 0 ]]; then
      sl_prompt clusterMap
      if sl_isset clusterMap; then SL_MAP=1; return 0; fi
      sl_say "no clusterMap: the ${TARGET_LISTS:-} lists select the targets"
    fi
  fi
  SL_MAP=0
  for l in ${TARGET_LISTS:-}; do sl_prompt "$l" mandatory; done
}

sl_optional_menu() {
  local i opts=() names=() cur
  while true; do
    opts=("Done: review and submit"); names=("")
    for ((i = 0; i < ${#P_NAME[@]}; i++)); do
      [[ " ${SL_ASKED} " == *" ${P_NAME[$i]} "* ]] && continue
      cur="$( [[ "${P_SET[$i]}" == 1 ]] && printf '= %s' "${P_VAL[$i]}" || printf '(default: %s)' "${P_DEF[$i]:-empty}")"
      opts+=("$(printf '%-30s %s' "${P_NAME[$i]}" "$cur" | cut -c1-110)"); names+=("${P_NAME[$i]}")
    done
    [[ "${#opts[@]}" -gt 1 ]] || return 0
    sl_menu "Optional inputs of ${WF_TEMPLATE}:" "${opts[@]}"
    [[ "$SL_PICK" -eq 0 ]] && return 0
    sl_prompt "${names[$SL_PICK]}"
    sl_yes "Choose another optional input?" y || return 0
  done
}

sl_summary() {
  local i
  sl_head "Workflow ${WF_TEMPLATE}: inputs to submit"
  for ((i = 0; i < ${#P_NAME[@]}; i++)); do
    [[ "${P_SET[$i]}" == 1 ]] || continue
    printf '  %-30s %s\n' "${P_NAME[$i]}" "$(printf '%s' "${P_VAL[$i]}" | tr '\n' ' ' | cut -c1-120)" >&2
  done
  sl_say "  ${C_D}(every other input keeps its WorkflowTemplate default)${C_0}"
}

sl_quote() {  # sl_quote WORD -> WORD, single-quoted for the shell when it needs quoting
  if [[ "$1" =~ ^[A-Za-z0-9_./:=@,+-]+$ ]]; then printf '%s' "$1"
  else printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; fi
}
sl_command() {  # the equivalent argo command, printed for the record
  local i cmd="argo submit -n ${ARGO_NS} --from workflowtemplate/${WF_TEMPLATE}" f files=""
  for ((i = 0; i < ${#P_NAME[@]}; i++)); do
    [[ "${P_SET[$i]}" == 1 ]] || continue
    if [[ "${P_NAME[$i]}" == patchFiles && -n "${SL_PACKED:-}" ]]; then
      # the contents, as the helper prints them (not the base64 itself)
      for f in $SL_PACKED; do files="${files} $(sl_quote "$f")"; done
      cmd="${cmd} -p \"patchFiles=\$($(sl_quote "${SL_ROOT}/scripts/submit/pack-patch-files.sh")${files})\""
      continue
    fi
    cmd="${cmd} -p $(sl_quote "${P_NAME[$i]}=${P_VAL[$i]}")"
  done
  printf '%s' "$cmd"
}

sl_pack_patch_files() {
  # tpg-patch and tpg-create-instance (Round 14): the patch files the inputs and
  # clusterMap name (patchMode apply) are read here and sent in patchFiles, because
  # the workflow runs on the hub. Sets patchFiles and SL_PACKED; 1 when a file is missing.
  local mode map files=() f out
  mode="$(sl_val patchMode)"; mode="${mode:-apply}"
  if [[ "$mode" != clear ]]; then
    for f in postgresPatchFilePath valuesPatchFilePath operatorValuesPatchFilePath; do
      sl_isset "$f" && files+=("$(sl_val "$f")")
    done
  fi
  if sl_isset clusterMap; then
    map="$(printf '%s\n' "$(sl_val clusterMap)" | yq -o=json -I=0 '.' 2>/dev/null)" || map='{}'
    while IFS= read -r f; do [[ -n "$f" ]] && files+=("$f"); done < <(jq -r --arg d "$mode" 'to_entries[] | (.value.patchMode // $d) as $cm
      | (if $cm != "clear" then (.value.operatorValuesPatchFilePath // empty) else empty end),
        ((.value.instances // {}) | to_entries[] | (.value.patchMode // $cm) as $im | select($im != "clear")
         | .value.postgresPatchFilePath // empty, .value.valuesPatchFilePath // empty)' <<<"$map" 2>/dev/null)
  fi
  SL_PACKED=""
  if [[ "${#files[@]}" -eq 0 ]]; then sl_unset patchFiles; return 0; fi
  local uniq=()   # bash 3.2 (macOS): no mapfile
  while IFS= read -r f; do [[ -n "$f" ]] && uniq+=("$f"); done < <(printf '%s\n' "${files[@]}" | sort -u)
  files=("${uniq[@]}")
  if ! out="$(bash "${SL_ROOT}/scripts/submit/pack-patch-files.sh" "${files[@]}" 2>&1)"; then
    sl_err "patch file: ${out}"; return 1
  fi
  sl_setv patchFiles "$out"
  SL_PACKED="${files[*]}"
  sl_ok "patch files read from this machine: ${SL_PACKED}"
}

sl_submit() {  # -> SL_WORKFLOW
  # patchFiles can pass the 128 KiB Linux limits one command-line argument to, so
  # it goes through a parameter file (argo) or a file read by jq (kubectl)
  local i args=() out
  for ((i = 0; i < ${#P_NAME[@]}; i++)); do
    [[ "${P_SET[$i]}" == 1 ]] || continue
    if [[ "${P_NAME[$i]}" == patchFiles ]]; then
      local q="'"
      printf "patchFiles: '%s'\n" "${P_VAL[$i]//$q/$q$q}" > "$SL_TMP/params.yaml"
      printf '%s' "${P_VAL[$i]}" > "$SL_TMP/patch-files.json"
      args+=(--parameter-file "$SL_TMP/params.yaml")
      continue
    fi
    args+=(-p "${P_NAME[$i]}=${P_VAL[$i]}")
  done
  if command -v argo >/dev/null 2>&1; then
    out="$(argo ${HUB_CONTEXT:+--context "$HUB_CONTEXT"} submit -n "$ARGO_NS" --from "workflowtemplate/${WF_TEMPLATE}" ${args[@]+"${args[@]}"} -o name 2>&1)" \
      || sl_die "argo submit failed: ${out}"
  else
    local params='[]'
    for ((i = 0; i < ${#P_NAME[@]}; i++)); do
      [[ "${P_SET[$i]}" == 1 ]] || continue
      if [[ "${P_NAME[$i]}" == patchFiles ]]; then
        params="$(jq -c --rawfile v "$SL_TMP/patch-files.json" '. + [{name: "patchFiles", value: $v}]' <<<"$params")"
      else
        params="$(jq -c --arg n "${P_NAME[$i]}" --arg v "${P_VAL[$i]}" '. + [{name: $n, value: $v}]' <<<"$params")"
      fi
    done
    jq -n --arg t "$WF_TEMPLATE" --arg ns "$ARGO_NS" --argjson p "$params" \
      '{apiVersion: "argoproj.io/v1alpha1", kind: "Workflow",
        metadata: {generateName: ($t + "-"), namespace: $ns},
        spec: {workflowTemplateRef: {name: $t}, arguments: {parameters: $p}}}' > "$SL_TMP/workflow.json"
    out="$(kubectl ${HUB_CONTEXT:+--context "$HUB_CONTEXT"} create -f "$SL_TMP/workflow.json" -o name 2>&1)" \
      || sl_die "kubectl create failed (the hub admission policy names each wrong input): ${out}"
  fi
  SL_WORKFLOW="${out##*/}"
  sl_ok "submitted: ${SL_WORKFLOW}"
}

sl_watch() {
  local phase pod k=(kubectl ${HUB_CONTEXT:+--context "$HUB_CONTEXT"} -n "$ARGO_NS")
  sl_say "watching ${SL_WORKFLOW} (Ctrl+C stops watching, not the workflow)"
  while true; do
    phase="$("${k[@]}" get workflow "$SL_WORKFLOW" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    printf '\r  %s: %-10s %s' "$SL_WORKFLOW" "${phase:-Pending}" "$(date +%H:%M:%S)" >&2
    case "$phase" in Succeeded|Failed|Error) break ;; esac
    sleep 10
  done
  printf '\n' >&2
  pod="$("${k[@]}" get pods -l "workflows.argoproj.io/workflow=${SL_WORKFLOW}" -o json 2>/dev/null \
    | jq -r '[.items[] | select(.metadata.name | test("report"))] | sort_by(.metadata.creationTimestamp) | last | .metadata.name // ""')"
  if [[ -n "$pod" ]]; then "${k[@]}" logs "$pod" -c main 2>/dev/null | sed -n '/tpg run report/,$p' >&2 || true
  else sl_say "  no report pod found; argo get -n ${ARGO_NS} ${SL_WORKFLOW} shows the steps"; fi
}

sl_main() {
  local m
  for c in yq jq python3 kubectl; do command -v "$c" >/dev/null 2>&1 || sl_die "${c} is required"; done
  yq --version 2>/dev/null | grep -q mikefarah || sl_die "yq v4 (mikefarah) is required: https://github.com/mikefarah/yq"
  sl_load "$WF_TEMPLATE"
  sl_head "${WF_TEMPLATE}: ${WF_TITLE:-}"
  SL_ASKED=""
  # 1. targets and mandatory inputs
  sl_targets
  SL_ASKED="clusterMap ${TARGET_LISTS:-}"
  for m in ${MANDATORY:-}; do sl_prompt "$m" mandatory; SL_ASKED="${SL_ASKED} ${m}"; done
  if [[ "${SL_MAP:-0}" -eq 0 ]]; then
    for m in ${MANDATORY_WITHOUT_MAP:-}; do sl_prompt "$m" mandatory; SL_ASKED="${SL_ASKED} ${m}"; done
  else
    for m in ${MANDATORY_WITHOUT_MAP:-}; do
      sl_say ""; sl_say "${m}: with clusterMap it may come from the map; set it here as the default of every target?"
      if sl_yes "  set ${m} now?" n; then sl_prompt "$m" mandatory; fi
      SL_ASKED="${SL_ASKED} ${m}"
    done
  fi
  if declare -F sl_hook_mandatory >/dev/null; then sl_hook_mandatory; fi
  # 2. optional inputs
  sl_say ""
  sl_optional_menu
  while true; do
    if declare -F sl_hook_check >/dev/null && ! sl_hook_check; then
      sl_optional_menu; continue
    fi
    if ! sl_rules_check; then
      sl_say "  change the inputs above (the hub refuses this combination)"
      sl_optional_menu; continue
    fi
    sl_summary
    sl_say ""; sl_say "Equivalent command:"; sl_say "  $(sl_command)"
    if sl_isset clusterMap; then sl_map_validate "$(sl_val clusterMap)" || sl_say "  (the workflow's validate step will refuse this map)"; fi
    sl_menu "Submit ${WF_TEMPLATE}?" "Submit" "Change optional inputs" "Cancel"
    case "$SL_PICK" in
      0) break ;;
      1) sl_optional_menu ;;
      2) sl_say "cancelled: nothing submitted"; exit 0 ;;
    esac
  done
  sl_submit
  if [[ "${TPG_NO_WATCH:-0}" != "1" ]] && sl_yes "Watch the run and print its report?" y; then sl_watch; fi
}
