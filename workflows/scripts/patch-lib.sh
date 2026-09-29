#!/usr/bin/env bash
# patch-lib.sh: the per-cluster work of tpg-patch (Round 14, design decisions D76
# to D79). Sourced after lib.sh by patch-plan.sh (every cluster, before anything
# changes) and patch-cluster.sh (one cluster, under its mutex, on a fresh clone of
# the fleet branch), so both steps check, render and diff the same way.
#
# The caller sets REPO (a fleet repository checkout) and C_ERRS=() per cluster.
#   patch_targets CLUSTER INVENTORY   what the inputs ask for on the cluster (JSON):
#                                     {operator: null | {path, mode},
#                                      instances: [{name, postgres: null | {path, mode},
#                                                   values: null | {path, mode}}]}
#   patch_render_all CLUSTER TARGETS WHEN
#                                     render every target from REPO into
#                                     $WORK/render/<WHEN>-<cluster>-<target>.yaml
#                                     (WHEN before or after)
#   patch_prepare CLUSTER TARGETS     store the files under their UID names, make them
#                                     current (the old current becomes previous), write
#                                     the operator's effective values file; check each
#                                     file against clusters/fleet.yaml and the cluster.
#                                     Sets PREP_PLAN {instances: [...], operator: bool}
#   patch_dry_run CLUSTER             the after renders through the API server
#                                     (--dry-run=server): the render and admission errors
#   patch_diff CLUSTER                what a sync would change, printed to the log:
#                                     objects the patch no longer renders (the sync
#                                     prunes them) and kubectl diff --server-side of the
#                                     rendered objects against the live ones. Sets
#                                     PATCH_CHANGED (targets with a change)
# Every refusal is appended to C_ERRS; the caller records it (PATCH_REFUSED).
PATCH_CHART_PREFIX="charts/tpg-instance/"
PATCH_DEFAULT_ISSUER="postgres-operator-ca-certificate-cluster-issuer"
PATCH_DEFAULT_PULL_SECRET="regsecret"
# The Argo CD field manager (server-side apply) and tracking method of the hub
ARGOCD_MANAGER="argocd-controller"
CLUSTER_SCOPED_KINDS='["ClusterRole","ClusterRoleBinding","MutatingWebhookConfiguration","ValidatingWebhookConfiguration","ClusterIssuer","CustomResourceDefinition","Namespace","PriorityClass","StorageClass"]'

patch_targets() {  # patch_targets CLUSTER INVENTORY_JSON -> the targets of the cluster (JSON)
  local c="$1" inv="$2" op opm out i pg val m
  op="$(cmap_cval "$c" operatorValuesPatchFilePath "${P_OPERATOR_VALUES_PATCH:-}")"
  opm="$(cmap_cval "$c" patchMode "${P_PATCH_MODE:-apply}")"
  out="$(jq -cn --arg p "$op" --arg m "$opm" '{operator: (if $p == "" then null else {path: $p, mode: $m} end), instances: []}')"
  for i in $(jq -r --arg c "$c" '.[] | select(.name == $c) | .instances[].name' <<<"$inv"); do
    pg="$(cmap_ival "$c" "$i" postgresPatchFilePath "${P_POSTGRES_PATCH:-}")"
    val="$(cmap_ival "$c" "$i" valuesPatchFilePath "${P_VALUES_PATCH:-}")"
    [[ -n "$pg$val" ]] || continue
    m="$(cmap_ival "$c" "$i" patchMode "$opm")"
    out="$(jq -c --arg i "$i" --arg pg "$pg" --arg v "$val" --arg m "$m" '.instances += [{name: $i,
      postgres: (if $pg == "" then null else {path: $pg, mode: $m} end),
      values: (if $v == "" then null else {path: $v, mode: $m} end)}]' <<<"$out")"
  done
  printf '%s' "$out"
}

# ---- checks that need clusters/fleet.yaml or the cluster (the validate step has
# checked the type and shape of every file already: workflows/scripts/patchcheck.py)
patch_size_not_smaller() {  # patch_size_not_smaller FILE WHAT NEW CURRENT
  [[ -n "$3" && -n "$4" ]] || return 0
  local n c
  n="$(qty_bytes "$3")"; c="$(qty_bytes "$4")"
  [[ "$n" -ge 0 && "$c" -ge 0 ]] || { C_ERRS+=("$1: $2 '$3' is not a valid quantity"); return 0; }
  (( n >= c )) || C_ERRS+=("$1: $2 ${3} is smaller than the current ${4}; a volume cannot shrink")
}

