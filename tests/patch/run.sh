#!/usr/bin/env bash
# tpg-patch (Round 14, design decisions D76 to D79) with the real lib.sh,
# patch-lib.sh, clustermap.py and chart, and stubs for Git hosting, the run
# ConfigMap, the Argo CD API and the target cluster:
#   patch-plan.sh     the files come from patchFiles and are stored as
#                     <name>-<uid>.yaml; current and previous (with the commit that
#                     added it) in clusters/fleet.yaml; the checks that need the fleet
#                     or the cluster; the render and server-side dry run; the diff
#                     (no difference: NO_CHANGE, not planned); patchMode=clear; the
#                     clusterMap postgresVersion guard; nothing is committed
#   patch-cluster.sh  per cluster: one commit (pushMode direct, or a pull request
#                     branch), the sync at that commit (off the fleet branch for a
#                     pull request), the merge by a person (merged: Synced without a
#                     second sync; closed or timed out: reverted), the revert of a
#                     failed sync (pull request: back to the commit each Application
#                     ran; direct: a revert commit), the operator's effective values file
# The instance is rendered with helm (helm template); the operator chart comes
# from the Broadcom registry, so its render is stubbed with a Deployment that
# carries the effective values file.
# Requires: bash 4, git, python3, jq, yq (mikefarah) and helm; skipped without them.
# ok() and bad() always return 0; single-quoted snippets are jq, yq or YAML.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
for t in git python3 jq yq helm; do command -v "$t" >/dev/null || { echo "SKIP tests/patch: $t not installed" >&2; exit 0; }; done
yq --version 2>&1 | grep -q mikefarah || { echo "SKIP tests/patch: yq is not mikefarah yq v4" >&2; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/       | /' | tail -14; FAIL=$((FAIL + 1)); }

# ---- the fleet repository: a git repository, so previous.commit can be found
REPO="$TMP/repo"
mkdir -p "$REPO/clusters" "$REPO/patches/operator"
cp -r "$ROOT/charts" "$REPO/"
cp -r "$ROOT/clusters/_template" "$REPO/clusters/"
rm -f "$REPO"/charts/tpg-instance/patches/example-*
printf 'backup:\n  fullRetention: 9\n' > "$REPO/charts/tpg-instance/patches/old-ab12c.yaml"
cat > "$REPO/clusters/fleet.yaml" <<'YAML'
clusters:
  c1:
    operator: {version: v4.5.0}
    instances:
      orders-db:
        instance: {postgresVersion: postgres-17.6, storageSize: 50Gi}
        patches:
          values: [patches/old-ab12c.yaml]
      billing-db: {instance: {postgresVersion: postgres-16.9}}
YAML
git -C "$REPO" init -q -b main && git -C "$REPO" -c user.email=t@t -c user.name=t add -A \
  && git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm base
BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"
git clone -q --bare "$REPO" "$TMP/origin.git"   # the hosted fleet repository (pushes go here)

# local files of the submitting machine
L="$TMP/local"; mkdir -p "$L"
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  resources:\n    data:\n      limits: {memory: 8Gi}\n' > "$L/mem.yaml"
printf 'backup:\n  fullRetention: 6\n' > "$L/retention.yaml"
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  highAvailability: {enabled: false}\n  storageSize: 10Gi\n' > "$L/ha.yaml"
printf 'backup:\n  additionalParameters: {process-max: "4"}\n' > "$L/ignored.yaml"
printf 'resources:\n  limits: {cpu: 500m, memory: 300Mi}\n' > "$L/op.yaml"
printf 'backup:\n  fullRetention: 9\n  scheduled: false\n' > "$L/sched.yaml"
printf 'operatorImage: myacr.azurecr.io/postgres-operator:v4.5.0\n' > "$L/op-image.yaml"
printf 'operatorImage: myacr.azurecr.io/postgres-operator:v4.6.0\ndockerRegistrySecretName: acr-pull\n' > "$L/op-bad.yaml"
pack() {  # pack FILE... -> patchFiles for the local files (keys as given)
  local out='{}' f
  for f in "$@"; do out="$(jq -c --arg p "$f" --arg b "$(base64 < "$L/${f#./}" | tr -d '\n')" '. + {($p): $b}' <<<"$out")"; done
  printf '%s' "$out"
}

# ---- stubs. S_DIFF 1: kubectl diff finds a change (default), 0: none
#             S_SYNC_FAIL  targets whose sync fails (operator, orders-db)
#             S_PR         merged | closed | timeout
#             S_EXPECT     ok | drift (app_expect_synced after the merge)
cat > "$TMP/prelude.sh" <<PRELUDE
export TPG_WORK="$TMP/work"
source "$ROOT/workflows/scripts/lib.sh"
source "$ROOT/workflows/scripts/patch-lib.sh"
CMAP_KEYS="$ROOT/workflows/params/cluster-map-keys.yaml"
set +e
git_clone() {
  rm -rf "\$1"; cp -r "$REPO" "\$1"; git -C "\$1" config user.email t@t; git -C "\$1" config user.name t
  git -C "\$1" remote add origin "$TMP/origin.git"; git -C "$TMP/origin.git" update-ref refs/heads/main "$BASE_SHA"
}
record() { printf '%s|%s|%s|%s\n' "\$1" "\$2" "\${3:-}" "\${4:-}" >> "$TMP/records"; printf '%s' "\$2" > "$TMP/result"; RESULT_RECORDED=1; }
record_entry() { printf '%s|%s|%s|%s\n' "\$1" "\$2" "\${3:-}" "\${4:-}" >> "$TMP/records"; }
_last() { grep -F "\$1|" "$TMP/records" 2>/dev/null | tail -n1; }
run_data() {
  case "\$1" in
    inventory) printf '[{"name":"c1","wave":0,"instances":[%s]}]' "\$(printf '{"name":"%s"},' \${S_INV:-orders-db} | sed 's/,\$//')" ;;
    *) local l; l="\$(_last "\$1")"; [[ -n "\$l" ]] || return 0
       jq -cn --arg s "\$(cut -d'|' -f2 <<<"\$l")" --arg d "\$(cut -d'|' -f4- <<<"\$l")" '{status:\$s, detail:\$d}' ;;
  esac
}
setting() { [[ "\$1" == fleetRevision ]] && echo main; }
appset_refresh() { :; }
use_cluster() { CLUSTER="\$1"; }
vault_secret() { echo x; }
log() { printf '%s\n' "\$*" >&2; }
# Git hosting
git_commit_push() { git -C "\$1" add -A -- "\${@:3}"; git -C "\$1" commit -qm "\$2"; git -C "\$1" push -qf origin HEAD:main; PUSHED_REVISION="\$(git -C "\$1" rev-parse HEAD)"; echo "commit \$PUSHED_REVISION \$2" >> "$TMP/calls"; }
git_push_head() { git -C "\$1" push -q origin HEAD:main || return 1; PUSHED_REVISION="\$(git -C "\$1" rev-parse HEAD)"; echo "push-head \$PUSHED_REVISION \$(git -C "\$1" log -1 --format=%s)" >> "$TMP/calls"; }
pr_open() { git -C "\$1" checkout -qb "\$4"; git -C "\$1" commit -qm "\$2"; PR_BRANCH="\$4"; PR_NUMBER=7; PR_URL=https://example/pr/7; PR_SHA="\$(git -C "\$1" rev-parse HEAD)"; git -C "\$1" push -qf origin "HEAD:refs/heads/\$4"; echo "pr-open \$4 \$PR_SHA" >> "$TMP/calls"; printf '%s' "\$5" > "$TMP/pr-body"; }
pr_wait() { echo "pr-wait \$1" >> "$TMP/calls"; case "\${S_PR:-merged}" in merged) PR_MERGE_SHA=feedface0000; return 0 ;; closed) return 1 ;; *) return 2 ;; esac; }
pr_close() { echo "pr-close \$1" >> "$TMP/calls"; }
# S_MERGED_EARLY=yes: a person merged the pull request before the step failed (fast-forward)
pr_merged() {
  [[ "\${S_MERGED_EARLY:-no}" == yes ]] || return 1
  git -C "$TMP/origin.git" update-ref refs/heads/main "\$PR_SHA"; PR_MERGE_SHA="\$PR_SHA"
}
app_sync_status() { echo "\${S_APP_SYNC:-OutOfSync}"; }
branch_delete() { echo "branch-delete \$2" >> "$TMP/calls"; }
# Argo CD
app_deployed_revision() { echo "prev-\$1"; }
app_sync_wait() {
  echo "sync \$*" >> "$TMP/calls"
  local t="\${1#tpg-c1-}"
  # S_SYNC_FAIL: the first sync of that target fails (the revert sync after it passes)
  if [[ " \${S_SYNC_FAIL:-} " == *" \$t "* && ! -f "$TMP/failed-\$t" ]]; then
    touch "$TMP/failed-\$t"
    [[ "\${S_SHARED:-}" != yes ]] || bash "$TMP/shared.sh"
    SYNC_FAIL_REASON=SYNC_FAILED; SYNC_FAIL_DETAIL="\$1: sync failed (stub)"; return 1
  fi
  return 0
}
app_exists() { return 0; }
app_expect_synced() { echo "expect \$1" >> "$TMP/calls"; [[ "\${S_EXPECT:-ok}" == ok ]] && return 0; SYNC_FAIL_DETAIL="\$1 stays OutOfSync (stub)"; return 1; }
ferret_follow() { FERRET_DETAIL=""; return 0; }
exposure_follow() { EXPOSURE_DETAIL="ClusterIP"; return 0; }
busy_operations() { :; }
# the operator chart (registry): a Deployment with the effective values
patch_operator_render() {
  local eff="\$REPO/\$(operator_effective_rel "\$1")"
  { printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata: {name: postgres-operator}\nspec:\n  template:\n    spec:\n      containers:\n        - name: operator\n'
    [[ -f "\$eff" ]] && printf '          resources: %s\n' "\$(yq -o=json -I=0 '.resources // {}' "\$eff")"; } > "\$2"
}
tk() {
  case "\$*" in
    *readyz*) return 0 ;;
    *"--dry-run=server"*) cat >> "$TMP/dryrun.yaml"; echo "applied (server dry run)" ;;
    *" diff "*) cat > "$TMP/diff-in.json"; [[ "\${S_DIFF:-1}" == 1 ]] && { echo "--- live"; echo "+++ merged"; return 1; }; return 0 ;;
    *"get postgres "*) [[ "\$*" == *jsonpath* ]] && printf 'postgres-17.6'; return 0 ;;
    *"get secret acr-pull"*) return 1 ;;
    *) return 0 ;;
  esac
}
PRELUDE
for s in patch-plan patch-cluster; do
  sed -e "s#^source /scripts/lib.sh#source $TMP/prelude.sh#" -e "s#^source /scripts/patch-lib.sh#:#" \
      -e "s#/tmp/pull-request#$TMP/pull-request#" "$ROOT/workflows/scripts/$s.sh" > "$TMP/$s.sh"
