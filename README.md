# tpg-fleet

GitOps repository for the **Tanzu for Postgres on AKS GitOps POC**. Argo CD reads this repository to deploy the Tanzu for Postgres operator and Postgres instances to every target AKS cluster. Argo Workflows on the hub runs the ordered, gated Day 0 and Day 1 operations defined here.

The Azure infrastructure, the Argo installation and the cluster prerequisites live in the companion repository `tpg-aks-infra`.

## Pinned versions

| Component | Version | Where |
|---|---|---|
| Tanzu for Postgres operator chart | v4.5.0 | `clusters/fleet.yaml` (`clusters.<cluster>.operator.version`, written by `tpg-day0`) |
| Argo CD / chart | v3.5.3 / 10.9.1 | `tpg-aks-infra/argo` |
| Argo Workflows / chart | v4.1.3 / 2.0.6 | `tpg-aks-infra/argo` |
| cert-manager chart | v1.21.2 | `workflows/scripts/helm-addons.sh` (Helm release `cert-manager`) |
| kube-state-metrics chart | 8.5.0 | `bootstrap/monitoring/azure`, `workflows/scripts/helm-addons.sh` (standalone) |
| kube-prometheus-stack chart | 91.4.0 | `workflows/scripts/helm-addons.sh` (Helm release `kps`, standalone) |
| HashiCorp Vault / chart | 2.0.4 / 0.34.1 | `workflows/scripts/helm-addons.sh` (Helm release `vault`, hub), `vault/vault-values.yaml` |
| Vault Secrets Operator chart | 1.5.1 | `workflows/scripts/helm-addons.sh` (Helm release `vault-secrets-operator`) |
| Remote-write gateway image | `nginxinc/nginx-unprivileged:1.27-alpine` | `monitoring/standalone/hub/remote-write-gateway.yaml` (standalone monitoring) |
| Workflow tools image | `alpine/k8s:1.35.8` | `toolsImage` parameter of every WorkflowTemplate |
| Azure CLI image | `mcr.microsoft.com/azure-cli:2.90.0` | `azCliImage` parameter of `tpg-rotate-credential` |

## Repository layout

```text
tpg-fleet/
  bootstrap/
    project-tpg.yaml                 AppProject tpg (the target Applications; only workflow-bot syncs them)
    project-tpg-hub.yaml             AppProject tpg-hub (hub Applications, hub destination only)
    app-hub-workflows.yaml           Hub Application for workflows/ (project tpg-hub, automated sync)
    appsets/                         platform, operator (multi-source: OCI chart + fleet value files),
                                     instances (manual sync)
    monitoring/azure/                Option A: kube-state-metrics + azmonitoring monitors
  platform/base/                     StorageClass tpg-data-retain (disk SKU from Terraform, Retain;
                                     the tpg-platform ApplicationSet patches skuName per cluster),
                                     regsecret for the operator namespace (from Vault)
  vault/                             Helm values, server config (shamir and azure-keyvault),
                                     VaultConnection/VaultAuth, policies (tpg-admin, tpg-workflow,
                                     tpg-argocd, tpg-target)
  charts/tpg-instance/               Postgres + PostgresBackupLocation (Azure Blob; enableSSL from
                                     backup.enableSSL, default false; caBundle with true), Service
                                     exposure, NetworkPolicy tpg-ingress + CiliumNetworkPolicy tpg-egress
    patches/                         instance patch files, stored by tpg-patch and tpg-create-instance as
                                     <name>-<uid>.yaml, read by the chart with .Files.Get
  patches/operator/                  operator values files, stored by tpg-patch as <name>-<uid>.yaml
    clusters/<cluster>.yaml          the copy of a cluster's current file that the tpg-operator Application reads
  clusters/
    _template/cluster.yaml           cluster defaults for every cluster (maxReadReplicas, backup)
    _template/instance.yaml          instance defaults for every instance (sizes, HA, resources)
    fleet.yaml                       per cluster: operator.version, overrides, instances.<name> overrides,
                                     the current and previous patch file of each kind; ships empty (clusters: {})
    fleet.example.yaml               a filled-in example (not read by Argo CD or the workflows)
    deleted/<cluster>/<i>-<time>     instance entries removed by the delete workflows
  docs/
    workflow-commands.md             argo and argocd commands for every workflow: input types, clusterMap,
                                     examples
  workflows/
    kustomization.yaml               WorkflowTemplates, CronWorkflows, RBAC, admission policies,
                                     tpg-scripts ConfigMap
    rbac.yaml                        ServiceAccount tpg-workflow
    admission/                       ValidatingAdmissionPolicies: tpg-workflow-parameters (input types,
                                     generated), tpg-application-sync (only workflow-bot syncs target apps)
    params/                          types.yaml (input types) and generate.py; cluster-map-keys.yaml
                                     (the keys clusterMap accepts); patch-schemas.json (generated: what a
                                     patch file may contain)
    scripts/                         step scripts mounted at /scripts (helm-addons.sh is also run by tpg-aks-infra)
      common.sh                      shared with tpg-aks-infra scripts/lib/common.sh: retries, pod watch,
                                     Helm release pre-check, metrics flow check
      lib.sh                         workflow functions: run results, Git and pull requests, Vault, the Argo CD
                                     sync engine, clusterMap accessors, patch files (patchFiles, stored names)
      patch-lib.sh                   tpg-patch per cluster: store, check, render, server-side dry run, diff
      patchcheck.py                  a patch file against the input it was passed to (patch-schemas.json)
      clustermap.py                  clusterMap validation and normalization
    vault-agent/                     Vault Agent templates (ConfigMap tpg-vault-agent) for the workflow pods
    templates/                       tpg-lib, tpg-day0, tpg-create-instance, tpg-upgrade, tpg-patch,
                                     tpg-scale-instance, tpg-network-policy, tpg-backup,
                                     tpg-backup-retention, tpg-restore, tpg-rotate-credential,
                                     tpg-delete-instance, tpg-delete-apps, tpg-helm-addons
    cron/                            tpg-backup-full (Sun 00:00 UTC), tpg-backup-incr (Mon-Sat 00:00 UTC),
                                     tpg-backup-retention (daily 02:00 UTC)
  monitoring/
    ksm/values.yaml                  custom resource state metrics for Postgres, backups, restores
    azure/, standalone/              monitors, kube-prometheus-stack values, 5 dashboards, PrometheusRules,
                                     the hub remote-write gateway (standalone)
    grafana/                         generate.py, Grafana alert rules, Azure import script, SMTP examples
    prometheus/                      Alertmanager SMTP example
  scripts/                           set-repo-url.sh, validate.sh
    submit/                          interactive submit script per workflow (tpg-<workflow>.sh, submit-lib.sh),
                                     pack-patch-files.sh (the patchFiles input for a plain argo submit)
  tools/pgdata/pgdata.py             create databases and tables, insert random rows, read them back
  tests/
    cli-flags/                       flags the pinned CLIs no longer accept (rules.yaml, fixtures)
    helm4/                           helm-addons.sh end to end against a Helm 4 CLI (stub helm, kubectl)
    shared-lib/                      the shared common.sh block: identical in both repositories, retries, pod watch
    sync-engine/                     the Argo CD sync engine against a scripted Argo CD API
    rollout/                         rolloutMode (canary, batches, all) of the batch planner
    params/                          input types, generated policy, templates and docs agree
    cluster-map/                     clusterMap validation per workflow, the tpg-day0 version rule,
                                     patch file types
    scale/                           tpg-scale-instance: maxReadReplicas and the rollout
    patch/                           tpg-patch: stored files, checks, diff, pull request and direct flows, revert
    chart/                           instance chart: exposure, caBundle, network policy rendering
    day0-plan/                       tpg-day0 and tpg-create-instance planning, pre-check ownership, gate
    network-policy/                  tpg-network-policy planning (apply, update, remove, blocks)
    submit/                          the submit scripts through their numbered menus
    pgdata/                          pgdata.py against a throwaway local PostgreSQL
    admission/                       the admission policies on a real kube-apiserver
    envtest/                         starts etcd and kube-apiserver from the envtest binaries
    run-all.sh                       every suite, plus tpg-aks-infra/tests/verify and tests/argocd-rbac
                                     when it is a sibling
```

## One template for every cluster

There is no folder per cluster. Every cluster renders the same chart with the same two template files, and `clusters/fleet.yaml` holds only what differs:

```yaml
clusters:
  aks-tpg-poc-01:                  # registered cluster (Argo CD label tpg.fleet/managed=true)
    operator:
      version: v4.5.0              # required; tpg-day0 and tpg-upgrade write it
    cluster:
      maxReadReplicas: 5           # optional override of _template/cluster.yaml
    instances:
      orders-db:                   # namespace pg-orders-db, Application tpg-aks-tpg-poc-01-orders-db
        instance:
          postgresVersion: postgres-17.6
          highAvailability: {enabled: true, readReplicas: 2}
      billing-db:
        instance:
          postgresVersion: postgres-17.6
```