patch_check_postgres() {  # patch_check_postgres FILE(repo path) NAME CLUSTER INSTANCE: fields other workflows own
  local f="$REPO/$1" n="$2" k
  yq -e '.spec.postgresVersion == null' "$f" >/dev/null || C_ERRS+=("${n}: spec.postgresVersion is changed by tpg-upgrade component=postgres")
  yq -e '.spec.highAvailability == null' "$f" >/dev/null || C_ERRS+=("${n}: spec.highAvailability is changed by tpg-scale-instance")
  yq -e '.spec.storageClassName == null' "$f" >/dev/null || C_ERRS+=("${n}: spec.storageClassName cannot change on a running instance")
  for k in serviceType serviceAnnotations readOnlyServiceType readOnlyServiceAnnotations; do
    yq -e ".spec.${k} == null" "$f" >/dev/null \
      || C_ERRS+=("${n}: spec.${k} comes from the exposure values (instance.exposure, serviceAnnotations, readOnlyExposure, readOnlyServiceAnnotations, allowedSourceRanges): set them in a values patch")
  done
  patch_size_not_smaller "$n" spec.storageSize "$(yq -r '.spec.storageSize // ""' "$f")" \
    "$(fleet_instance_value "$REPO" "$3" "$4" '.instance.storageSize' '')"
  patch_size_not_smaller "$n" spec.walStorageSize "$(yq -r '.spec.walStorageSize // ""' "$f")" \
    "$(fleet_instance_value "$REPO" "$3" "$4" '.instance.walStorageSize' '')"
}

patch_check_values() {  # patch_check_values FILE(repo path) NAME CLUSTER INSTANCE: fields other workflows own
  local f="$REPO/$1" n="$2" k
  for k in .instance.name .instance.postgresVersion .instance.highAvailability .instance.storageClassName .instance.serviceType .cluster .patches .valuesOverride; do
    yq -e "${k} == null" "$f" >/dev/null || C_ERRS+=("${n}: ${k#.} cannot be set by a values patch")
  done
  # tpg-instances ignores these PostgresBackupLocation fields (ignoreDifferences with
  # RespectIgnoreDifferences), so a sync would never apply them to a running instance
  for k in .backup.additionalParameters .backup.enableSSL .backup.forcePathStyle; do
    yq -e "${k} == null" "$f" >/dev/null \
      || C_ERRS+=("${n}: ${k#.} is ignored by Argo CD on a running instance (tpg-instances ignoreDifferences); it is set when the instance is created (tpg-day0, tpg-create-instance)")
  done
  patch_size_not_smaller "$n" instance.storageSize "$(yq -r '.instance.storageSize // ""' "$f")" \
    "$(fleet_instance_value "$REPO" "$3" "$4" '.instance.storageSize' '')"
  patch_size_not_smaller "$n" instance.walStorageSize "$(yq -r '.instance.walStorageSize // ""' "$f")" \
    "$(fleet_instance_value "$REPO" "$3" "$4" '.instance.walStorageSize' '')"
}