done
reset() { rm -rf "$TMP/work"; : > "$TMP/records"; : > "$TMP/dryrun.yaml"; : > "$TMP/calls"; }
plan() {  # plan VAR=VALUE...: patch-plan.sh in the local directory
  reset
  OUT="$(cd "$L" && env P_PUSH_MODE=direct "$@" bash "$TMP/patch-plan.sh" wf 2>&1)" || true
}
cluster() {  # cluster VAR=VALUE...: patch-cluster.sh c1 (keeps the records of the plan)
  rm -rf "$TMP/work/repo" "$TMP/work/render" "$TMP"/failed-*; : > "$TMP/calls"
  OUT="$(cd "$L" && env "$@" bash "$TMP/patch-cluster.sh" wf c1 600 2>&1)" || true
}
rec() { grep -F "$1" "$TMP/records" || true; }
calls() { cat "$TMP/calls"; }

# ==== patch-plan.sh
echo "== 1 plan: apply through the inputs"
PF="$(pack ./mem.yaml retention.yaml)"
plan P_CLUSTERS=c1 P_INSTANCES=orders-db P_POSTGRES_PATCH=./mem.yaml P_VALUES_PATCH=retention.yaml P_PATCH_FILES="$PF"
names="$(rec "patch.names|SET" | cut -d'|' -f4-)"
jq -e '(.["mem.yaml"] | test("^charts/tpg-instance/patches/mem-[a-z0-9]{5}\\.yaml$"))
       and (.["retention.yaml"] | test("^charts/tpg-instance/patches/retention-[a-z0-9]{5}\\.yaml$"))' <<<"$names" >/dev/null \
  && ok "1 each received file gets its stored name <name>-<uid>.yaml (./ dropped)" || bad "1 names" "$names $OUT"