| Value | Source |
|---|---|
| Which clusters exist, and their wave | Cluster registration in `tpg-aks-infra` (Secret labels `tpg.fleet/managed`, `tpg.fleet/wave`) |
| Operator version, instances and their overrides | `clusters/fleet.yaml` |
| Defaults | `clusters/_template/cluster.yaml`, `clusters/_template/instance.yaml`, then `charts/tpg-instance/values.yaml` |
| `cluster.name`, backup container `pg-backups-<cluster>` | Set by the `tpg-instances` ApplicationSet |

The `tpg-operator` and `tpg-instances` ApplicationSets combine the registered clusters with `clusters/fleet.yaml` (matrix generator with a list generator per cluster). A registered cluster without an entry gets only `tpg-<cluster>-platform` until `tpg-day0` adds it. You normally never edit `fleet.yaml` by hand: the workflows write it, with `pushMode=direct` or `pushMode=pr`.

`clusters/fleet.yaml` ships empty (`clusters: {}`), because an entry declares what a cluster should run and an example left there would look like real state; `clusters/fleet.example.yaml` shows a filled-in file, including patch references. tpg-day0 compares its version inputs with what runs on each target, not with `fleet.yaml`: a version that nothing runs yet is replaced (`FLEET_OVERRIDDEN`), and a cluster that runs another version is blocked (`UPGRADE_REQUIRED`, `DOWNGRADE_NOT_ALLOWED`, `VERSION_UNKNOWN`) until tpg-upgrade moves it.

## Get started

These steps run **before** the first `tpg-aks-infra/scripts/run.sh`. That script
reads this repository from disk (`FLEET_LOCAL_DIR`), not from GitHub: its
`vault`, `addons` and `bootstrap` steps apply files from the clone and run
`workflows/scripts/helm-addons.sh` out of it. A clone that still carries the
`<org>` placeholder fails those steps after the clusters have been changed.

1. Create an empty private GitHub repository named `tpg-fleet`, and clone it
   next to `tpg-aks-infra` (the tests in either repository find the other one
   when they are siblings).

2. Set the repository URL everywhere:

   ```bash
   cd tpg-fleet
   ./scripts/set-repo-url.sh https://github.com/<your-org>/tpg-fleet.git
   git grep -n '<org>' || echo "no placeholders left"
   ```

3. Review `clusters/_template/*.yaml`. `clusters/fleet.yaml` starts empty; `tpg-day0` adds clusters and instances from its inputs.

4. Keep the scripts executable and run the checks. Neither needs a cluster:

   ```bash
   chmod +x scripts/*.sh scripts/submit/*.sh tools/pgdata/pgdata.py tests/run-all.sh tests/*/run.sh
   tests/run-all.sh        # CLI flags, Helm 4, shared library, sync engine, rollout modes, input types,
                           # clusterMap, tpg-patch, chart, Day 0 planning, network policy, submit
                           # scripts, pgdata, admission policies, server-side apply
   ./scripts/validate.sh   # yamllint, shellcheck, kustomize, helm lint/template, kubeconform
   ```

5. Push, so Argo CD and the workflows read the same content:

   ```bash
   git add -A && git commit -m "Set repository URL"
   git remote add origin https://github.com/<your-org>/tpg-fleet.git
   git push -u origin main
   ```

   The checked-out branch must be the one in `FLEET_REPO_REVISION` (`main` by default).

6. In `tpg-aks-infra`, set `env.sh` (`FLEET_LOCAL_DIR` points at this clone) and run `scripts/run.sh` for your scenario (hub with or without Argo; clusters from Terraform or pre-created). Its `addons` step installs the Helm add-ons and its `bootstrap` step applies `bootstrap/`.

### Helm 4

`toolsImage` is `alpine/k8s:1.35.8`, which ships **Helm 4**. Helm 4 removed
the `-a` flag from `helm list` (it lists every release state by default), renamed `--atomic` to
`--rollback-on-failure` and `--force` to `--force-replace`, takes a registry
domain without a path for `helm registry login`, and no longer runs an
executable path passed to `--post-renderer`. Both repositories are free of those
flags, and `tests/cli-flags` fails the build when one comes back. Commands here
work on Helm 3 and Helm 4 alike: the shared Helm helpers select release states with
`--deployed --failed --pending --superseded --uninstalled --uninstalling`
(`HR_LIST_ALL` in `workflows/scripts/common.sh`), which both versions accept.

## How delivery works