patch_check_operator() {  # patch_check_operator FILE(repo path) NAME CLUSTER (use_cluster first)
  local f="$REPO/$1" n="$2" c="$3" img tag want v
  img="$(yq -r '.operatorImage // ""' "$f")"
  if [[ -n "$img" ]]; then
    tag="${img##*:}"
    want="$(C="$c" yq -r '.clusters[strenv(C)].operator.version // ""' "$REPO/$FLEET_REL")"
    if [[ -z "$want" ]]; then
      C_ERRS+=("${n}: operatorImage needs clusters.${c}.operator.version in ${FLEET_REL} (run tpg-day0 first)")
    elif [[ "$(norm_operator_version "$tag")" != "$(norm_operator_version "$want")" ]]; then
      C_ERRS+=("${n}: operatorImage tag ${tag} differs from the operator version ${want} of ${c}: a values patch may move the image to another registry, not change its version (tpg-upgrade component=operator)")
    fi
  fi
  v="$(yq -r '.dockerRegistrySecretName // ""' "$f")"
  if [[ -n "$v" && "$v" != "$PATCH_DEFAULT_PULL_SECRET" ]] && ! tk -n "$OPERATOR_NS" get secret "$v" >/dev/null 2>&1; then
    C_ERRS+=("${n}: dockerRegistrySecretName ${v}: no Secret ${OPERATOR_NS}/${v} on ${c} (the operator could not pull images); create it first")
  fi
  v="$(yq -r '.certManagerClusterIssuerName // ""' "$f")"
  if [[ -n "$v" && "$v" != "$PATCH_DEFAULT_ISSUER" ]] && ! tk get clusterissuer "$v" >/dev/null 2>&1; then
    C_ERRS+=("${n}: certManagerClusterIssuerName ${v}: no ClusterIssuer ${v} on ${c}; create it first")
  fi
  v="$(yq -r '.certManagerNamespace // ""' "$f")"
  if [[ -n "$v" ]] && ! tk get namespace "$v" >/dev/null 2>&1; then
    C_ERRS+=("${n}: certManagerNamespace ${v}: no namespace ${v} on ${c}")
  fi
}

patch_clear_matches() {  # patch_clear_matches GIVEN CURRENT KIND -> 0 when GIVEN names CURRENT
  local g
  g="$(patch_norm "$1")"
  [[ -n "$2" ]] || return 1
  [[ "$g" == "$2" ]] && return 0
  [[ "$3" != operator && "$g" == "${PATCH_CHART_PREFIX}$2" ]]
}

# ---- rendering
patch_operator_render() {  # patch_operator_render CLUSTER OUT_FILE: the operator chart with the effective values file
  local c="$1" opv eff host
  opv="$(C="$c" yq -r '.clusters[strenv(C)].operator.version // ""' "$REPO/$FLEET_REL")"
  eff="$REPO/$(operator_effective_rel "$c")"
  host="tanzu-sql-postgres.packages.broadcom.com"
  local -a vf=()
  [[ -f "$eff" ]] && vf=(-f "$eff")
  vault_secret broadcom-registry password \
    | helm registry login "$host" --username "$(vault_secret broadcom-registry username)" --password-stdin >/dev/null 2>&1 || true
  helm template "tpg-${c}-operator" "oci://${host}/vmware-sql-postgres-operator" --version "$opv" \
    --namespace "$OPERATOR_NS" ${vf[@]+"${vf[@]}"} > "$2" 2>"$2.err"
}

patch_render_all() {  # patch_render_all CLUSTER TARGETS WHEN
  local c="$1" t="$2" w="$3" i out
  mkdir -p "$WORK/render"
  for i in $(jq -r '.instances[].name' <<<"$t"); do
    out="$WORK/render/${w}-${c}-${i}.yaml"
    if ! instance_render "$REPO" "$c" "$i" > "$out" 2>"$out.err"; then
      [[ "$w" == before ]] && : > "$out" || C_ERRS+=("${i}: the chart does not render: $(tail -n 3 "$out.err" | tr '\n' ' ')")
    fi
    # values the workflows read on the hub and the chart does not render: a values
    # patch with only backup.scheduled moves the instance in or out of the backup
    # CronWorkflows (discover.sh) without a change on the cluster
    printf 'backup.scheduled=%s\n' "$(instance_effective "$REPO" "$c" "$i" '.backup.scheduled' true)" > "$WORK/render/${w}-${c}-${i}.hub"
  done
  if jq -e '.operator != null' <<<"$t" >/dev/null; then
    out="$WORK/render/${w}-${c}-operator.yaml"
    if ! patch_operator_render "$c" "$out"; then
      [[ "$w" == before ]] && : > "$out" \
        || C_ERRS+=("operator values: the operator chart does not render with the values file: $(tail -n 3 "$out.err" | tr '\n' ' ')")
    fi
  fi
}