rec "precheck.c1|PASSED" | grep -q "to sync: orders-db" && rec "plan.c1|PLANNED" | grep -q '"instances":\["orders-db"\]' \
  && ok "1 the cluster passes and is planned with its changed instance" || bad "1 precheck" "$(cat "$TMP/records") $OUT"
yq -e 'select(.kind == "Postgres") | .spec.resources.data.limits.memory == "8Gi"' "$TMP/dryrun.yaml" >/dev/null \
  && yq -e 'select(.kind == "PostgresBackupLocation") | .spec.retentionPolicy.fullRetention.number == 6' "$TMP/dryrun.yaml" >/dev/null \
  && ok "1 the dry run carries the new current files (the old values patch is replaced)" || bad "1 dry run" "$(cat "$TMP/dryrun.yaml")"
grep -q "diff c1/orders-db (tpg-c1-orders-db)" <<<"$OUT" && grep -q '^+++ merged' <<<"$OUT" \
  && ok "1 the diff is printed in the step log" || bad "1 diff log" "$OUT"
jq -e '.items[] | select(.kind == "Postgres") | .metadata.annotations["argocd.argoproj.io/tracking-id"] == "tpg-c1-orders-db:sql.tanzu.vmware.com/Postgres:pg-orders-db/orders-db"' "$TMP/diff-in.json" >/dev/null \
  && ok "1 the diffed objects carry the Argo CD tracking annotation (only the sync's change shows)" || bad "1 tracking" "$(head -c 600 "$TMP/diff-in.json")"