- **ApplicationSets** generate one Application per cluster and component: `tpg-<cluster>-platform`, `-operator`, and `tpg-<cluster>-<instance>`. They carry the labels `tpg.fleet/cluster`, `tpg.fleet/wave` and `tpg.fleet/component`.
- **Helm releases** outside Argo CD: `cert-manager` and `vault-secrets-operator` on every target, `vault` and `vault-secrets-operator` on the hub, and for standalone monitoring `kps` on the hub and `kps` + `tpg-ksm` on targets (`helm list -A`). Every install runs a pre-check first: an existing release of ours is compared (chart version and values) and upgraded, kept or skipped; a compatible foreign cert-manager or Vault Secrets Operator is reused; anything else blocks the run with what it found.
- **No automated sync** on those Applications. Workflows sync them through the Argo CD API as `workflow-bot`, cluster by cluster, canary first (or every cluster at once with `rolloutMode=all`).
- **Only the workflows sync the target Applications** (project `tpg`). Argo CD RBAC denies people `sync` (which also covers rollback), `override`, `update` and `delete` on `tpg/*` (a marked block in `policy.csv`, written by `tpg-aks-infra`). The hub admission policy `tpg-application-sync` refuses a new operation unless argocd-server writes it for `workflow-bot`, and refuses automated sync, which also covers a `kubectl edit`. Each workflow sync reports a sync started elsewhere as the warning `MANUAL_SYNC_DETECTED`. The hub Applications are in project `tpg-hub` and stay manageable.
- **Typed inputs.** Every WorkflowTemplate input has a type (`List`, `String`, `Boolean`, `Integer`, `Enum`, `Map`, ...) in `workflows/params/types.yaml`. The generated admission policy `tpg-workflow-parameters` rejects a Workflow whose inputs do not match, before it exists, with the input and its type in the message.
- **clusterMap.** day0, create-instance, upgrade, patch, scale, network-policy, backup, backup-retention, delete-instance and delete-apps take an optional `clusterMap` (YAML or JSON): the targets, with values per cluster and per instance. The keys, their types and the workflows that accept them are listed in `workflows/params/cluster-map-keys.yaml`; the validate step checks every key and suggests the closest one for a typo.
- **Patches from your machine, synced before the merge** (Round 14). `tpg-patch` changes settings no other workflow owns. You pass the relative path of a file on the machine that submits the run; its contents travel in the input `patchFiles` (the submit scripts fill it, `scripts/submit/pack-patch-files.sh` prints it), and the workflow stores it as `<name>-<uid>.yaml`. `fleet.yaml` records one current file per kind and target and the previous one with the commit that added it; only current is applied. The validate step refuses a file of the wrong kind (a Postgres manifest passed as values, and the reverse), unknown keys and Postgres fields, and operator values outside an allow-list of eight keys. The plan renders every target with helm, sends it through the API server with `--dry-run=server` and prints the diff; a target without a difference is not synced. Then, per cluster: with `pushMode=pr` a branch and pull request, the Applications synced at the branch commit before the merge (the instance chart reads `clusters/fleet.yaml` at the synced commit, the operator Application a fixed per-cluster copy of its values file), and a person merges it: the Applications then compare the fleet branch with the same objects and stay Synced without a second sync. A failed sync, a closed pull request or one not merged in time closes the pull request, syncs the cluster back and deletes the branch (a pull request merged before the failure is reverted on the fleet branch); with `pushMode=direct` a revert commit undoes it. Operator manifest patches (server-side apply as `tpg-patch`) were removed. Fields another workflow owns are refused with the name of that workflow.
- **One sync engine for every workflow** (`app_sync_wait` in `workflows/scripts/lib.sh`). It syncs the fleet commit the workflow pushed, follows only the operation its own request started, fails at once on a permanent error (admission webhook denied, invalid or immutable field) with Argo CD's message, syncs again with backoff on a transient one, and records `SUCCEEDED` only when the Application is Synced and the target is ready. Result reasons: `SYNC_REJECTED`, `SYNC_FAILED`, `SYNC_TIMEOUT`, `SYNC_DRIFT`, `SYNC_BUSY`, `HEALTH_TIMEOUT`, `POD_<REASON>`.
- **Health means Running.** Argo CD has a health check for the `Postgres` kind (`tpg-aks-infra/argo/argocd-values.yaml`): Healthy only when `status.currentState` is `Running`. While the workflows wait, they print the pods of the namespace every 5 seconds and stop at once when one cannot start (`CreateContainerConfigError`, `InvalidImageName`), or when `CrashLoopBackOff`, `ImagePullBackOff`, `Error` or `OOMKilled` lasts 60 seconds, or a pod stays unschedulable for 5 minutes; the failure prints the pod's events and logs.
- **The version of a running instance belongs to the PostgresVersionUpgrade.** The `tpg-instances` ApplicationSet ignores `Postgres spec.postgresVersion` (`RespectIgnoreDifferences=true`): Git records the version, a new instance is created with it, and `tpg-upgrade` changes it. Argo CD applying the field made the operator's admission webhook reject the sync while an upgrade was being finished.
- **API calls are retried.** Every `kubectl`, `helm`, `az` and Argo CD API call in the scripts goes through `tpg_retry` (`workflows/scripts/common.sh`): a timeout, a dropped connection or an HTTP 429/502/503/504 from the AKS API server is retried up to 5 times (5, 10, 20, 40 s); anything else fails at once.
- **Databases are never pruned.** Postgres resources carry `Prune=false,Delete=false`, and the Postgres CR sets `persistentVolumeClaimPolicy: retain`.
- **Zero defaults are not declared.** A field left out takes the same default on the API server or in the operator, so declaring `false`, `0`, `[]` or `{}` gains nothing, and it costs a diff wherever a writer drops the field: an Application that declares it compares a desired object holding the key with a live object that does not, and stays OutOfSync with a diff no sync can settle. That happened to `PostgresBackupLocation` (fields serialized with `omitempty`) and was reported for single-node instances (`highAvailability: {enabled: false, readReplicas: 0}`). Every object the fleet renders therefore leaves out a field that holds its zero default: the chart runs each object through `tpg.prune`, which reads the registry `charts/tpg-instance/files/zero-defaults.yaml`, generated from the 9 live CRDs and the defaults the 4.5 documentation gives (`tools/crd-defaults/generate.py`, `charts/crd-reference`). A required field is never left out, a field whose default is not zero (`enableSSL`, `backupSync`) is always written, and a parent left empty goes too. The Postgres spec carries `highAvailability` only for an HA instance (`enabled: true` with `readReplicas` 1 or more); `clusters/fleet.yaml` keeps `enabled: false` and `readReplicas: 0` explicit, because the template defaults are `true` and `1`. `highAvailability=true` with `readReplicas=0` is refused by every workflow, the admission policy and the chart. The objects the workflow scripts write inline (PostgresBackup, PostgresVersionUpgrade, PostgresRestore and the copied backup location) follow the same rule, and `tests/crd-reference` compares them with the reference templates. The `tpg-instances` ApplicationSet still lists `additionalParameters` and `forcePathStyle` under `ignoreDifferences` for clusters whose operator drops or adds them anyway.
- **highAvailability and readReplicas depend on each other.** `highAvailability=true` needs `readReplicas` 1 or more (empty means 1), and `readReplicas` above 0 needs `highAvailability=true`. tpg-day0 and tpg-create-instance refuse either mismatch in the validate step (and the admission policy and the submit scripts refuse it for the inputs) before anything changes, where both values are set: as inputs, or on one `clusterMap` entry. An input `readReplicas` is a default for HA instances only and does not apply to an entry that sets `highAvailability: false`. `fleet-day0.sh` refuses the same pairs again instead of turning a `readReplicas` above 0 into 0. tpg-scale-instance reads `clusters/fleet.yaml` in its validate step and refuses `replicas` above 0 with `enableHAIfNeeded=false` for an instance declared a single node (`HA_DISABLED`).
- **Upgrading to Round 14 (patch files).** Run `scripts/validate.sh` on the lab repository after the merge; it names what needs a change:
  - An entry with `operator.patches.manifests` (operator manifest patches were removed): move a change the chart values allow-list can express to an operator values file and apply it with tpg-patch, then delete the entry. The fields the removed `tpg-patch` field manager set stay on the live objects until that manager is released; for each patched object, apply a manifest with only its `apiVersion`, `kind` and `metadata` as that manager (for the operator Deployment: `kubectl -n tanzu-postgres-operator apply --server-side --field-manager=tpg-patch --force-conflicts -f -` with `{apiVersion: apps/v1, kind: Deployment, metadata: {name: postgres-operator, namespace: tanzu-postgres-operator}}`), which removes the fields only that manager owned; the next operator sync takes back the ones the chart sets (lab item V67).
  - An operator `patches.values` list: the operator Application no longer reads it. With one file, copy it to `patches/operator/clusters/<cluster>.yaml` (`scripts/validate.sh` checks the copy) or apply it again with tpg-patch; with more than one, merge them into one file and apply that.
  - An instance `patches.postgres` or `patches.values` list of more than one file fails the render: merge them into one file and apply it with tpg-patch. A list of one file keeps working as the current file.
  - Operator values files that set keys outside the allow-list (or `operatorImage` with another tag) are refused when they are applied again.
