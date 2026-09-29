#!/usr/bin/env bash
# operator-upgrade.sh WORKFLOW_NAME CLUSTER TARGET_VERSION TIMEOUT_SECONDS
# tpg-upgrade component=operator, one cluster:
#   1 guards     every instance that exists is Running (declared but absent: warning
#                INSTANCE_NOT_DEPLOYED, left out); no downgrade; nothing to do when already at the target
#   2 backup     optional full backup of every Running instance (P_PRE_BACKUP=true)
#   3 Git        clusters.<cluster>.operator.version in clusters/fleet.yaml (PUSH_MODE direct | pr)
#   4 sync       wait for the ApplicationSet to render the new version, sync, verify operator and instances
# An operator values patch (tpg-patch, Round 14, D76) that sets operatorImage
# carries the tag of the running version: the version commit stores a copy of that
# file with the new tag under a new UID name and makes it current (the old file,
# never changed, becomes previous with its commit), and rewrites the effective copy
# patches/operator/clusters/<cluster>.yaml. A tag that is not the running version
# stops the upgrade before anything changes (OPERATOR_IMAGE_PINNED); so does a
# Round 11 list of several operator values files (OPERATOR_PATCH_LIST), which
# Round 14 no longer applies.
# P_DRY_RUN=true records the plan and changes nothing.
WF="$1"; C="$2"; TIMEOUT="$4"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh
TARGET="$(norm_operator_version "$3")"
export PUSH_MODE="${P_PUSH_MODE:-direct}" PR_TIMEOUT_SECONDS="${P_PR_TIMEOUT:-3600}"

fail() { record "result.${C}" FAILED "$1" "${2:-}"; exit 1; }
result_guard "result.${C}"
use_cluster "$C" || fail NOT_REGISTERED
app="tpg-${C}-operator"
REPO="$WORK/repo"
git_clone "$REPO"
current="$(C="$C" yq -r '.clusters[strenv(C)].operator.version // ""' "$REPO/$FLEET_REL")"
[[ -n "$current" ]] || fail NOT_IN_FLEET "clusters.${C}.operator.version is not declared (run tpg-day0)"
if [[ "$current" == "$TARGET" ]]; then
  record "result.${C}" SUCCEEDED ALREADY_AT_TARGET "$TARGET" "$current"
  exit 0