! calls | grep -q commit && rec "result.git|SUCCEEDED|PLANNED" | grep -q . \
  && ok "1 nothing is committed by the plan" || bad "1 no commit" "$(calls)"

echo "== 2 plan: no difference"
plan P_CLUSTERS=c1 P_INSTANCES=orders-db P_VALUES_PATCH=retention.yaml P_PATCH_FILES="$(pack retention.yaml)" S_DIFF=0
rec "precheck.c1|NO_CHANGE" | grep -q . && rec "result.c1.orders-db|SUCCEEDED|NO_CHANGE" | grep -q . && ! rec "plan.c1" | grep -q . \
  && ok "2 no difference: NO_CHANGE, the cluster is not planned" || bad "2 no change" "$(cat "$TMP/records")"

plan P_CLUSTERS=c1 P_INSTANCES=orders-db P_VALUES_PATCH=sched.yaml P_PATCH_FILES="$(pack sched.yaml)" S_DIFF=0
rec "precheck.c1|PASSED" | grep -q "to commit only (nothing changes on the cluster): orders-db" && rec "plan.c1|PLANNED" | grep -q . \
  && ! rec "result.c1.orders-db|SUCCEEDED|NO_CHANGE" | grep -q . \
  && ok "2 only backup.scheduled changes (read by the workflows, not rendered): planned to commit, not NO_CHANGE" || bad "2 hub only" "$(cat "$TMP/records") $OUT"
cluster P_PUSH_MODE=direct P_VALUES_PATCH=sched.yaml P_INSTANCES=orders-db P_CLUSTERS=c1 P_PATCH_FILES="$(pack sched.yaml)" S_DIFF=0
calls | grep -q "^commit .* patch c1: orders-db (wf)" && ! calls | grep -q "^sync " \
  && rec "result.c1.orders-db|SUCCEEDED" | grep -q "nothing to sync: only values the workflows read changed (backup.scheduled=false)" \
  && ok "2 it is committed and not synced" || bad "2 hub only commit" "$(calls) $(cat "$TMP/records") $OUT"

want="$(yq -o=json -I=0 '[.spec.template.spec.ignoreDifferences[] | {(.kind): [.jsonPointers[] | sub("^/"; "") | split("/")]}] | .[0] * .[1]' "$ROOT/bootstrap/appsets/tpg-instances.yaml" 2>/dev/null)"
got="$(bash -c "source '$ROOT/workflows/scripts/patch-lib.sh' 2>/dev/null; printf '%s' \"\$PATCH_IGNORED_PATHS\"" | jq -c .)"
[[ -n "$want" ]] && [[ "$(jq -cS . <<<"$want")" == "$(jq -cS . <<<"$got")" ]] \
  && ok "2 the diff ignores the fields the tpg-instances ApplicationSet ignores" || bad "2 ignored paths" "want $want got $got"