- **`clusters/fleet.yaml` is block YAML.** Every commit of the file by a workflow turns flow maps and lists into block YAML: the tpg-day0 and tpg-create-instance commit copied each cluster from the JSON plan as is, which put JSON into the file. The first commit after this change also converts the entries written that way before. Quotes stay only where YAML needs them, and `caBundle` stays a literal block.
- **Upgrading from Round 12 (existing instances).** Nothing changes in how a running instance behaves: every field the chart now leaves out holds the value the API server or the operator uses when the field is absent. The first workflow sync of each instance Application after the merge removes them from the desired state only, and a single-node instance that stayed OutOfSync becomes Synced (lab item V58: `argocd app diff tpg-<cluster>-<instance>` before and after). One entry needs a change first: `highAvailability: {enabled: true, readReplicas: 0}`, which `tpg-scale-instance replicas=0` wrote before Round 13, no longer renders. `scripts/validate.sh` names such entries; run `tpg-scale-instance` for each with `replicas=0` (single node, the shape the 4.5 documentation uses) or `replicas=1` before any other workflow syncs that Application.
- **Backups by the operator, if you prefer.** `backupSchedule=operator` (tpg-day0, tpg-create-instance) takes the instance out of the backup CronWorkflows (`backup.scheduled: false`) and renders two PostgresBackupSchedule objects with the instance: `<instance>-backup-full` on `operatorFullSchedule` (default `0 0 * * 0`) and `<instance>-backup-incremental` on `operatorIncrementalSchedule` (default `0 0 * * 1-6`; empty for none), in UTC. `tpg-backup-retention` expires their backups by chain like any other. A later change goes through a tpg-patch values file. A tpg-day0 re-run writes `backupSchedule` as well (default `fleet`): repeat `backupSchedule=operator` for such instances, or the entry returns to the CronWorkflows and the sync removes the schedules.
- **FerretDB (Tech Preview).** `ferret=true` (tpg-day0, tpg-create-instance) renders a PostgresFerretDocumentDB named like the instance: MongoDB-compatible proxies on port 27017 (`ferretReplicas`, and `ferretReadOnlyReplicas` on an HA instance), published like the instance (`ferretExposure`, the instance's source ranges and subnet) and allowed by its network policy. It needs Postgres 17.5 or later (`FERRET_VERSION_UNSUPPORTED`) and the operator's FerretDB CRD (`FERRET_CRD_MISSING`); the workflows wait for the connection Secrets (`FERRET_SECRET_MISSING`) and the proxies (`FERRET_NOT_READY`). The `documentdb` extension is prepared by the DBA (extensions are out of scope): a run that turns FerretDB on records the warning `FERRET_EXTENSION_REQUIRED`. An empty `ferret` input keeps what `fleet.yaml` has; `false` removes it.
- **`enableSSL` of the backup location is a parameter.** `backup.enableSSL` (default `false`: plain HTTP to Azure Blob) is set in `clusters/_template/cluster.yaml`, per cluster or per instance in `clusters/fleet.yaml`, or with the `tpg-day0` and `tpg-create-instance` input `backupEnableSSL`. The chart always writes it, and the ApplicationSet ignores it because the CRD drops `false` too. `false` needs a storage account that accepts HTTP (Terraform `backup_storage_https_only = false`, the default). With `true` the workflows also write `backup.caBundle`: the root CAs of the storage account's certificate chain, which Terraform takes from a pinned Microsoft list, checks against the live endpoint and passes to `tpg-settings` (`backupCaBundle`) through `tpg-aks-infra/scripts/run.sh`. The chart refuses `enableSSL: true` without a bundle. **Upgrading from Round 11:** an entry of `clusters/fleet.yaml` (or `clusters/_template/cluster.yaml`) that already sets `backup.enableSSL: true` has no `caBundle`, so its Application stops rendering after this change. Before merging, run `scripts/validate.sh` (it renders every declared instance), then either add `backup.caBundle` (the PEM from `tpg-settings` `backupCaBundle`) to those entries or set them to `enableSSL: false`. The plan carries the bundle between workflow steps as the placeholder `@tpg-settings:backupCaBundle@`, and the commit writes the PEM itself.
- **Nothing is written for a blocked cluster.** tpg-day0 and tpg-create-instance plan `clusters/fleet.yaml` first, pre-check every cluster against the plan, and commit only the clusters that passed. A run in which any cluster or instance was `BLOCKED` still deploys the others and then ends `Failed` (step `gate`), so a partial run is never reported as a success.
- **Ownership comes from Argo CD.** An operator Deployment or a Postgres instance belongs to the fleet when its Argo CD tracking annotation names the Application that deploys it. A Postgres CRD also belongs to it when that Application lists it in `status.resources`: the CRDs come from the chart's `crds/` directory and carry no tracking annotation, so a check by annotation alone called a cluster the fleet had deployed `FOREIGN_CRD`. The list is not used for the other kinds, because it also names an object someone else created under the same name. An operator is found by its label `app=postgres-operator` or by its image name.
- **Azure Blob backups rest on the live CRD.** The Tanzu Postgres 4.5 documentation lists S3 and GCS backup targets only; the operator's PostgresBackupLocation CRD has `spec.storage.azure`. The pre-check and the deploy step read the CRD on each target and block with `AZURE_BACKUP_UNSUPPORTED` when it is missing.
- **Service exposure is one value.** `instance.exposure` and `instance.readOnlyExposure` (`clusterIP`, `internalLoadBalancer`, `loadBalancer`), with `serviceAnnotations`, `allowedSourceRanges` and `internalLoadBalancerSubnet`, render `serviceType` and the Azure load balancer annotations of the Postgres spec. The workflows wait until the Services have their load balancer addresses (`EXPOSURE_NOT_APPLIED`) and warn about a public load balancer without source ranges (`EXPOSURE_UNRESTRICTED`).
- **Network policy per instance.** `network.policy: baseline` renders a NetworkPolicy for ingress and a CiliumNetworkPolicy for egress in `pg-<instance>`: default deny plus the flows the instance needs (replication, the operator, metrics, DNS, the API server, the backup storage), then the client and egress rules. `tpg-network-policy` applies, updates or removes it and then proves that WAL archiving still works and that only the allowed clients connect. Host-name egress rules need ACNS (Terraform `acns_enabled`).
- **Scaling down to one node.** `tpg-scale-instance replicas=0` makes a single-node instance: `fleet.yaml` gets `enabled: false` and `readReplicas: 0`, and the Postgres spec loses its `highAvailability` block. When the live object still says `enabled: true` after the sync (another field manager co-owns the field), the step switches it off with a server-side apply as field manager `tpg-scale` and records the warning `HA_FIELD_CO_OWNED`. It is refused (`FERRET_READONLY_NEEDS_HA`) while the instance has FerretDB read-only proxies.
- **HA and zones.** With more database pods (1 + read replicas) than zones in the data pool, the leader and the synchronous standby can share a zone, and the 4.5 release notes say Patroni does not fail over automatically when that zone is lost. tpg-day0, tpg-create-instance and tpg-scale-instance warn about it (`HA_NODES_EXCEED_ZONES`).
- **High availability needs a data pool that can hold it.** `highAvailability=true` places a primary, a standby and the read replicas on different nodes and zones, so the pre-check refuses a cluster whose data pool does not span 3 zones with 3 Ready nodes. Single-node instances run on any pool shape.
- `tpg-hub-workflows` (templates, scripts, RBAC, admission policies) and the Azure monitoring Applications use automated sync because they hold no data.

## Secrets

No credential is stored in this repository or in a Kubernetes Secret that someone creates by hand. Three values live in HashiCorp Vault on the hub (`tpg/shared/broadcom-registry`, `github-read`, `github-push`, `backup-storage`), installed and filled by `tpg-aks-infra` (`scripts/steps/35-vault.sh`, `40-hub-secrets.sh`):

| Consumer | How it reads Vault |
|---|---|
| Argo Workflows steps | Vault Agent (injector on the hub) renders `/vault/secrets/*.json` before the step container starts, from the templates in the ConfigMap `tpg-vault-agent` (`workflows/vault-agent/`). Steps that need no credential set `vault.hashicorp.com/agent-inject: "false"` |
| Argo CD repositories | Two `VaultStaticSecret` objects in `argocd` build the repository Secrets for this Git repository and the Broadcom OCI registry |
| Operator and instance namespaces | `charts/tpg-instance/templates/vault-secrets.yaml` and `platform/base/vault-secrets.yaml` create a `VaultStaticSecret` for `regsecret` (image pull) and `backup-storage` (the key the `PostgresBackupLocation` uses), in sync wave -1 so the Secrets exist before the Postgres resources |

The Vault Secrets Operator keeps each Kubernetes Secret in step with Vault, and Argo CD reports a `VaultStaticSecret` as Healthy only once the Secret is synced, so the Postgres sync wave waits for it.

## Workflows

All workflows run in the `argo` namespace as `tpg-workflow`, write per-target results to the ConfigMap `tpg-run-<workflow-name>` (deleted with the workflow), and end with a report printed by the exit handler. When any target is `FAILED` or `TIMEOUT`, the report step fails so the run is flagged in the Argo UI and in the controller metrics.

Inputs are typed: a Workflow whose inputs do not match their types is rejected when it is submitted. Mandatory inputs have no default: the first step (`validate`) fails with the list of missing or invalid inputs and the registered cluster names. Where the table says "or `clusterMap`", the map replaces `clusters` and `instances` and can carry the other values per target. **[docs/workflow-commands.md](docs/workflow-commands.md) lists every input with its type, the `clusterMap` keys, several `argo submit` examples per workflow, and the related `argocd` commands.** `scripts/submit/tpg-<workflow>.sh` asks for the inputs interactively (mandatory first, then a menu of the optional ones with types and examples) and submits the run; `tools/pgdata/pgdata.py` loads and reads test data on an instance (sections 17 and 18 of that page).

| Workflow | Purpose | Mandatory inputs |
|---|---|---|
| `tpg-day0` | Write the inputs to `fleet.yaml`, pre-check, install cert-manager, deploy operator and instances in waves | `clusters` and `instances` (or `clusterMap`), `highAvailability`, `operatorVersion`, `postgresVersion` (inputs or map keys), `pushMode` |
| `tpg-create-instance` | Add instances to clusters that run the fleet's operator, with the tpg-day0 instance inputs and patch files of your machine | `clusters` and `instances` (or `clusterMap`), `highAvailability`, `postgresVersion` (inputs or map keys), `pushMode`; `patchFiles` with a patch file |
| `tpg-upgrade` | Upgrade the operator or Postgres instances in waves | `component`, `targetVersion`, `clusters`, `instances` (postgres), or `clusterMap` with versions; `pushMode` |
| `tpg-patch` | Apply patch files of your machine to deployed instances (Postgres spec, chart values) and operators (chart values of an allow-list), per cluster through a pull request synced before the merge (or a direct commit), with a revert on failure | `clusters` (or `clusterMap`), one patch file input or map key, `patchFiles`, `instances` for instance files, `pushMode` |
| `tpg-scale-instance` | Set read replicas of the listed instances on the listed clusters (0: single node) and the cap `maxReadReplicas`, cluster by cluster (`rolloutMode`, default all) | `clusters` and `instances` (or `clusterMap`), `replicas` (input or map key), or `maxReadReplicas` alone; `pushMode` |
| `tpg-network-policy` | Apply, update or remove the network policy of instances, then check WAL archiving and client access | `clusters` and `instances` (or `clusterMap`), `mode`, `pushMode` |
| `tpg-delete-apps` | Delete instances and/or the operator and its CRDs per cluster | `clusters` and `apps` (or `clusterMap`), `confirm`, `dryRun`, `purgePvcs`, `purgeNamespace`, `pushMode` |
| `tpg-delete-instance` | Guarded delete of the listed instances on the listed clusters | `clusters` and `instances` (or `clusterMap`), `confirm` |
| `tpg-helm-addons` | cert-manager, the Vault Secrets Operator and the standalone monitoring agent Helm releases on targets | `clusters` |
| `tpg-backup` | On-demand backups, full or incremental (CronWorkflows run it on a schedule) | none (`backupType`, `clusters` default; `instances` or `clusterMap` narrow it) |
| `tpg-backup-retention` | Expire backup chains older than the retention window | none (`clusters`, `retentionDays`, `dryRun` default; `instances` or `clusterMap` narrow it) |
| `tpg-restore` | Restore an instance: point in time, latest, a named backup, an LSN or a transaction ID, into a new or an existing instance on the same or another cluster | `sourceCluster`, `instance`, `mode` and the recovery point of that mode |
| `tpg-rotate-credential` | Rotate registry, storage or Git credentials | `secretType` |

### Day 0: deploy

```bash
# Dry run: fleet.yaml diff and pre-checks (operator, CRDs, same-named instances, versions)
argo submit -n argo --from workflowtemplate/tpg-day0 \
  -p clusters=all -p instances=orders-db -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct -p dryRun=true --watch

# Deploy: wave 0 canary alone, then later waves in batches of maxParallel (2)
argo submit -n argo --from workflowtemplate/tpg-day0 \
  -p clusters=all -p instances=orders-db -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct --watch

# Every selected cluster at once, no canary
argo submit -n argo --from workflowtemplate/tpg-day0 \
  -p clusters=all -p instances=orders-db -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct -p rolloutMode=all --watch
```

`rolloutMode` (also on `tpg-upgrade`): `canary` (default) runs the wave-0 cluster alone first, then the later waves in batches of `maxParallel`; `batches` skips the canary; `all` runs every selected cluster in one batch. One failing cluster does not stop the others of its batch; a failed batch stops the later ones.

| Pre-check status | Meaning |
|---|---|
| `PASSED` | Nothing Tanzu Postgres related on the cluster |
| `MANAGED` | Existing objects belong to this fleet's Applications (safe re-run: new instances are added) |
| `BLOCKED` | Foreign operator, foreign CRDs, same-named instance, missing Postgres version, no Azure backup in the CRD (`AZURE_BACKUP_UNSUPPORTED`), a data pool that cannot hold an HA instance (`PGDATA_POOL_NOT_HA_CAPABLE`), no Cilium or ACNS for a requested network policy, or unreachable. The cluster gets no `fleet.yaml` entries and is not changed; the run ends `Failed` after the others are deployed |

### Day 1: upgrade, scale, backup, restore, rotate

```bash
argo submit -n argo --from workflowtemplate/tpg-upgrade \
  -p component=operator -p targetVersion=v4.5.1 -p clusters=all -p pushMode=direct --watch
argo submit -n argo --from workflowtemplate/tpg-upgrade \
  -p component=postgres -p targetVersion=postgres-17.7 -p clusters=all -p instances=all -p pushMode=pr --watch
argo submit -n argo --from workflowtemplate/tpg-scale-instance \
  -p clusters=aks-tpg-poc-02 -p instances=orders-db -p replicas=2 -p pushMode=direct --watch
argo submit -n argo --from workflowtemplate/tpg-patch \
  -p clusters=all -p instances=orders-db -p pushMode=pr \
  -p postgresPatchFilePath=./orders-memory.yaml \
  -p patchFiles="$(~/src/tpg-fleet/scripts/submit/pack-patch-files.sh ./orders-memory.yaml)" --watch
argo submit -n argo --from workflowtemplate/tpg-backup -p backupType=full -p clusters=aks-tpg-poc-01 --watch
argo submit -n argo --from workflowtemplate/tpg-backup-retention -p clusters=all -p dryRun=true --watch
argo submit -n argo --from workflowtemplate/tpg-restore \
  -p sourceCluster=aks-tpg-poc-01 -p instance=orders-db -p mode=time \
  -p targetTime=2026-09-15T08:30:00Z --watch
```

- **Upgrade:** minor or major is detected per instance; major needs `allowMajor=true` and pauses for `argo resume` before every batch after the canary. A full backup runs first (`preUpgradeBackup=true`). The `PostgresVersionUpgrade` is followed with the instance pods printed every 5 seconds; then the workflow waits for the operator to set `spec.postgresVersion.name`, writes the version to `fleet.yaml` and syncs at that commit. An instance whose Application does not end Synced is `FAILED` (with Argo CD's message), not `SUCCEEDED`, and later batches do not run.
- **Operator upgrade and the operator image:** when the current operator values patch sets `operatorImage`, the version commit moves its tag to the new version (in the stored file and its copy); another tag stops the upgrade first (`OPERATOR_IMAGE_PINNED`).
- **Patch:** `tpg-patch` checks every file in the validate step, stores it, renders and dry-runs every target and prints the diff, then per cluster commits (a pull request branch synced before the merge, or a direct commit), syncs, verifies and reverts on failure (`PR_NOT_MERGED` when the pull request is closed or not merged within `prTimeoutSeconds`). A refused file or a failed render blocks that cluster only (`PATCH_REFUSED`). `patchMode` `apply` (default) or `clear` (remove the current file of a kind).
- **Scale:** `tpg-scale-instance` writes the counts and the new caps (`maxReadReplicas`, refused below an instance's read replicas: `MAX_BELOW_CURRENT`) in one commit, then syncs cluster by cluster: `rolloutMode` `all` (default), `canary` or `batches` with `maxParallel`. A run with `maxReadReplicas` and no instances only changes the cap.
- **Backups:** one full backup on Sunday, an incremental one on the other days (or the operator's PostgresBackupSchedule objects with `backupSchedule=operator`). Every incremental backup belongs to the chain of the last full backup, so a chain is only ever expired as a whole. If the previous backup is still `Pending` or `Running`, the workflow waits 2 minutes and reports `SKIPPED_IN_PROGRESS`. Instances with `backupSchedule=none` are skipped by the CronWorkflows.
- **Retention:** `tpg-backup-retention` runs daily. It groups the backups of each instance into chains (a full backup and the incrementals that follow it), expires every chain whose newest backup is older than `retentionDays` (35 by default, `backup.retentionDays` per cluster or instance), and always keeps the newest chain, whatever its age. `dryRun=true` reports what it would expire.
- **Restore:** `tpg-restore` restores into a new instance (a one-off clone on the same cluster, or a cluster member added to `clusters/fleet.yaml` and adopted by Argo CD on another cluster) or into an existing one (in place or another instance, which requires `confirm=<instance>` because it overwrites data). For a restore into another namespace or cluster, the workflow creates a read-only copy of the source backup location so `backupSync` lists the source backups there.
- **Credential rotation:** update the value in Vault, then run `tpg-rotate-credential` with `secretType` `broadcom-registry`, `backup-storage`, `git-push` or `git-read`. The workflow verifies that the new value reached every consumer (VaultStaticSecrets, Argo CD repository connection, image pull, backup location, the Blob container).

### Day 2: delete

```bash
# Plan, then run with dryRun=false
argo submit -n argo --from workflowtemplate/tpg-delete-apps \
  -p clusters=aks-tpg-poc-03 -p apps='{"aks-tpg-poc-03":["tpg-instances","tpg-operator"]}' \
  -p confirm=aks-tpg-poc-03 -p dryRun=true -p purgePvcs=false -p purgeNamespace=false -p pushMode=direct --watch
```

Instances leave `clusters/fleet.yaml` (a copy goes to `clusters/deleted/<cluster>/`), the Applications are removed without cascading (`preserveResourcesOnDeletion`), and the workflow deletes the objects in order. With `tpg-operator` it also deletes the operator and the `sql.tanzu.vmware.com` CRDs, refusing while other Postgres instances exist unless `force=true`. The backup repository is never deleted.

## Workflow logs

Every step's log is archived to Azure Blob when the step ends (`archiveLogs`, container `argo-logs` in the backup storage account), through the namespace default artifact repository `argo/artifact-repositories` that `tpg-aks-infra` creates in its `hub-secrets` step, with the account key from Vault (`VaultStaticSecret argo/argo-artifacts`). The Argo UI shows the logs of a finished step even after its pod is gone, for as long as the Workflow exists (7 days); `tpg-aks-infra/scripts/wf-logs.sh <workflow>` reads them afterwards, until the lifecycle rule deletes them (90 days by default).

## Monitoring

| Option | Apply | Dashboards and alerts |
|---|---|---|
| A: Azure Monitor | `MONITORING_OPTION=azure` in `tpg-aks-infra/env.sh`, `enable_azure_monitor = true` in Terraform. The `addons` step enables the managed Prometheus add-on on any cluster that lacks it (a new or pre-created cluster), checks its `ama-metrics` pods and the Grafana role on the workspace | Imported by the `addons` step, or `monitoring/grafana/import-azure-grafana.sh rg-tpgpoc amg-tpgpoc` |
| B: Standalone | `MONITORING_OPTION=standalone`; the `addons` step installs Helm release `kps` and the remote-write gateway on the hub, and `kps` + `tpg-ksm` on every target, then checks that each target's metrics reach the hub | Provisioned automatically (dashboard ConfigMaps in the folder Tanzu Postgres, `grafana.alerting` values) |

**How the targets reach the hub (standalone).** Each target's Prometheus writes to the hub gateway `tpg-remote-write` (nginx, `monitoring/standalone/hub/remote-write-gateway.yaml`): https on port 8443 with a certificate from the Vault CA, basic auth with the credential in Vault `tpg/shared/monitoring-remote-write` (synced to each target as `monitoring/tpg-remote-write`), and only `/api/v1/write` forwarded to the hub Prometheus. Its load balancer is internal or public (restricted to the target egress CIDRs), from the `tpg-aks-infra` inventory `monitoring.remoteWriteExposure`. A new cluster is wired the same way by `tpg-day0` (`installAddons=true`) and `tpg-helm-addons`, and both fail with `MONITORING_NOT_FLOWING` when its metrics do not reach the hub within 5 minutes. Grafana's data sources (Prometheus `uid prometheus`, Alertmanager `uid alertmanager`) are set explicitly in `monitoring/standalone/hub/kps-values.yaml`.

Both options scrape the `postgres-exporter` container that the operator runs in every Postgres pod with a `PodMonitor` every 10 seconds (`scrapeTimeout` 8s), and both watch Vault on the hub (`servicemonitor-vault.yaml`, alert `tpg-vault-sealed`: a sealed or unreachable Vault stops every credential from being renewed).

Five dashboards, all with the data source and cluster variables, in the folder **Tanzu Postgres**:

| Dashboard | Shows |
|---|---|
| Tanzu Postgres Fleet (`tpg-fleet`) | Instances per cluster, healthy and unhealthy instances, ready and desired replicas, backup and restore counts, backup workflow results, hours since the last backup, replication lag, WAL archive failures, connection usage, active alerts |
| Instance overview (`tpg-instance`) | Per instance: operator state, exporter and `pg_up` per pod, connections (used % and by state), transactions, cache hit ratio, rows, database size, locks, deadlocks, longest transaction, volume usage, CPU, memory and restarts of the Postgres pods |
| Replication and HA (`tpg-replication`) | Role per pod, pods ready against desired, desired read replicas, replication lag against the 30 s alert threshold, WAL archived and failed, restarts |
| Backup, WAL and restore (`tpg-backup`) | Hours since the newest full and the newest backup, backups by phase and type, backups in the last 24 hours, backup and retention workflow results, WAL archiving, restores by phase and restore workflow results |
| Alerts (`tpg-alerts`) | The firing and pending alerts, the Prometheus `ALERTS` series, and one panel per configured rule with its expression over time and the threshold as a line |

Alert and dashboard definitions live in `monitoring/grafana/generate.py`. After changing them, regenerate the Grafana provisioning values, the API payloads, the PrometheusRule and the dashboards:

```bash
python3 monitoring/grafana/generate.py
```

Email notifications are optional: see `monitoring/grafana/smtp/` (Grafana SMTP for both options) and `monitoring/prometheus/alertmanager-smtp-values.yaml` (Prometheus alerts through Alertmanager). For the standalone hub, pass them with `KPS_HUB_EXTRA_VALUES` to `tpg-aks-infra/scripts/run.sh --only addons`.

## Adding a cluster or an instance

- **Instance:** run `tpg-create-instance -p clusters=<cluster> -p instances=<name> ...` on a cluster that runs the operator (or `tpg-day0`, which also installs the operator and add-ons). It adds the instance to `clusters/fleet.yaml` and deploys it.
- **Cluster:** create it with `tpg-aks-infra` (`target_cluster_count`) or add a pre-created cluster to `inventory/clusters.yaml` with `wave: 1` or higher, run `tpg-aks-infra/scripts/run.sh` again, then run `tpg-day0 -p clusters=<cluster> ...`. No file or folder is added by hand.

## Static validation

`scripts/validate.sh` runs the same checks used before delivery: `yamllint`, `shellcheck`, `kustomize build`, the `clusters/fleet.yaml` structure, `helm lint` and `helm template` of the instance chart for every `fleet.yaml` instance (with the values the ApplicationSet passes), `kubeconform` (Kubernetes, Argo and Prometheus Operator schemas from the CRDs catalog), and JSON parsing of the dashboard and alert payloads. It also checks that the chart renders `enableSSL` (false by default, true when set with a CA bundle), the exposure and both network policy objects, and refuses the old `instance.serviceType`, that the `tpg-instances` ApplicationSet ignores `Postgres spec.postgresVersion`, and that the five dashboards exist and are in the hub kustomization. It checks `clusters/fleet.yaml` and `clusters/fleet.example.yaml` alike (structure, and that every referenced patch file exists), renders the chart with the example patch files (`chart: patch files are merged`), and fails when `workflows/admission/workflow-parameters.yaml` is not what `workflows/params/generate.py` makes of `types.yaml`, or when the zero-default registry, the reference templates or the CRD schemas are not what `tools/crd-defaults/generate.py` makes of `charts/crd-reference/source-crds/`. It renders a single-node instance (no `highAvailability` block), the backup schedules and FerretDB, and every `charts/crd-reference/examples/` file, and validates the Tanzu Postgres objects with `kubeconform -strict` against the schemas generated from the live CRDs (`charts/crd-reference/schemas/`). It ends with `tests/run-all.sh`.

`tests/run-all.sh` runs on its own too, and needs no cluster. Suites that need a binary that is not installed (`helm`, the envtest API server, the `argocd` CLI) print `SKIP` and pass; `tests/README.md` says what each needs:

- `tests/cli-flags` reads every command in both repositories and fails on a flag the pinned CLI version no longer accepts (`rules.yaml` says which, why and what to write instead). Its fixtures plant one violation per rule, so a rule that stops matching fails the suite. `--against-cli` additionally asks each installed binary for its own flags and reports anything it does not know. It also fails on a jq or yq alternative whose fallback is `true` or a non-zero number: `//` replaces an explicit `false` too, which is how the pre-created preflight read "secure transfer off" as on.
- `tests/helm4` runs `workflows/scripts/helm-addons.sh` against a stub Helm 4 CLI through every pre-check outcome (`DRY_RUN`, `UP_TO_DATE`, `SKIPPED_EXISTS`, `SKIPPED_NEWER`, `REUSED_EXISTING`, `BLOCKED`). The stub rejects `-a` on `helm list` the way Helm 4 does.
- `tests/shared-lib` checks that the shared block of `workflows/scripts/common.sh` is identical to the one in `tpg-aks-infra`, and drives the retries and the pod watch with stubs.
- `tests/sync-engine` drives the Argo CD sync engine with scripted API answers: an old operation is not the answer, a webhook denial fails at once, a transient error is retried, drift and timeouts are reported.
- `tests/rollout` checks the batches of each `rolloutMode`.
- `tests/params` checks that the input types, the generated admission policy, the WorkflowTemplates (names, defaults, enums), the clusterMap key registry and the Type columns of `docs/workflow-commands.md` agree.
- `tests/cluster-map` drives the validate step of every workflow that takes `clusterMap` (unknown keys with suggestions, types, required values, exclusive inputs, `confirm`), and runs `fleet-day0.sh` against stub clusters for the version rule of tpg-day0.
- `tests/patch` runs `patch-plan.sh` and `patch-cluster.sh` with the real chart, a local Git origin and stubs for GitHub and Argo CD: file checks, refused fields, `patchMode`, the postgresVersion guard, the dry-run document, the diff (with the ignored fields of the tpg-instances ApplicationSet), a values patch the chart does not render, `pushMode=direct` and `pr` with the merge, the revert (closed, not merged in time, a failed sync, a merge before the failure, a stored file another cluster still names) and the operator (needs `helm`).
- `tests/chart` renders the instance chart for every exposure, the `caBundle` rule and the network policy, and checks that no NetworkPolicy peer list is ever empty; the `highAvailability` block, zero defaults left out, the backup schedules and FerretDB, all checked with `kubeconform -strict` against the CRD schemas (needs `helm`).
- `tests/crd-reference` checks that the registry, the reference templates and the schemas are generated from the CRDs in the folder, that `tpg.prune` leaves out each zero default of the 9 kinds and keeps the others, that the examples pass the schemas, and that the objects the workflow scripts write inline equal the reference render (needs `helm`).
- `tests/day0-plan` runs the tpg-day0 and tpg-create-instance steps with stubs: the plan, ownership (the Application's resource list for the CRDs, the tracking annotation for the rest), `ORPHAN_CRD`, `OPERATOR_NOT_INSTALLED`, the creation rules, `ALREADY_EXISTS` and `INSTANCE_EXISTS`, the commit of the passed clusters only, and the gate (needs `helm`).
- `tests/network-policy` runs the tpg-network-policy plan with the real chart: `apply`, `update`, `remove`, clusterMap rules, the guard, and every block (needs `helm`).
- `tests/submit` drives the submit scripts through their numbered menus with stub `argo` and `kubectl`.
- `tests/pgdata` runs `pgdata.py` against a throwaway local PostgreSQL (needs the PostgreSQL server binaries and psycopg 3).
- `tests/admission` evaluates both admission policies on a real kube-apiserver with the Argo CD and Argo Workflows CRDs (it needs the envtest binaries). `tests/ssa` (operator manifest patches) was removed with them in Round 14.
- `tpg-aks-infra/tests/argocd-rbac` evaluates the RBAC deny block with the real `argocd admin settings rbac can`: people cannot sync, override, update or delete a tpg Application, `workflow-bot` can sync, and the functions `check-argo.sh` uses (`scripts/lib/argo-rbac.sh`) find every subject that can still act on project `tpg` and merge the marked block into an existing `policy.csv`.
- `tpg-aks-infra/tests/preflight` runs the storage check of the pre-created preflight against a stubbed `az`: secure transfer off is read as off.
- `tpg-aks-infra/tests/verify` drives `scripts/steps/60-verify.sh` against a stubbed cluster and asserts that a missing object is named as missing rather than reported as a wrong field value, and that the summary groups each resource with the clusters it fails on.

## Items to validate in the lab

The Tanzu for Postgres custom resources have no public JSON schema, so confirm these on the first lab cluster:

| # | Item | How |
|---|---|---|
| V1 | `spec.storage.azure` fields and `backup-storage` keys (`accountName`, `accountKey`) | `kubectl explain postgresbackuplocation.spec.storage.azure`, then one manual backup |
| V2 | Minor upgrades through `PostgresVersionUpgrade`, and whether the operator updates `spec.postgresVersion.name` | Upgrade a test instance by one minor version |
| V3 | Operator upgrade by Argo CD, including CRD updates and instance pod rollout | Run `tpg-upgrade -p component=operator` on the canary |
| V4 | In-place PITR with `pitr.type: time` on an existing instance | Restore a disposable instance with `inPlace=true` |
| V5 | kube-state-metrics timestamp gauges exported as unix seconds | `curl` the `tpg-ksm` metrics endpoint, grep `tanzu_postgres_` |
| V6 | postgres-exporter metric names used in alerts | Port-forward 9187 on a data pod and grep `pg_` |
| V7 | Argo Workflows custom metric names (`argo_workflows_tpg_*_total`) | `curl` the workflow controller metrics Service |
| V8 | `alpine/k8s:1.35.8` and `azure-cli:2.90.0` tags pullable from the hub | `kubectl run` a test pod with each image |
| V9 | Re-creating a deleted instance reattaches retained PVCs | Delete with defaults, then run `tpg-day0` for the instance again |
| V10 | `tpg-delete-apps` with `tpg-operator` removes all 9 `sql.tanzu.vmware.com` CRDs and leftover webhooks | Run on a lab cluster; `kubectl get crd,validatingwebhookconfigurations` |
| V11 | ApplicationSet matrix with `elementsYaml` renders one Application per `fleet.yaml` instance | `argocd appset get tpg-instances`; `argocd app list -l tpg.fleet/component=instance` |
| V12 | Pull request mode with the fine-grained PAT (Pull requests: Read and write) | `tpg-scale-instance -p pushMode=pr -p dryRun=false` on a test instance |
| V13 | `VaultStaticSecret` status conditions of Vault Secrets Operator 1.5.1 (`Ready` and/or `SecretSynced`), which the Argo CD health check reads | `kubectl -n argocd get vaultstaticsecret repo-tpg-fleet -o yaml`; `argocd app get` shows the resource health |
| V14 | Vault Agent injection in the workflow pods: `/vault/secrets/*.json` present and readable | `argo submit --from workflowtemplate/tpg-backup -p dryRun=true`, then `kubectl -n argo exec <pod> -- ls /vault/secrets` |
| V15 | `PostgresBackup.spec.expire` expires the whole chain of a full backup, and `status.phase` afterwards | `tpg-backup-retention -p dryRun=false` on a disposable instance with several chains |
| V16 | `PostgresRestore` with `pitr.type: time`, `latest`, `lsn` and `transaction`, and `sourceBackupLocation.stanzaName` of a copied backup location | `tpg-restore` in each mode on a disposable instance |
| V17 | `backupSync` on the read-only copy of a source backup location lists the source backups in the target namespace | Cross-namespace `tpg-restore`, then `kubectl -n pg-<target> get postgresbackup` |
| V18 | Deleting the copied backup location (label `tpg.fleet/restore-source`) removes only the synced objects | Delete it after a validated restore and check the source namespace |
| V19 | Auto-unseal with the Azure Key Vault key after a `vault-0` restart (`vault_unseal_mode = "azure-keyvault"`) | `kubectl -n vault delete pod vault-0`, then `kubectl -n vault exec vault-0 -- vault status` |
| V20 | Helm version in the tools image, and `helm list` without `-a` | `kubectl -n argo run helmcheck --rm -it --image=alpine/k8s:1.35.8 --restart=Never -- helm version --short` and `... -- helm list -A` |
| V21 | `PostgresBackupLocation` stays Synced: the applied object carries neither `additionalParameters` nor `storage.azure.forcePathStyle`, and the Application reports Synced after two refreshes | `kubectl -n pg-orders-db get postgresbackuplocation orders-db-backup-location -o yaml`; `argocd app get tpg-<cluster>-orders-db --hard-refresh` |
| V22 | `60-verify.sh` names a missing object instead of reporting a wrong value | Delete `storageclass tpg-data-retain` on a lab target, run `scripts/run.sh ... --only verify`, then re-apply it |
| V23 | A step that fails before it records a result reports `UNEXPECTED_ERROR` with the line number, not `UNKNOWN` | Revoke the workflow ServiceAccount's access to `configmap/tpg-run-<workflow>` mid-run, or `kubectl -n argo delete secret kubeconfig-<cluster>` before a `tpg-backup` run; read `kubectl -n argo get configmap tpg-run-<workflow> -o yaml` |
| V24 | Argo CD reports a new instance Progressing until `status.currentState` is `Running`, then Healthy (Postgres health check) | `argocd app get tpg-<cluster>-orders-db` during `tpg-day0` |
| V25 | The pod watch stops a run on a pod that cannot start, and prints its events and logs | Deploy an instance with a wrong `storageClassName` (unschedulable) or break `regsecret`, read the step log |
| V26 | `tpg-upgrade component=postgres` ends Synced with no webhook rejection: the operator writes `spec.postgresVersion.name`, and Argo CD ignores the field | Minor upgrade of a test instance; the log shows `spec.postgresVersion.name is postgres-<target>`; `argocd app get` shows Synced |
| V27 | The sync engine pins the fleet commit and reports a rejected sync as `SYNC_REJECTED` | Break an instance spec by hand in Git, run `tpg-scale-instance`, read `tpg-run-<workflow>` |
| V28 | `rolloutMode=all` starts every cluster in the same batch | `tpg-day0 -p rolloutMode=all -p dryRun=false`; `argo get @latest` shows one batch |
| V29 | Archived logs: the Argo UI shows the log of a step whose pod was deleted, and `scripts/wf-logs.sh` reads it after the Workflow is deleted | Run any workflow, `argo delete` it, then `tpg-aks-infra/scripts/wf-logs.sh <workflow>` |
| V30 | `enableSSL: false` backups work against the storage account (HTTP accepted), and `true` works with HTTPS | One backup per setting on a disposable instance |
| V31 | Standalone: each target's metrics reach the hub through the gateway (basic auth, Vault CA); Grafana lists the two data sources and the folder Tanzu Postgres | `count by (cluster) (up)` in Grafana Explore; `kubectl -n monitoring logs deploy/tpg-remote-write` shows 204 |
| V32 | Azure option: a pre-created cluster without the managed Prometheus add-on gets it from the `addons` step, and its data appears in Managed Grafana | `az aks show --query azureMonitorProfile.metrics.enabled`; `Tanzu Postgres - Instance overview` |
| V33 | The five dashboards show data with the exporter's metric names on the operator 4.5 image (`pg_stat_database_*`, `pg_locks_count`, `pg_replication_is_replica`, `pg_stat_archiver_*`) | Open each dashboard; a panel with no data points to a metric name to adjust in `generate.py` |
| V34 | The admission policy `tpg-workflow-parameters` rejects a Workflow whose input has the wrong type and names the input | `argo submit --from workflowtemplate/tpg-day0 -p maxParallel=abc ...`: rejected, no Workflow created |
| V35 | The admission policy `tpg-application-sync` refuses a sync from the Argo CD UI and accepts the workflows' syncs; the username the workflows produce is `workflow-bot` or `workflow-bot:apiKey` | Sync a target Application in the UI; run `tpg-scale-instance`; `argocd app get <app> -o json \| jq .status.operationState.operation.initiatedBy` |
| V36 | The RBAC block denies people `sync`, `rollback`, `terminate-op` and `set` on `tpg/*` and leaves `tpg-hub-workflows` manageable | Each command as admin on a target Application; `argocd app sync tpg-hub-workflows` |
| V37 | `check-argo.sh --yes` finds every subject that can act on project `tpg` on an existing hub (SSO groups, `policy.default`) and closes the gap | `--only hub` on an existing hub with an SSO group role, then again without `--yes`: no `ARGO_RBAC_MISSING` |
| V38 | The operator Application renders from two sources: the OCI chart with the `$fleet` value file `patches/operator/clusters/<cluster>.yaml` (Round 14; `ignoreMissingValueFiles` when the cluster has none) | `tpg-patch` with `operatorValuesPatchFilePath` on the canary; `argocd app get <app> -o json \| jq .spec.sources`; `argocd app manifests` |
| V39 | Removed in Round 14 with the operator manifest patches (see V67) | |
| V40 | Removed in Round 14 with the operator manifest patches and the input `operatorPatches` | |
| V41 | A Postgres patch (resources) rolls out through the operator without `SYNC_REJECTED` | `tpg-patch -p postgresPatchFilePath=./resources.yaml` (with `patchFiles`) on a disposable instance |
| V42 | `tpg-day0` reports `FLEET_OVERRIDDEN` where nothing runs and blocks a cluster that runs another operator version | Declare a version by hand for an empty cluster and run `tpg-day0` with another; repeat on a running cluster (`UPGRADE_REQUIRED` or `DOWNGRADE_NOT_ALLOWED`) |
| V43 | `scripts/validate.sh` passes with the `helm` binary (`helm lint` and `helm template` with the example patch files) | On a workstation with Helm 3 or 4: `./scripts/validate.sh` |
| V44 | A tpg-day0 re-run on a cluster it deployed reports `MANAGED`: the operator Application lists the CRDs in `status.resources`, and the operator Deployment carries the tracking annotation | `tpg-day0 -p dryRun=true` for a deployed cluster; `argocd app get tpg-<cluster>-operator -o json \| jq '.status.resources[] \| .kind + "/" + .name'`; `kubectl -n tanzu-postgres-operator get deploy -o jsonpath='{.items[*].metadata.annotations.argocd\.argoproj\.io/tracking-id}'` |
| V45 | tpg-create-instance: the server-side dry run of `tpg-create-probe` in namespace `default` passes the operator's webhooks and leaves nothing behind | `tpg-create-instance -p dryRun=true`; `kubectl get postgres -A` shows no probe |
| V46 | `enableSSL: true` with the Terraform CA bundle: a full backup and WAL archiving over HTTPS on a storage account with secure transfer required | `tpg-create-instance -p backupEnableSSL=true` on a disposable instance, then `tpg-backup` |
| V47 | Exposure: `internalLoadBalancer` gets a private IP from `internalLoadBalancerSubnet`, `loadBalancer` honours `azure-allowed-ip-ranges`, the read-only Service is a load balancer only with HA | `kubectl -n pg-<instance> get svc -o wide`; connect from inside and outside the ranges |
| V48 | `tpg-egress` on AKS with Cilium: `toEntities: kube-apiserver` keeps the Patroni leader lock working, DNS works through LocalDNS, metrics are still scraped | Apply `mode=apply`, fail the primary over by hand, check `up` for the instance in Grafana |
| V49 | A client through a load balancer reaches the pod with its own source address, so `ingressFromCidrs` matches it | `tpg-network-policy -p ingressFromCidrs=<client range>`; connect from inside and outside the range |
| V50 | Backup egress: any address on 443 without ACNS, `*.blob.core.windows.net` by FQDN with ACNS (`acns_enabled = true`) | `tpg-network-policy` with `connectivityCheck=true` on a cluster of each kind (`BACKUP_EGRESS_BLOCKED` must not appear) |
| V51 | `run.sh --only vault` shows the `vault` pod table with `vault-0` as `Started` before init and unseal | Install a new hub; read the step output |
| V52 | The submit scripts on macOS (bash 3.2) with arrow-key menus | `HUB_CONTEXT=<hub> scripts/submit/tpg-day0.sh` from a Mac terminal, then Cancel |
| V53 | A single-node instance (`highAvailability=false`) reaches Synced: the rendered Postgres has no `highAvailability` block and `argocd app diff` is empty after two refreshes | `tpg-create-instance -p highAvailability=false`; `argocd app manifests tpg-<cluster>-<instance> --source git \| yq 'select(.kind == "Postgres") \| .spec'`; `argocd app get tpg-<cluster>-<instance> --hard-refresh` |
| V54 | `tpg-scale-instance replicas=0` turns an HA instance into a single node: the standby and replica pods go, the primary keeps serving; whether `HA_FIELD_CO_OWNED` appears (and which managers own `spec.highAvailability.enabled`) | On a disposable HA instance; `kubectl -n pg-<instance> get postgres <instance> -o json \| jq '.spec.highAvailability, [.metadata.managedFields[].manager]'`; read the run report |
| V55 | `backupSchedule=operator`: the two PostgresBackupSchedule objects create PostgresBackup objects at their cron times (UTC), the CronWorkflows skip the instance, and `tpg-backup-retention` expires the chains | `tpg-create-instance -p backupSchedule=operator -p operatorFullSchedule='*/30 * * * *' -p operatorIncrementalSchedule='*/10 * * * *'` on a disposable instance; `kubectl -n pg-<instance> get postgresbackupschedule,postgresbackup` |
| V56 | FerretDB on Postgres 17.5 or later: after the DBA prepared the `documentdb` extension, the proxies are ready, a MongoDB client connects on 27017 through the exposure, and the read-only proxies work on an HA instance | `tpg-create-instance -p postgresVersion=postgres-17.6 -p ferret=true -p ferretReadOnlyReplicas=1 -p highAvailability=true`; `mongosh "mongodb://<user>:<password>@<address>:27017/"` |
| V57 | FerretDB without the extension: the proxies start but a client fails, which is what `FERRET_EXTENSION_REQUIRED` warns about; the error text the client gets | Same as V56 without preparing the extension |
| V58 | Existing instances after the Round 13 merge: the first sync changes nothing on the live objects and a single-node instance that was OutOfSync becomes Synced | `argocd app diff tpg-<cluster>-<instance>` before and after any workflow sync; `kubectl get postgres,postgresbackuplocation -n pg-<instance> -o yaml` unchanged except `metadata` |
| V59 | The CRDs in `charts/crd-reference/source-crds/` equal the lab operator's, so the registry and the schemas describe what runs | `kubectl get crd <name>.sql.tanzu.vmware.com -o yaml` for the 9 kinds into `source-crds/`, then `python3 tools/crd-defaults/generate.py --check` (no change) |
| V60 | The pre-created preflight accepts a backup storage account with secure transfer turned off | `tpg-aks-infra/scripts/run.sh --targets precreated --only preflight` against an account with `--https-only false` |
| V61 | A tpg-day0 run on a lab `clusters/fleet.yaml` that holds JSON-style entries commits the whole file in block YAML, and the Applications stay Synced (values unchanged) | `git show HEAD -- clusters/fleet.yaml` after the run; `argocd app get tpg-<cluster>-<instance>` |
| V62 | The tpg-scale-instance validate step reads `clusters/fleet.yaml` (Vault Agent in that step) and refuses `replicas=2 enableHAIfNeeded=false` for a single-node instance before any change | `argo submit --from workflowtemplate/tpg-scale-instance -p clusters=<c> -p instances=<single-node> -p replicas=2 -p enableHAIfNeeded=false -p pushMode=direct`; the validate step log |
| V63 | tpg-patch `pushMode=pr`: Argo CD syncs an instance Application at the commit of the pull request branch (not on its `targetRevision`), the Application shows OutOfSync until the merge, and after the merge it turns Synced without a second sync (`argocd app history` shows the branch commit) | `scripts/submit/tpg-patch.sh` with a values file on the canary; `argocd app get tpg-<c>-<i>` before and after merging |
| V64 | The operator Application is synced with its fleet source at the branch commit (`revisions` and `sourcePositions` of the sync request) and reads `patches/operator/clusters/<cluster>.yaml` from it | tpg-patch with `operatorValuesPatchFilePath` (resources) and `pushMode=pr`; `argocd app get tpg-<c>-operator -o json \| jq .status.operationState.syncResult` |
| V65 | The diff of the plan shows only what the patch changes: an unchanged instance gives no `kubectl diff --server-side` output (the tracking annotation is added), and the operator chart render has no field that changes on every render | tpg-patch `dryRun=true` with a file whose content equals the current one: `NO_CHANGE`; the plan step log |
| V66 | A pull request closed without merging, and a sync that fails, close the pull request, sync the cluster back and delete the branch; a pull request merged before the failure is reverted on the fleet branch; with `pushMode=direct` a revert commit is pushed and synced | tpg-patch `pushMode=pr`, close the pull request while the workflow waits; tpg-patch `pushMode=direct` with a Postgres patch the operator's webhook refuses |
| V67 | Upgrading to Round 14 on a lab repository with operator manifest patches: `scripts/validate.sh` names the entries, and after the release command the `tpg-patch` field manager owns nothing on the operator Deployment | tpg-fleet README, Upgrading to Round 14; `kubectl get deploy -n tanzu-postgres-operator -o json --show-managed-fields` |
| V68 | `patchFiles` is read from the Workflow object (RBAC `workflows get` for `tpg-workflow`), also near the limits (a 256 KiB file, 512 KiB in all) | tpg-patch with a large values file; the validate step log |
| V69 | tpg-scale-instance `rolloutMode=canary` syncs the wave-0 cluster first and stops the later batches when it fails, and the exit handler restores the count of the clusters it did not reach in `clusters/fleet.yaml`; `maxReadReplicas` alone writes the cap and syncs nothing | `-p rolloutMode=canary -p maxParallel=1` on three clusters; `-p maxReadReplicas=4` without instances |
| V70 | tpg-aks-infra verify on fresh targets reports StorageClass `tpg-data-retain` as a WARNING (created by tpg-day0), and as an issue once `tpg-<cluster>-platform` has synced | `scripts/run.sh ... --only verify` before and after the first tpg-day0 |