patch_prepare() {  # patch_prepare CLUSTER TARGETS (use_cluster first)
  local c="$1" t="$2" p m stored cur i kind n
  PREP_PLAN='{"instances":[],"operator":false}'
  # ---- operator
  if jq -e '.operator != null' <<<"$t" >/dev/null; then
    p="$(jq -r '.operator.path' <<<"$t")"; m="$(jq -r '.operator.mode' <<<"$t")"
    if ! fleet_has_cluster "$REPO" "$c"; then
      C_ERRS+=("no clusters.${c} in ${FLEET_REL} (run tpg-day0 first)")
    elif ! patch_ref "$REPO/$FLEET_REL" "$c" "" operator >/dev/null; then
      C_ERRS+=("${c}: operator.patches.values lists several files (Round 11); Round 14 applies one current file: merge them into one file and apply it (tpg-fleet README, Upgrading to Round 14)")
    elif [[ "$m" == clear ]]; then
      cur="$(patch_ref "$REPO/$FLEET_REL" "$c" "" operator)" || cur=""
      if patch_clear_matches "$p" "$cur" operator; then
        patch_set_current "$REPO" "$c" "" operator "" && operator_effective_write "$REPO" "$c"
        PREP_PLAN="$(jq -c '.operator = true' <<<"$PREP_PLAN")"
      else
        C_ERRS+=("patchMode=clear: ${p} is not the current operator values patch of ${c} (current: ${cur:-none})")
      fi
    elif stored="$(patch_store "$REPO" "$p" operator)"; then
      patch_check_operator "$stored" "$p" "$c"
      patch_set_current "$REPO" "$c" "" operator "$stored" && operator_effective_write "$REPO" "$c"
      PREP_PLAN="$(jq -c '.operator = true' <<<"$PREP_PLAN")"
    else
      C_ERRS+=("${p}: the file was not received (patchFiles)")
    fi
  fi
  # ---- instances
  for i in $(jq -r '.instances[].name' <<<"$t"); do
    if ! n="$(cmap_guard "$c" "$i")"; then
      record_entry "result.${c}.${i}" SKIPPED_VERSION_MISMATCH "" "$n"
      continue
    fi
    for kind in postgres values; do
      jq -e --arg i "$i" --arg k "$kind" '.instances[] | select(.name == $i) | .[$k] != null' <<<"$t" >/dev/null || continue
      if ! patch_ref "$REPO/$FLEET_REL" "$c" "$i" "$kind" >/dev/null; then
        C_ERRS+=("${c}/${i}: patches.${kind} lists several files (Round 11); Round 14 applies one current file: merge them into one file and apply it (tpg-fleet README, Upgrading to Round 14)")
        continue
      fi
      p="$(jq -r --arg i "$i" --arg k "$kind" '.instances[] | select(.name == $i) | .[$k].path' <<<"$t")"
      m="$(jq -r --arg i "$i" --arg k "$kind" '.instances[] | select(.name == $i) | .[$k].mode' <<<"$t")"
      if [[ "$m" == clear ]]; then
        cur="$(patch_ref "$REPO/$FLEET_REL" "$c" "$i" "$kind")" || cur=""
        if patch_clear_matches "$p" "$cur" "$kind"; then
          patch_set_current "$REPO" "$c" "$i" "$kind" ""
        else
          C_ERRS+=("patchMode=clear: ${p} is not the current ${kind} patch of ${c}/${i} (current: ${cur:-none})")
        fi
        continue
      fi
      if ! stored="$(patch_store "$REPO" "$p" "$kind")"; then
        C_ERRS+=("${p}: the file was not received (patchFiles)"); continue
      fi
      if [[ "$kind" == postgres ]]; then patch_check_postgres "${PATCH_CHART_PREFIX}${stored}" "$p" "$c" "$i"
      else
        patch_check_values "${PATCH_CHART_PREFIX}${stored}" "$p" "$c" "$i"
        # a values file that turns FerretDB on lifts the valuesOverride tpg-restore
        # wrote for a restored copy (D71), which would otherwise win over it
        if [[ "$(yq -r '.ferret.enabled // ""' "$REPO/${PATCH_CHART_PREFIX}${stored}")" == "true" ]]; then
          C="$c" I="$i" yq -i 'del(.clusters[strenv(C)].instances[strenv(I)].valuesOverride.ferret)
            | del(.clusters[strenv(C)].instances[strenv(I)].valuesOverride | select(length == 0))' "$REPO/$FLEET_REL"
        fi
      fi
      patch_set_current "$REPO" "$c" "$i" "$kind" "$stored"
    done
    PREP_PLAN="$(jq -c --arg i "$i" '.instances += [$i]' <<<"$PREP_PLAN")"
  done
}