list='{"apiVersion":"v1","kind":"List","items":[{"kind":"PostgresBackupLocation","metadata":{"name":"b"},"spec":{"storage":{"azure":{"enableSSL":false,"container":"x"}}}},{"kind":"Postgres","metadata":{"name":"p"},"spec":{"postgresVersion":{"name":"postgres-17.6"},"storageSize":"5Gi"}}]}'
got="$(bash -c "source '$ROOT/workflows/scripts/patch-lib.sh' 2>/dev/null
  tk() { case \"\$*\" in *PostgresBackupLocation*) echo '{\"spec\":{\"storage\":{\"azure\":{\"container\":\"x\"}}}}' ;; *Postgres*) echo '{\"spec\":{\"postgresVersion\":{\"name\":\"postgres-17.7\"}}}' ;; esac; }
  patch_ignore_live pg-x" <<<"$list" | jq -c '[.items[0].spec.storage.azure, .items[1].spec]')"
[[ "$got" == '[{"container":"x"},{"postgresVersion":{"name":"postgres-17.7"},"storageSize":"5Gi"}]' ]] \
  && ok "2 an ignored field takes the live value, or goes when the live object has none" || bad "2 patch_ignore_live" "$got"

echo "== 3 plan: refusals that need the fleet or the cluster"
plan P_CLUSTERS=c1 P_INSTANCES=orders-db P_POSTGRES_PATCH=ha.yaml P_PATCH_FILES="$(pack ha.yaml)"
r="$(rec "precheck.c1|BLOCKED|PATCH_REFUSED")"
grep -q "ha.yaml: spec.highAvailability is changed by tpg-scale-instance" <<<"$r" \
  && grep -q "spec.storageSize 10Gi is smaller than the current 50Gi" <<<"$r" \
  && rec "result.c1.orders-db|FAILED|PATCH_REFUSED" | grep -q . \
  && ok "3 fields other workflows own, and a smaller volume, are refused" || bad "3 guarded" "$r $OUT"
plan P_CLUSTERS=c1 P_INSTANCES=orders-db P_VALUES_PATCH=ignored.yaml P_PATCH_FILES="$(pack ignored.yaml)"
rec "precheck.c1|BLOCKED" | grep -q "backup.additionalParameters is ignored by Argo CD on a running instance" \
  && ok "3 a value tpg-instances ignores on a running instance is refused" || bad "3 ignored" "$(cat "$TMP/records")"
plan P_CLUSTERS=c1 P_INSTANCES=orders-db P_VALUES_PATCH=retention.yaml P_PATCH_FILES='{}'
rec "precheck.c1|BLOCKED" | grep -q "retention.yaml: the file was not received (patchFiles)" \
  && ok "3 a file without contents is refused" || bad "3 no contents" "$(cat "$TMP/records") $OUT"
plan P_CLUSTERS=c1 P_OPERATOR_VALUES_PATCH=op-bad.yaml P_PATCH_FILES="$(pack op-bad.yaml)"
r="$(rec "precheck.c1|BLOCKED")"
grep -q "operatorImage tag v4.6.0 differs from the operator version v4.5.0 of c1" <<<"$r" \
  && grep -q "dockerRegistrySecretName acr-pull: no Secret tanzu-postgres-operator/acr-pull on c1" <<<"$r" \
  && ok "3 operator: another version in operatorImage, a pull Secret that does not exist" || bad "3 operator" "$r $OUT"
plan P_CLUSTERS=c1 P_OPERATOR_VALUES_PATCH=op-image.yaml P_PATCH_FILES="$(pack op-image.yaml)"
rec "precheck.c1|PASSED" | grep -q "to sync: operator" \
  && ok "3 operator: operatorImage from another registry with the running tag passes" || bad "3 registry" "$(cat "$TMP/records") $OUT"

echo "== 4 plan: patchMode=clear and the version guard"
plan P_CLUSTERS=c1 P_INSTANCES=orders-db P_VALUES_PATCH=charts/tpg-instance/patches/other-zz99z.yaml P_PATCH_MODE=clear
rec "precheck.c1|BLOCKED" | grep -q "patchMode=clear: charts/tpg-instance/patches/other-zz99z.yaml is not the current values patch of c1/orders-db (current: patches/old-ab12c.yaml)" \
  && ok "4 clear names the current file, or is refused with the current one" || bad "4 clear wrong" "$(cat "$TMP/records")"
plan P_CLUSTERS=c1 P_INSTANCES=orders-db P_VALUES_PATCH=charts/tpg-instance/patches/old-ab12c.yaml P_PATCH_MODE=clear
rec "precheck.c1|PASSED" | grep -q . && ! rec "patch.names" | grep -q . \
  && ok "4 clear of the current file is planned; no file is stored" || bad "4 clear" "$(cat "$TMP/records") $OUT"
plan P_CLUSTER_MAP='c1: {instances: {billing-db: {postgresVersion: "16.9", valuesPatchFilePath: retention.yaml}}}' P_PATCH_FILES="$(pack retention.yaml)" S_INV=billing-db
rec "result.c1.billing-db|SKIPPED_VERSION_MISMATCH" | grep -q "postgres-16.9" && ! rec "plan.c1" | grep -q . \
  && ok "4 an instance that runs another version is skipped" || bad "4 guard" "$(cat "$TMP/records") $OUT"

# ==== patch-cluster.sh
echo "== 5 cluster: pushMode=direct"
plan P_CLUSTERS=c1 P_INSTANCES=orders-db P_VALUES_PATCH=retention.yaml P_PATCH_FILES="$(pack retention.yaml)"
stored="$(rec "patch.names|SET" | cut -d'|' -f4- | jq -r '.["retention.yaml"]')"
cluster P_PUSH_MODE=direct P_VALUES_PATCH=retention.yaml P_INSTANCES=orders-db P_CLUSTERS=c1 P_PATCH_FILES="$(pack retention.yaml)"
W="$TMP/work/repo"
sha="$(git -C "$W" log -1 --format=%H)"
calls | grep -q "^commit ${sha} patch c1: orders-db (wf)" \
  && git -C "$W" show --name-only --format= HEAD | grep -qx "$stored" \
  && ok "5 one commit on the fleet branch with the stored file and clusters/fleet.yaml" || bad "5 commit" "$(calls) $OUT"
[[ "$(yq -r '.clusters.c1.instances["orders-db"].patches.values.current' "$W/clusters/fleet.yaml")" == "${stored#charts/tpg-instance/}" ]] \
  && [[ "$(yq -r '.clusters.c1.instances["orders-db"].patches.values.previous.path' "$W/clusters/fleet.yaml")" == "patches/old-ab12c.yaml" ]] \
  && [[ "$(yq -r '.clusters.c1.instances["orders-db"].patches.values.previous.commit' "$W/clusters/fleet.yaml")" == "$BASE_SHA" ]] \
  && ok "5 current is the new file; previous is the Round 11 file with the commit that added it" || bad "5 refs" "$(yq '.clusters.c1.instances["orders-db"].patches' "$W/clusters/fleet.yaml")"
calls | grep -q "^sync tpg-c1-orders-db 600 --revision ${sha} .*--prune" && ! calls | grep -q -- "--off-branch" \
  && rec "result.c1.orders-db|SUCCEEDED" | grep -q "synced at ${sha:0:12}" \
  && ok "5 the instance is synced at the commit (prune) and SUCCEEDED" || bad "5 sync" "$(calls) $(cat "$TMP/records")"

echo "== 6 cluster: pushMode=direct, the sync fails: a revert commit"
cluster P_PUSH_MODE=direct P_VALUES_PATCH=retention.yaml P_INSTANCES=orders-db P_CLUSTERS=c1 P_PATCH_FILES="$(pack retention.yaml)" S_SYNC_FAIL=orders-db
rsha="$(git -C "$TMP/work/repo" log -1 --format=%H)"
git -C "$TMP/work/repo" log -1 --format=%s | grep -q '^Revert "patch c1: orders-db (wf)"' \
  && calls | grep -q "^push-head ${rsha}" \
  && [[ "$(yq -o=json -I=0 '.clusters.c1.instances["orders-db"].patches.values' "$TMP/work/repo/clusters/fleet.yaml")" == '["patches/old-ab12c.yaml"]' ]] \
  && ok "6 the commit is reverted on the fleet branch (fleet.yaml and the stored file as before)" || bad "6 revert" "$(calls) $OUT"
calls | grep -q "^sync tpg-c1-orders-db 600 --revision ${rsha}" && rec "result.c1.orders-db|FAILED|SYNC_FAILED" | grep -q "reverted: orders-db synced at the revert" \
  && ok "6 the instance is synced at the revert and FAILED with the sync reason" || bad "6 revert sync" "$(calls) $(cat "$TMP/records")"

# S_SHARED=yes: while c1 syncs, another cluster's commit (rebased onto c1's, so it
# does not add the stored file again) starts to use the same stored file
cat > "$TMP/shared.sh" <<'SH'
set -e
d="$(mktemp -d)"; git clone -q "$ORIGIN" "$d/r"; cd "$d/r"
f="$(git show --name-only --format= HEAD | grep '^charts/tpg-instance/patches/retention-')"
F="${f#charts/tpg-instance/}" yq -i '.clusters = ({"c2": {"instances": {"orders-db": {"patches": {"values": {"current": strenv(F)}}}}}} + .clusters)' clusters/fleet.yaml
git -c user.email=t@t -c user.name=t commit -qam "patch c2: orders-db (wf)"; git push -q origin HEAD:main
SH
cluster P_PUSH_MODE=direct P_VALUES_PATCH=retention.yaml P_INSTANCES=orders-db P_CLUSTERS=c1 P_PATCH_FILES="$(pack retention.yaml)" S_SYNC_FAIL=orders-db S_SHARED=yes ORIGIN="$TMP/origin.git"
g="$TMP/shared-check"; rm -rf "$g"; git clone -q "$TMP/origin.git" "$g"
f="$(yq -r '.clusters.c2.instances["orders-db"].patches.values.current' "$g/clusters/fleet.yaml")"
git -C "$g" log -1 --format=%s | grep -q '^Revert "patch c1: orders-db (wf)"' && [[ -f "$g/charts/tpg-instance/$f" ]] \
  && [[ "$(yq -o=json -I=0 '.clusters.c1.instances["orders-db"].patches.values' "$g/clusters/fleet.yaml")" == '["patches/old-ab12c.yaml"]' ]] \
  && ok "6 the revert keeps a stored file another cluster of the run still names" || bad "6 shared file" "$(git -C "$g" show --stat HEAD) $OUT"

echo "== 7 cluster: pushMode=pr, merged"
cluster P_PUSH_MODE=pr P_VALUES_PATCH=retention.yaml P_INSTANCES=orders-db P_CLUSTERS=c1 P_PATCH_FILES="$(pack retention.yaml)" S_PR=merged
psha="$(calls | awk '/^pr-open/ {print $3}')"
calls | grep -q "^pr-open tpg/patch/wf/c1 " && calls | grep -q "^sync tpg-c1-orders-db 600 --revision ${psha} .*--off-branch" \
  && ok "7 a branch and pull request per cluster; the instance is synced at the branch commit before the merge" || bad "7 pr sync" "$(calls) $OUT"
grep -q "synced to the cluster from this branch before the merge" "$TMP/pr-body" && grep -q '^+++ merged' "$TMP/pr-body" \
  && ok "7 the pull request body says so and carries the diff" || bad "7 body" "$(cat "$TMP/pr-body")"
[[ "$(calls | grep -n '' | grep -E 'sync tpg-c1|pr-wait|expect' | cut -d: -f2 | awk '{print $1}' | paste -sd' ')" == "sync pr-wait expect" ]] \
  && ! calls | grep -q -- "--revision prev-" \
  && rec "result.c1.orders-db|SUCCEEDED" | grep -q "merged as feedface0000 (pull request #7)" \
  && ok "7 sync, then the merge, then Synced at the fleet branch head without a second sync" || bad "7 order" "$(calls) $(cat "$TMP/records")"

echo "== 8 cluster: pushMode=pr, closed or not merged in time"
cluster P_PUSH_MODE=pr P_VALUES_PATCH=retention.yaml P_INSTANCES=orders-db P_CLUSTERS=c1 P_PATCH_FILES="$(pack retention.yaml)" S_PR=closed
calls | grep -q "^sync tpg-c1-orders-db 600 --revision prev-tpg-c1-orders-db .*--off-branch" \
  && calls | grep -q "^pr-close 7" && calls | grep -q "^branch-delete tpg/patch/wf/c1" \
  && rec "result.c1.orders-db|FAILED|PR_NOT_MERGED" | grep -q "closed without merging" \
  && ok "8 closed: synced back at the commit it ran before, pull request closed, branch deleted" || bad "8 closed" "$(calls) $(cat "$TMP/records")"
cluster P_PUSH_MODE=pr P_VALUES_PATCH=retention.yaml P_INSTANCES=orders-db P_CLUSTERS=c1 P_PATCH_FILES="$(pack retention.yaml)" S_PR=timeout P_PR_TIMEOUT=5
rec "result.c1.orders-db|FAILED|PR_NOT_MERGED" | grep -q "not merged within 5s" && calls | grep -q "^branch-delete" \
  && ok "8 not merged in time: the same revert" || bad "8 timeout" "$(calls) $(cat "$TMP/records")"
cluster P_PUSH_MODE=pr P_VALUES_PATCH=retention.yaml P_INSTANCES=orders-db P_CLUSTERS=c1 P_PATCH_FILES="$(pack retention.yaml)" S_SYNC_FAIL=orders-db
! calls | grep -q "^pr-wait" && calls | grep -q "^branch-delete" && rec "result.c1.orders-db|FAILED|SYNC_FAILED" | grep -q . \
  && ok "8 a failed sync reverts at once; nobody is asked to merge" || bad "8 sync fail" "$(calls) $(cat "$TMP/records")"
cluster P_PUSH_MODE=pr P_VALUES_PATCH=retention.yaml P_INSTANCES=orders-db P_CLUSTERS=c1 P_PATCH_FILES="$(pack retention.yaml)" S_EXPECT=drift
rec "result.c1.orders-db|FAILED|MERGED_CONTENT_DIFFERS" | grep -q "stays OutOfSync" && ! calls | grep -q "^branch-delete" \
  && ok "8 merged but the fleet branch renders other objects: FAILED, nothing reverted" || bad "8 drift" "$(calls) $(cat "$TMP/records")"

cluster P_PUSH_MODE=pr P_VALUES_PATCH=retention.yaml P_INSTANCES=orders-db P_CLUSTERS=c1 P_PATCH_FILES="$(pack retention.yaml)" S_PR=closed S_APP_SYNC=Synced
calls | grep -q "^sync tpg-c1-orders-db 600 --revision ${BASE_SHA} .*--off-branch" \
  && ok "8 an Application that was Synced goes back to the fleet branch head, not to its history" || bad "8 back to BASE" "$(calls)"
cluster P_PUSH_MODE=pr P_VALUES_PATCH=retention.yaml P_INSTANCES=orders-db P_CLUSTERS=c1 P_PATCH_FILES="$(pack retention.yaml)" S_SYNC_FAIL=orders-db S_MERGED_EARLY=yes
psha="$(calls | awk '/^pr-open/ {print $3}')"
head="$(git -C "$TMP/origin.git" rev-parse main)"
[[ "$(calls | grep -n '' | grep -E 'pr-close|push-head' | cut -d: -f2 | awk '{print $1}' | paste -sd' ')" == "pr-close push-head" ]] \
  && git -C "$TMP/origin.git" log -1 --format=%s main | grep -q '^Revert "patch c1: orders-db (wf)"' \
  && [[ "$(git -C "$TMP/origin.git" rev-parse "${head}^")" == "$psha" ]] \
  && calls | grep -q "^sync tpg-c1-orders-db 600 --revision ${head}" \
  && rec "result.c1.orders-db|FAILED|SYNC_FAILED" | grep -q "was merged before the failure" \
  && ok "8 merged before the failure: closed first, then the merge is reverted on the fleet branch and synced" || bad "8 merged early" "$(calls) $OUT"

echo "== 9 cluster: the operator"
plan P_CLUSTERS=c1 P_OPERATOR_VALUES_PATCH=op.yaml P_PATCH_FILES="$(pack op.yaml)"
cluster P_PUSH_MODE=pr P_OPERATOR_VALUES_PATCH=op.yaml P_CLUSTERS=c1 P_PATCH_FILES="$(pack op.yaml)"
W="$TMP/work/repo"; cur="$(yq -r '.clusters.c1.operator.patches.values.current' "$W/clusters/fleet.yaml")"
[[ "$cur" =~ ^patches/operator/op-[a-z0-9]{5}\.yaml$ ]] \
  && [[ "$(yq -o=json -I=0 . "$W/patches/operator/clusters/c1.yaml")" == "$(yq -o=json -I=0 . "$W/$cur")" ]] \
  && git -C "$W" show --name-only --format= HEAD | grep -qx "patches/operator/clusters/c1.yaml" \
  && ok "9 the stored file is current and its copy patches/operator/clusters/c1.yaml is committed with it" || bad "9 effective" "$(git -C "$W" show --stat HEAD) $OUT"
psha="$(calls | awk '/^pr-open/ {print $3}')"
calls | grep -q "^sync tpg-c1-operator 600 --revisions 2 ${psha} --pods tanzu-postgres-operator  --ready-fn _operator_ready --off-branch" \
  && ok "9 the operator Application is synced with its fleet source (position 2) at the branch commit" || bad "9 operator sync" "$(calls)"

echo "== 10 cluster: no difference any more on the fleet branch head"
plan P_CLUSTERS=c1 P_INSTANCES=orders-db P_VALUES_PATCH=retention.yaml P_PATCH_FILES="$(pack retention.yaml)"
cluster P_PUSH_MODE=direct P_VALUES_PATCH=retention.yaml P_INSTANCES=orders-db P_CLUSTERS=c1 P_PATCH_FILES="$(pack retention.yaml)" S_DIFF=0
! calls | grep -qE "^(commit|pr-open|sync)" && rec "result.c1.orders-db|SUCCEEDED|NO_CHANGE" | grep -q . \
  && ok "10 nothing committed or synced when the step finds no difference" || bad "10 no change" "$(calls) $(cat "$TMP/records")"

echo "== 11 clear, and a Round 11 list of several files"
plan P_CLUSTERS=c1 P_INSTANCES=orders-db P_VALUES_PATCH=charts/tpg-instance/patches/old-ab12c.yaml P_PATCH_MODE=clear
cluster P_PUSH_MODE=direct P_VALUES_PATCH=charts/tpg-instance/patches/old-ab12c.yaml P_PATCH_MODE=clear P_INSTANCES=orders-db P_CLUSTERS=c1
W="$TMP/work/repo"
[[ "$(yq -o=json -I=0 '.clusters.c1.instances["orders-db"].patches.values' "$W/clusters/fleet.yaml")" == "{\"previous\":{\"path\":\"patches/old-ab12c.yaml\",\"commit\":\"${BASE_SHA}\"}}" ]] \
  && rec "result.c1.orders-db|SUCCEEDED" | grep -q . \
  && ok "11 clear: no current file any more, the cleared one is previous; committed and synced" || bad "11 clear" "$(yq '.clusters.c1.instances["orders-db"].patches' "$W/clusters/fleet.yaml") $(cat "$TMP/records")"
cp "$REPO/clusters/fleet.yaml" "$TMP/fleet.saved"
yq -i '.clusters.c1.instances["orders-db"].patches.values = ["patches/old-ab12c.yaml", "patches/other.yaml"]' "$REPO/clusters/fleet.yaml"
plan P_CLUSTERS=c1 P_INSTANCES=orders-db P_VALUES_PATCH=retention.yaml P_PATCH_FILES="$(pack retention.yaml)"
rec "precheck.c1|BLOCKED" | grep -q "patches.values lists several files (Round 11); Round 14 applies one current file" \
  && ok "11 a Round 11 list of several files is refused with the migration note" || bad "11 list" "$(cat "$TMP/records")"
cp "$TMP/fleet.saved" "$REPO/clusters/fleet.yaml"

echo
echo "tests/patch: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
