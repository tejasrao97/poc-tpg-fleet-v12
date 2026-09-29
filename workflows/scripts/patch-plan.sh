#!/usr/bin/env bash
# patch-plan.sh WORKFLOW_NAME
# tpg-patch, before anything changes (Round 14, design decisions D76 to D79): for
# every target cluster, on a clone of the fleet branch,
#   1 render the targets as they are now (the "before" objects)
#   2 store the patch files the run received (input patchFiles) under their UID
#     names and make them current in clusters/fleet.yaml (patch-lib.sh
#     patch_prepare); check them against clusters/fleet.yaml and the cluster:
#       postgres files   no spec.postgresVersion (tpg-upgrade), spec.highAvailability
#                        (tpg-scale-instance), spec.storageClassName, the Service
#                        fields (the exposure values of a values patch set them);
#                        storageSize and walStorageSize not smaller
#       values files     no instance.name, instance.postgresVersion,
#                        instance.highAvailability, instance.storageClassName,
#                        instance.serviceType, cluster, patches, valuesOverride; sizes
#                        not smaller; no backup.additionalParameters, backup.enableSSL,
#                        backup.forcePathStyle (ignored by the tpg-instances
#                        ApplicationSet on a running instance). May switch the backup
#                        scheduler (D70) and FerretDB (D71): the chart refuses the
#                        combinations the workflow inputs refuse
#       operator values  operatorImage only with the tag of the cluster's operator
#                        version (another registry, not another version); the pull
#                        Secret, ClusterIssuer and namespace it names must exist
#       patchMode=clear  the path given must be the current file of that kind
#     The validate step has checked the type of each file already (patchcheck.py).
#   3 render the targets with the new clusters/fleet.yaml (helm template) and send
#     them through the API server (--dry-run=server): a render or admission error
#     BLOCKs the cluster (PATCH_REFUSED) and names the error
#   4 print the diff: objects the patch no longer renders, and kubectl diff
#     --server-side of the rendered objects against the live ones. A target with
#     no difference is NO_CHANGE and is not synced; a cluster without any is not
#     planned.
# Nothing is committed here: patch-cluster.sh does the same on a fresh clone under
# the cluster mutex, then commits (pushMode direct, or a pull request branch), syncs
# and verifies. The UID names are chosen once for the run (record patch.names).
#
# Records precheck.<cluster> (PASSED | BLOCKED | NO_CHANGE), plan.<cluster> (the
# targets with a change) and result.git.
WF="$1"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh
# shellcheck source=workflows/scripts/patch-lib.sh
source /scripts/patch-lib.sh
result_guard result.git

REPO="$WORK/repo"
git_clone "$REPO"
inv="$(run_data inventory)"; [[ -n "$inv" ]] || inv="[]"
any_blocked=0; planned=0