patch_dry_run() {  # patch_dry_run CLUSTER (use_cluster first): the after renders through the API server
  local c="$1" i f docs dr
  for i in $(jq -r '.instances[]' <<<"$PREP_PLAN"); do
    f="$WORK/render/after-${c}-${i}.yaml"
    [[ -s "$f" ]] || continue
    docs="$(yq 'select(.kind == "Postgres" or .kind == "PostgresBackupLocation"
               or .kind == "PostgresBackupSchedule" or .kind == "PostgresFerretDocumentDB")' "$f")"
    exposure_warning_rendered "$c" "$i" "$(cat "$f")"
    # FerretDB switched on by a values patch (D71): the documentdb extension is a manual step
    if yq -e 'select(.kind == "PostgresFerretDocumentDB") | .metadata.name' "$f" >/dev/null 2>&1 \
       && ! tk -n "pg-${i}" get postgresferretdocumentdb "$i" >/dev/null 2>&1; then
      record_entry "warning.${c}.${i}.ferret" WARNING FERRET_EXTENSION_REQUIRED \
        "${i}: FerretDB (Tech Preview) needs the documentdb extension in the instance; prepare it by hand (Runbook, FerretDB) or the FerretDB proxies do not start"
    fi
    if [[ -n "$docs" ]] && ! dr="$(tk -n "pg-${i}" apply --server-side --dry-run=server --field-manager="$ARGOCD_MANAGER" \
        --force-conflicts -f - <<<"$docs" 2>&1)"; then
      C_ERRS+=("${i}: the API server rejects the patched instance: $(tr '\n' ' ' <<<"$dr" | cut -c1-400)")
    fi
  done
  if [[ "$(jq -r '.operator' <<<"$PREP_PLAN")" == "true" ]]; then
    f="$WORK/render/after-${c}-operator.yaml"
    docs="$(yq 'select(.kind == "Deployment")' "$f" 2>/dev/null)"
    if [[ -n "$docs" ]] && ! dr="$(tk -n "$OPERATOR_NS" apply --server-side --dry-run=server \
        --field-manager="$ARGOCD_MANAGER" --force-conflicts -f - <<<"$docs" 2>&1)"; then
      C_ERRS+=("operator values: the API server rejects the operator Deployment: $(tr '\n' ' ' <<<"$dr" | cut -c1-400)")
    fi
  fi
}

patch_tracked_list() {  # patch_tracked_list FILE APP NAMESPACE -> the rendered objects as a List, each
  # with the tracking annotation Argo CD writes (annotation tracking), so the diff
  # shows only what the sync changes
  yq -o=json -I=0 'select(. != null and .kind != null)' "$1" | jq -sc --arg app "$2" --arg ns "$3" \
    --argjson cs "$CLUSTER_SCOPED_KINDS" '{apiVersion: "v1", kind: "List", items: map(
      .kind as $k
      | (if ($cs | index($k)) != null then "" else (.metadata.namespace // $ns) end) as $n
      | ((.apiVersion | split("/")) as $a | if ($a | length) == 2 then $a[0] else "" end) as $g
      | .metadata.annotations["argocd.argoproj.io/tracking-id"] = "\($app):\($g)/\(.kind):\($n)/\(.metadata.name)")}'
}

# The ignoreDifferences of the tpg-instances ApplicationSet (bootstrap/appsets/
# tpg-instances.yaml; tests/patch compares the two): Argo CD does not count these
# fields, so neither does the diff of tpg-patch.
PATCH_IGNORED_PATHS='{"PostgresBackupLocation": [["spec","additionalParameters"], ["spec","storage","azure","forcePathStyle"], ["spec","storage","azure","enableSSL"]], "Postgres": [["spec","postgresVersion"]]}'