fi
if [[ "$(printf '%s\n%s\n' "${current#v}" "${TARGET#v}" | sort -V | tail -n1)" != "${TARGET#v}" ]]; then
  fail DOWNGRADE_NOT_SUPPORTED "${current} -> ${TARGET}"
fi
# Instances declared in clusters/fleet.yaml but absent on the cluster (never
# deployed, for example after a BLOCKED tpg-day0) are left out of the guard, the
# pre-upgrade backup and the post-upgrade wait, with warning INSTANCE_NOT_DEPLOYED.
# An instance that exists must be Running (design decision D61).
PRESENT=()
for i in $(inventory_instances "$C"); do
  if ! gerr="$(tk -n "pg-$i" get postgres "$i" -o name 2>&1 >/dev/null)"; then
    # Only NotFound means absent; any other error (API timeout, RBAC) stops the run
    grep -qiE 'NotFound|not found' <<<"$gerr" \
      || fail CLUSTER_API_ERROR "${i}: cannot read the Postgres object on ${C}: $(head -c 300 <<<"$gerr")"
    record_entry "warning.${C}.${i}.deployed" WARNING INSTANCE_NOT_DEPLOYED \
      "${i} is declared in clusters/fleet.yaml but does not exist on ${C}; deploy it with tpg-create-instance or tpg-day0, or remove it with tpg-delete-instance"
    continue
  fi
  [[ "$(pg_state "$i")" == "Running" ]] || fail INSTANCE_NOT_RUNNING_BEFORE "${i} (currentState $(pg_state "$i"))"
  PRESENT+=("$i")
done
rc=0; vfile="$(patch_ref "$REPO/$FLEET_REL" "$C" "" operator)" || rc=$?
[[ "$rc" -ne 2 ]] || fail OPERATOR_PATCH_LIST "clusters.${C}.operator.patches.values lists several files, which Round 14 does not apply: merge them into one and apply it with tpg-patch (tpg-fleet README, Upgrading to Round 14)"
[[ "$rc" -eq 0 ]] || vfile=""
img=""
[[ -z "$vfile" || ! -f "$REPO/$vfile" ]] || img="$(yq -r '.operatorImage // ""' "$REPO/$vfile")"
if [[ -n "$img" && "$(norm_operator_version "${img##*:}")" != "$(norm_operator_version "$current")" ]]; then
  fail OPERATOR_IMAGE_PINNED "${vfile} sets operatorImage ${img}, whose tag is not the running version ${current}; fix it with tpg-patch first"
fi
if [[ "${P_DRY_RUN:-false}" == "true" ]]; then
  record "result.${C}" SUCCEEDED DRY_RUN "would upgrade ${current} -> ${TARGET}; preUpgradeBackup=${P_PRE_BACKUP:-true}$( [[ -z "$img" ]] || printf '; operatorImage of %s -> %s' "$vfile" "${img%:*}:${TARGET}")" "$current"
  exit 0
fi

if [[ "${P_PRE_BACKUP:-true}" == "true" ]]; then
  for i in "${PRESENT[@]}"; do
    RESULT_KEY="backup.${C}.${i}" bash /scripts/backup-instance.sh "$WF" "$C" "$i" full "$TIMEOUT"
    b="$(run_data "backup.${C}.${i}")"
    case "$(jq -r '.status' <<<"$b")" in
      SUCCEEDED) ;;
      *) fail PRE_UPGRADE_BACKUP_FAILED "${i}: $(jq -r '.status + " " + .reason + " " + .detail' <<<"$b")" ;;
    esac
  done
fi

TARGET="$TARGET" C="$C" yq -i '.clusters[strenv(C)].operator.version = strenv(TARGET)' "$REPO/$FLEET_REL"
files=("$FLEET_REL"); img_note=""
if [[ -n "$img" ]]; then
  # stored patch files are never changed: a copy with the new tag becomes current
  stem="${vfile##*/}"; stem="${stem%.*}"; stem="$(sed -E 's/-[a-z0-9]{5}$//' <<<"$stem")"
  nfile="${PATCH_OPERATOR_DIR}/$(patch_stored_name "${stem}.yaml" "$(patch_uid)")"
  while [[ -e "$REPO/$nfile" ]]; do nfile="${PATCH_OPERATOR_DIR}/$(patch_stored_name "${stem}.yaml" "$(patch_uid)")"; done
  cp "$REPO/$vfile" "$REPO/$nfile"
  I="${img%:*}:${TARGET}" yq -i '.operatorImage = strenv(I)' "$REPO/$nfile"
  patch_set_current "$REPO" "$C" "" operator "$nfile"
  operator_effective_write "$REPO" "$C"
  files+=("$nfile" "$(operator_effective_rel "$C")")
  img_note="; operatorImage ${img%:*}:${TARGET} (${nfile}, previous ${vfile})"
fi
git_commit_push "$REPO" "operator ${C} ${current} -> ${TARGET} (${WF})" "${files[@]}" \
  || fail GIT_PUSH_FAILED "pushMode=${PUSH_MODE}"

appset_refresh tpg-operator
start="$(date +%s)"
until [[ "$(app_target_revision "$app")" == "$TARGET" ]]; do
  (( $(date +%s) - start > 600 )) && fail APPSET_NOT_UPDATED "$app targetRevision"
  log "waiting for the ApplicationSet tpg-operator to render ${TARGET} into ${app} (now $(app_target_revision "$app"))"
  sleep 15
done
# The Application already carries the new chart version (targetRevision of the
# OCI source); its fleet source (the effective values file) is synced at the
# fleet branch head, which holds the version commit.
# The target is checked directly (CRD Established, operator Deployment
# available) instead of waiting for Argo CD to rediscover the CRDs.
rc=0; app_sync_wait "$app" "$TIMEOUT" --pods tanzu-postgres-operator "" --ready-fn _operator_ready || rc=$?
[[ "$rc" -eq 0 ]] || fail "$SYNC_FAIL_REASON" "$SYNC_FAIL_DETAIL"
image="$(tk -n tanzu-postgres-operator get deploy -l app=postgres-operator \
  -o jsonpath='{.items[0].spec.template.spec.containers[0].image}')"

for i in "${PRESENT[@]}"; do
  pg_wait_ready "$i" "$TIMEOUT" || fail "INSTANCE_${POD_WATCH_REASON:-NOT_RUNNING}" "after the operator upgrade: ${POD_WATCH_DETAIL}"
done
record "result.${C}" SUCCEEDED "" "operator ${TARGET}, image ${image}${img_note}" "$current"