# One stored name per received file for the whole run (every cluster, both steps)
declare -a apply_paths=()
for c in $(jq -r '.[].name' <<<"$inv"); do
  t="$(patch_targets "$c" "$inv")"
  while IFS= read -r p; do [[ -n "$p" ]] && apply_paths+=("$p"); done < <(jq -r '
    [(.operator // empty | . + {kind: "operator"}),
     (.instances[] | (.postgres // empty | . + {kind: "postgres"}), (.values // empty | . + {kind: "values"}))]
    | .[] | select(.mode != "clear") | .kind + "=" + .path' <<<"$t")
done
if [[ "${#apply_paths[@]}" -gt 0 ]]; then
  patch_names_plan "$REPO" "${apply_paths[@]}" || { record result.git FAILED UNEXPECTED_ERROR "no stored names for the patch files"; exit 1; }
  log "patch files of this run, as stored in the fleet repository: $(patch_names)"
fi

for c in $(jq -r '.[].name' <<<"$inv"); do
  C_ERRS=()
  t="$(patch_targets "$c" "$inv")"
  if jq -e '.operator == null and (.instances | length) == 0' <<<"$t" >/dev/null; then
    record_entry "precheck.${c}" NO_CHANGE "" "no patch file applies to ${c}"
    continue
  fi
  if ! use_cluster "$c" || ! tk get --raw=/readyz >/dev/null 2>&1; then
    record_entry "precheck.${c}" BLOCKED UNREACHABLE "API server not reachable from the hub"
    any_blocked=1; continue
  fi
  cp "$REPO/$FLEET_REL" "$WORK/fleet.cluster.bak"
  patch_render_all "$c" "$t" before
  patch_prepare "$c" "$t"
  [[ "${#C_ERRS[@]}" -gt 0 ]] || patch_render_all "$c" "$t" after
  [[ "${#C_ERRS[@]}" -gt 0 ]] || patch_dry_run "$c"
  [[ "${#C_ERRS[@]}" -gt 0 ]] || patch_diff "$c"
  # the next cluster starts from the fleet branch again (patch-cluster.sh commits per cluster)
  cp "$WORK/fleet.cluster.bak" "$REPO/$FLEET_REL"
  git -C "$REPO" checkout --quiet -- . 2>/dev/null || true
  git -C "$REPO" clean --quiet -fd -- charts/tpg-instance/patches patches 2>/dev/null || true

  if [[ "${#C_ERRS[@]}" -gt 0 ]]; then
    record_entry "precheck.${c}" BLOCKED PATCH_REFUSED "$(printf '%s; ' "${C_ERRS[@]}")"
    for i in $(jq -r '.instances[].name' <<<"$t"); do record_entry "result.${c}.${i}" FAILED PATCH_REFUSED "see precheck.${c}"; done
    jq -e '.operator != null' <<<"$t" >/dev/null && record_entry "result.${c}.operator" FAILED PATCH_REFUSED "see precheck.${c}"
    any_blocked=1
    continue
  fi
  changed="$(printf '%s\n' "${PATCH_CHANGED[@]+"${PATCH_CHANGED[@]}"}" | jq -Rsc 'split("\n") | map(select(. != ""))')"
  hubonly="$(printf '%s\n' "${PATCH_HUB_ONLY[@]+"${PATCH_HUB_ONLY[@]}"}" | jq -Rsc 'split("\n") | map(select(. != ""))')"
  for x in $(jq -r '.instances[]' <<<"$PREP_PLAN") $( [[ "$(jq -r '.operator' <<<"$PREP_PLAN")" == "true" ]] && echo operator); do
    jq -e --arg x "$x" 'index($x) != null' <<<"$changed" >/dev/null && continue
    jq -e --arg x "$x" 'index($x) != null' <<<"$hubonly" >/dev/null && continue
    record_entry "result.${c}.${x}" SUCCEEDED NO_CHANGE "the patch renders the objects that run on ${c}: nothing to sync"
  done
  if [[ "$(jq -n --argjson a "$changed" --argjson b "$hubonly" '$a + $b | length')" -eq 0 ]]; then
    record_entry "precheck.${c}" NO_CHANGE "" "every target already runs what the patch renders; not synced"
    continue
  fi
  # the targets to commit: those with a change on the cluster (synced) and those where
  # only values the workflows read change (committed, not synced)
  changed="$(jq -c --argjson b "$hubonly" '. + $b' <<<"$changed")"
  plan="$(jq -c --argjson ch "$changed" '{instances: [.instances[] | select(. as $i | $ch | index($i) != null)],
    operator: (.operator and ($ch | index("operator") != null))}' <<<"$PREP_PLAN")"
  record_entry "precheck.${c}" PASSED "" "to sync: $(jq -r --argjson h "$hubonly" '[(.instances + (if .operator then ["operator"] else [] end))[] | select(. as $x | $h | index($x) | not)] | join(",")' <<<"$plan")$( [[ "$hubonly" == "[]" ]] || printf '; to commit only (nothing changes on the cluster): %s' "$(jq -r 'join(",")' <<<"$hubonly")")"
  record_entry "plan.${c}" PLANNED "" "$plan"
  planned=$((planned + 1))
  if [[ "${P_DRY_RUN:-false}" == "true" ]]; then
    for x in $(jq -r '.instances[] , (if .operator then "operator" else empty end)' <<<"$plan"); do
      record_entry "result.${c}.${x}" SUCCEEDED DRY_RUN "the diff above is what a sync would change; nothing was committed"
    done
  fi
done

blocked_note=""; [[ "$any_blocked" -eq 0 ]] || blocked_note="; some clusters are BLOCKED (see the pre-check)"
if [[ "${P_DRY_RUN:-false}" == "true" ]]; then
  record result.git SUCCEEDED DRY_RUN "${planned} cluster(s) with a change; nothing committed or synced${blocked_note}"
  exit 0
fi
record result.git SUCCEEDED PLANNED "${planned} cluster(s) to patch; each is committed and synced in its own step (pushMode=${P_PUSH_MODE:-direct})${blocked_note}"