patch_ignore_live() {  # patch_ignore_live NAMESPACE: stdin List -> stdout List
  # every ignored field of an object that runs takes its live value (or goes, when
  # the live object has none), so kubectl diff shows only what Argo CD compares
  local ns="$1" list n i kind name live
  list="$(cat)"
  n="$(jq '.items | length' <<<"$list")"
  for ((i = 0; i < n; i++)); do
    kind="$(jq -r --argjson i "$i" '.items[$i].kind' <<<"$list")"
    jq -e --arg k "$kind" 'has($k)' <<<"$PATCH_IGNORED_PATHS" >/dev/null || continue
    name="$(jq -r --argjson i "$i" '.items[$i].metadata.name' <<<"$list")"
    live="$(tk -n "$ns" get "$kind" "$name" -o json 2>/dev/null)" || continue
    [[ -n "$live" ]] || continue
    list="$(jq -c --argjson i "$i" --argjson live "$live" --argjson ps "$PATCH_IGNORED_PATHS" '
      .items[$i] |= (reduce $ps[.kind][] as $p (.;
        ($live | getpath($p)) as $v | if $v == null then delpaths([$p]) else setpath($p; $v) end))' <<<"$list")"
  done
  printf '%s\n' "$list"
}

patch_removed() {  # patch_removed BEFORE AFTER -> kind/name of objects only BEFORE renders
  comm -23 <(yq -r 'select(.kind != null) | .kind + "/" + .metadata.name' "$1" 2>/dev/null | sort -u) \
           <(yq -r 'select(.kind != null) | .kind + "/" + .metadata.name' "$2" 2>/dev/null | sort -u)
}

patch_diff() {
  # patch_diff CLUSTER (use_cluster first) -> PATCH_CHANGED (targets with a change on
  # the cluster), PATCH_HUB_ONLY (instances where only values the workflows read on
  # the hub change: committed, not synced), the diff in the log and $WORK/diff-<cluster>.txt
  local c="$1" t app ns before after removed rc out hub
  PATCH_CHANGED=(); PATCH_HUB_ONLY=()
  : > "$WORK/diff-${c}.txt"
  for t in $(jq -r '.instances[]' <<<"$PREP_PLAN") $( [[ "$(jq -r '.operator' <<<"$PREP_PLAN")" == "true" ]] && echo operator); do
    before="$WORK/render/before-${c}-${t}.yaml"; after="$WORK/render/after-${c}-${t}.yaml"
    if [[ "$t" == operator ]]; then app="tpg-${c}-operator"; ns="$OPERATOR_NS"; else app="tpg-${c}-${t}"; ns="pg-${t}"; fi
    [[ -f "$before" ]] || : > "$before"
    removed="$(patch_removed "$before" "$after")"
    rc=0
    out="$(patch_tracked_list "$after" "$app" "$ns" | patch_ignore_live "$ns" \
      | tk -n "$ns" diff --server-side --force-conflicts --field-manager="$ARGOCD_MANAGER" -f - 2>&1)" || rc=$?
    log "==================== diff ${c}/${t} (${app}) ===================="
    if [[ "$rc" -gt 1 ]]; then
      C_ERRS+=("${t}: kubectl diff failed: $(tr '\n' ' ' <<<"$out" | cut -c1-400)")
      continue
    fi
    {
      printf '==== %s/%s (%s)\n' "$c" "$t" "$app"
      [[ -z "$removed" ]] || printf 'objects the patch no longer renders (the sync prunes them):\n  - %s\n' "${removed//$'\n'/$'\n'  - }"
      [[ "$rc" -ne 1 ]] || printf '%s\n' "$out"
    } | tee -a "$WORK/diff-${c}.txt" >&2
    if [[ "$rc" -eq 0 && -z "$removed" ]]; then
      hub=""
      [[ "$t" == operator ]] || hub="$(diff "$WORK/render/before-${c}-${t}.hub" "$WORK/render/after-${c}-${t}.hub" 2>/dev/null | sed -n 's/^> //p' | paste -sd' ' -)"
      if [[ -n "$hub" ]]; then
        printf '%s/%s: nothing changes on the cluster; the workflows read %s\n' "$c" "$t" "$hub" | tee -a "$WORK/diff-${c}.txt" >&2
        PATCH_HUB_ONLY+=("$t")
      else
        log "${c}/${t}: no difference; the patch renders the objects that run"
      fi
    else
      PATCH_CHANGED+=("$t")
    fi
  done
}
