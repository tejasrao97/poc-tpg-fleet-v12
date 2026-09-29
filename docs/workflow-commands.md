# Workflow command reference

Every tpg operation is an Argo Workflows `WorkflowTemplate` in the `argo` namespace on the hub. You start a run with the **argo CLI** (`argo submit --from workflowtemplate/<name>`). Argo CD does not start workflows: the workflows call the Argo CD API to refresh and sync Applications. The **argocd CLI** commands at the end of this page inspect what the workflows did; people cannot sync the tpg target Applications themselves (section 20).

Every input has a type (section 2). A Workflow whose inputs do not match their types is rejected when it is submitted, and no Workflow is created. Mandatory inputs have no default: a run without them fails in its first step (`validate`), which lists every missing or invalid input, including the registered cluster names.

Every workflow can also be started with an interactive script, `scripts/submit/tpg-<workflow>.sh`, that asks for the mandatory inputs first and then offers the optional ones in a menu (section 17).

## Contents

1. [Set up the CLIs](#1-set-up-the-clis)
2. [Input types and conventions](#2-input-types-and-conventions)
3. [clusterMap](#3-clustermap)
4. [tpg-day0](#4-tpg-day0)
5. [tpg-create-instance](#5-tpg-create-instance)
6. [tpg-upgrade](#6-tpg-upgrade)
7. [tpg-patch](#7-tpg-patch)
8. [tpg-scale-instance](#8-tpg-scale-instance)
9. [tpg-network-policy](#9-tpg-network-policy)
10. [tpg-delete-apps](#10-tpg-delete-apps)
11. [tpg-delete-instance](#11-tpg-delete-instance)
12. [tpg-helm-addons](#12-tpg-helm-addons)
13. [tpg-backup](#13-tpg-backup)
14. [tpg-backup-retention](#14-tpg-backup-retention)
15. [tpg-restore](#15-tpg-restore)
16. [tpg-rotate-credential](#16-tpg-rotate-credential)
17. [Interactive submit scripts](#17-interactive-submit-scripts)
18. [Test data: pgdata](#18-test-data-pgdata)
19. [Follow, approve, stop and clean up runs](#19-follow-approve-stop-and-clean-up-runs)
20. [argocd CLI: inspect the sync steps behind the workflows](#20-argocd-cli-inspect-the-sync-steps-behind-the-workflows)

---

## 1. Set up the CLIs

```bash
# Kubeconfig written by tpg-aks-infra/scripts/run.sh (context aks-tpg-hub)
export KUBECONFIG=~/src/tpg-aks-infra/.work/kubeconfig
export ARGO_NAMESPACE=argo            # every command below then works without -n argo

argo version
argo template list
```

To use the Argo Workflows server instead of the Kubernetes API (for example from a laptop without cluster access), see `tpg-aks-infra/docs/README-argo-on-aks.md` and set `ARGO_SERVER`, `ARGO_HTTP1=true`, `ARGO_SECURE=true` and `ARGO_TOKEN`.

```bash
# argocd CLI against the hub (port-forward works without a public UI)
kubectl --context aks-tpg-hub -n argocd port-forward svc/argocd-server 18080:443 >/dev/null 2>&1 &
argocd login localhost:18080 --username admin --insecure --grpc-web \
  --password "$(kubectl --context aks-tpg-hub -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
```

## 2. Input types and conventions

Argo Workflows passes every input as a string. The types below are declared once in `workflows/params/types.yaml` and enforced by the hub's Kubernetes API server (ValidatingAdmissionPolicy `tpg-workflow-parameters`, generated from that file). The check applies to `argo submit`, the Argo UI, the API and CronWorkflows alike. A rejected submission names every wrong input and its type, for example:

```text
tpg-day0: maxParallel="abc" must be an Integer (1 or more); dryRun="yes" must be a Boolean (true or false). See docs/workflow-commands.md
tpg-scale-instance: cluster is not an input of tpg-scale-instance. See docs/workflow-commands.md
```

| Type | Accepted values | Example |
|---|---|---|
| `List` | Comma-separated names (lowercase DNS labels). Where the table says so, `all` selects every registered cluster or every declared instance. `components` takes `auto`, or a list of `cert-manager`, `vso` and `monitoring` | `aks-tpg-poc-01,aks-tpg-poc-02`, `all` |
| `String (file path)` | The relative path of one `.yaml` or `.yml` file on the machine that submits the run (no leading `/`, no `..`); its contents go in `patchFiles` (tpg-patch, tpg-create-instance; Round 14) | `./orders-backup.yaml` |
| `List (CIDRs)` | Comma-separated IPv4 or IPv6 networks with the host bits zero | `10.20.0.0/16,192.168.10.0/24` |
| `List (host names)` | Comma-separated DNS names; `*.` in front matches every subdomain | `api.example.com,*.example.org` |
| `String` | Any text | `alpine/k8s:1.35.8` |
| `String (name)` | One lowercase DNS label (a Kubernetes object name for `backupName`, `ferretSecretName` and `ferretReadOnlySecretName`) | `orders-db` |
| `String (cron)` | A cron schedule of 5 fields: minute, hour, day of month, month, day of week (UTC) | `0 0 * * 0` |
| `String (Azure name)` | An Azure resource name: letters, digits, `-`, `_` and `.`, at most 80 characters | `aks-apps_subnet` |
| `String (version)` | Operator: `v4.5.0` (`4.5.0` is accepted). Postgres: `postgres-17.6` (`17.6` is accepted; the version must exist in `kubectl get postgresversion`) | `v4.5.1`, `postgres-16.10` |
| `String (quantity)` | A Kubernetes quantity | `20Gi`, `500m`, `2` |
| `String (UTC time)` | `YYYY-MM-DDThh:mm:ssZ` | `2026-09-15T08:30:00Z` |
| `String (LSN)` | A log sequence number | `0/3000060` |
| `Boolean` | `true` or `false` | `true` |
| `Integer` | Digits only. Counts can be 0; timeouts and `maxParallel` start at 1 | `3`, `1800` |
| `Enum` | One of the values in the Description column | `direct` |
| `Map` | YAML or JSON (section 3) | `{"aks-tpg-poc-01": {"instances": {"orders-db": {"replicas": 2}}}}` |
| `Map (JSON)` | A JSON object | `{"aks-tpg-poc-01": ["tpg-operator"]}` |

Inputs used by several workflows:

| Common input | Type | Values | Used by |
|---|---|---|---|
| `clusters` | `List` | Registered clusters, or `all` where accepted | every workflow except restore |
| `instances` | `List` | Declared instances, or `all` where accepted (new instances for create-instance) | day0, create-instance, upgrade, patch, scale, network-policy, backup, backup-retention, delete-instance |
| `clusterMap` | `Map` | Targets with per-cluster and per-instance values (section 3); replaces `clusters` and `instances` | day0, create-instance, upgrade, patch, scale, network-policy, backup, backup-retention, delete-instance, delete-apps |
| `pushMode` | `Enum` | `direct`: push the `clusters/fleet.yaml` change to the fleet branch. `pr`: push a branch, open a GitHub pull request and continue once it is merged (`prTimeoutSeconds`, default 3600). tpg-patch syncs the pull request branch before the merge (section 7) | day0, create-instance, upgrade, patch, scale, network-policy, delete-apps, delete-instance, restore |
| `dryRun` | `Boolean` | `true`: validate and record the plan; change nothing | day0, create-instance, upgrade, patch, scale, network-policy, delete-apps, helm-addons, backup-retention |
| `rolloutMode` | `Enum` | `canary` (default): the wave-0 cluster alone, then the other waves in batches of `maxParallel`. `batches`: no canary, batches of `maxParallel` in wave order. `all`: every selected cluster in one batch | day0, create-instance, upgrade, patch, network-policy |

- Put values that contain commas, spaces or JSON in single quotes.
- `-p name=value` sets one input. `--parameter-file inputs.yaml` reads several from a file (examples in each section). In a parameter file, quote `true`, `false` and numbers, and write `clusterMap` as a block (`clusterMap: |`).
- `--watch` follows the run in the terminal. Without it, the command prints the workflow name.
- `--name` or `--generate-name` sets the workflow name, which is also the results ConfigMap `tpg-run-<name>`.
- Every run ends with a report (exit handler). `argo logs @latest -c main | sed -n '/tpg run report/,$p'` prints it again. Warnings (section 19) have their own part of the report.
- Instance lists are checked against `clusters/fleet.yaml` before anything changes: an instance that is not declared on a selected cluster fails the run with `UNKNOWN_INSTANCE` and the list of declared instances.
- While a step waits for pods (Helm releases, the operator, instances, upgrades, scale, patch, restore), it prints the pod table of the namespace every 5 seconds and stops as soon as a pod cannot start. The failure reason is `POD_<REASON>` (for example `POD_CRASHLOOPBACKOFF`, `POD_CREATECONTAINERCONFIGERROR`, `POD_UNSCHEDULABLE`), followed in the log by the pod's status, events and the logs of the failing container. `CreateContainerConfigError`, `CreateContainerError`, `InvalidImageName` and `RunContainerError` fail at once; `CrashLoopBackOff`, `ImagePullBackOff`/`ErrImagePull`, `Error` and `OOMKilled` after 60 seconds; an unschedulable or Pending pod after 5 minutes.
- Transient API errors (timeouts, connection resets, HTTP 429/502/503/504) of `kubectl`, `helm`, `az` and the Argo CD API are retried up to 5 times with 5, 10, 20 and 40 seconds between attempts (`TPG_RETRY_ATTEMPTS`, `TPG_RETRY_DELAY`); the log shows `<tool> <verb>: transient error (attempt n/5), retrying in Ns: <error>`.
- Argo CD syncs are made at the fleet commit the run pushed; a sync the API server rejects (admission webhook, invalid field) fails the step at once with Argo CD's message.
- `toolsImage` (`String`, default `alpine/k8s:1.35.8`) is the image every step runs in. It is an input of every workflow and is not listed in the tables below.
- Some combinations are refused as well, by the same admission policy (`rules` in `workflows/params/types.yaml`), by the submit scripts and by the `validate` step (which also checks the values `clusterMap` gives each instance): `highAvailability=true` with `readReplicas=0` (a single node is `highAvailability=false`), `readReplicas` above 0 with `highAvailability=false` (read replicas need high availability), and `ferretReadOnlyReplicas` above 0 with `highAvailability=false` (the read-only FerretDB proxies connect to the standby). `highAvailability` and `readReplicas` are checked where they are set: both as inputs, or both on one `clusterMap` entry (an entry's own keys, the inputs filling what it leaves out). An input `readReplicas` is a default for HA instances only: it does not apply to an entry that sets `highAvailability: false` itself. `fleet-day0.sh` refuses the same pairs again before it writes anything (it no longer turns a `readReplicas` above 0 into 0).
- `clusters/fleet.yaml` is written in block YAML. Every workflow that commits it (the tpg-day0 and tpg-create-instance commit step included, which copies each cluster from its JSON plan) turns every flow map and list in the file into block style first, so an entry written as JSON by an earlier version, or a hand-written `{a: b}`, becomes block YAML with the next commit. Quotes stay only where YAML needs them (`"true"`, `"0"`), a comment at the end of a flow line moves above its content, and `caBundle` stays a literal block.
- **Zero defaults are not written** (design decision D69). The tpg-instance chart leaves out of every object it renders the fields that hold their zero default (`false`, `0`, `[]`, `{}`): a single-node instance gets no `spec.highAvailability` block at all (the operator's defaults are `enabled: false` and `readReplicas: 0`). A field left out takes the same default, so declaring it gains nothing, and a declared field that a writer drops leaves the Application OutOfSync (the PostgresBackupLocation drift of Round 9, the single-node reports of Round 12). `clusters/fleet.yaml` keeps the explicit values (`enabled: false`, `readReplicas: 0`), since `clusters/_template/instance.yaml` defaults to `true` and `1`. The fields come from the registry `charts/tpg-instance/files/zero-defaults.yaml`, generated from the 9 live CRDs in `charts/crd-reference` (`charts/crd-reference/README.md`, section 3). A field whose default is not zero is always written: `enableSSL: false` stays, because its CRD default is `true`.

---

## 3. clusterMap

`clusterMap` selects the targets of a run (clusters, and the instances on each) and carries values that differ per cluster or per instance. It is optional. A run takes either `clusterMap` or the `clusters` and `instances` inputs, not both. The other inputs stay the defaults of every target, and a map key overrides them for one cluster or one instance.

```yaml
<cluster>:                  # a registered cluster
  <cluster key>: <value>
  instances:
    <instance>:             # an instance (namespace pg-<instance>)
      <instance key>: <value>
```

It is written as YAML or JSON. Values can be YAML booleans and numbers (`true`, `2`); a Postgres version written as a number (`16.10`) keeps its trailing zero. List values are YAML lists or comma-separated strings, map values are YAML or JSON maps of strings. A key set to `null`, or to an empty list or map, is refused: remove the key to use the default. The accepted keys are listed in `workflows/params/cluster-map-keys.yaml`; adding a key is one entry there. The `validate` step checks the whole map before anything changes:

- every cluster is registered, and every name is a DNS label;
- every key exists and the workflow accepts it (an unknown key names the closest known one: `replica` gives "did you mean replicas?"; an invalid name shows a valid form: `orders_db` gives "for example orders-db"; an unregistered cluster names the closest registered one);
- every value has the key's type;
- every required value is present, from the map key or from the workflow input of the same name;
- day0, create-instance, network-policy, backup, backup-retention and delete-instance need at least one instance per cluster. In upgrade, patch, scale and delete-apps, a cluster without instances must carry its cluster-level action (`operatorVersion`, an operator patch file, `maxReadReplicas`, `deleteOperator`).

Cluster keys:

| Key | Type | Workflows | Meaning |
|---|---|---|---|
| `operatorVersion` | `String (version)` | day0 (required: key or input), upgrade | Operator chart version of the cluster |
| `maxReadReplicas` | `Integer` | day0, create-instance, scale | `clusters.<c>.cluster.maxReadReplicas` (template default 3), 1 or more. tpg-scale-instance: the input `maxReadReplicas` is its default, and a cluster entry may carry it without instances (only the cap changes) |
| `operatorValuesPatchFilePath` | `String (file path)` | patch | An operator values file of the submitting machine (its contents in `patchFiles`) |
| `patchMode` | `Enum` | patch | `apply` or `clear`, for the operator file of this cluster and the default of its instances |
| `deleteOperator` | `Boolean` | delete-apps | `true` deletes the operator and its CRDs after the listed instances |
| `force` | `Boolean` | delete-apps | As the `force` input, for this cluster |

Instance keys:

| Key | Type | Workflows | Meaning |
|---|---|---|---|
| `postgresVersion` | `String (version)` | day0 and create-instance (required), upgrade; a guard in patch, scale, network-policy, backup, backup-retention, delete-instance and delete-apps | day0, create-instance and upgrade: the version to deploy or upgrade to. Guard: when set, an instance that runs another version is skipped (`SKIPPED_VERSION_MISMATCH`) and nothing is changed for it |
| `highAvailability` | `Boolean` | day0, create-instance (required) | As the input |
| `readReplicas`, `storageSize`, `walStorageSize`, `storageClass`, `cpu`, `memory`, `backupSchedule` | as the inputs | day0, create-instance | As the tpg-day0 inputs (`readReplicas` 1 or more with `highAvailability: true`, and none above 0 with `highAvailability: false`) |
| `operatorFullSchedule`, `operatorIncrementalSchedule` | `String (cron)` | day0, create-instance | `backupSchedule: operator`: the PostgresBackupSchedule crons of the instance; `operatorIncrementalSchedule: none` (or an empty value) makes no incremental schedule |
| `ferret` | `Boolean` | day0, create-instance | `true`: a FerretDB for the instance; `false`: none (removes it) |
| `ferretReplicas`, `ferretReadOnlyReplicas` | `Integer` | day0, create-instance | FerretDB read-write proxies (1 or more) and read-only proxies (above 0 needs `highAvailability: true`) |
| `ferretExposure` | `Enum` | day0, create-instance | FerretDB Services: `clusterIP`, `internalLoadBalancer` or `loadBalancer` |
| `ferretSecretName`, `ferretReadOnlySecretName` | `String (name)` | day0, create-instance | FerretDB connection Secrets (default: the operator's `<instance>-app-user-db-secret`, `<instance>-read-only-user-db-secret`) |
| `enableSSL` | `Boolean` | day0, create-instance | As `backupEnableSSL` |
| `exposure`, `readOnlyExposure` | `Enum` | day0, create-instance | `clusterIP`, `internalLoadBalancer` or `loadBalancer` (section 4) |
| `serviceAnnotations`, `readOnlyServiceAnnotations` | `Map` | day0, create-instance | Extra Service annotations |
| `allowedSourceRanges` | `List (CIDRs)` | day0, create-instance | Client ranges a load balancer accepts |
| `internalLoadBalancerSubnet` | `String (Azure name)` | day0, create-instance | Subnet of an internal load balancer |
| `networkPolicy` | `Enum` | day0, create-instance | `none` or `baseline` (section 9) |
| `ingressFromNamespaces` | `List` | day0, create-instance, network-policy | Namespaces allowed on 5432 |
| `ingressFromPodLabels` | `Map` | day0, create-instance, network-policy | Pod labels allowed on 5432 |
| `ingressFromCidrs`, `egressToCidrs` | `List (CIDRs)` | day0, create-instance, network-policy | Client ranges allowed on 5432; extra egress ranges |
| `egressToFqdns` | `List (host names)` | day0, create-instance, network-policy | Egress host names (needs ACNS) |
| `postgresPatchFilePath`, `valuesPatchFilePath` | `String (file path)` | patch, create-instance | Instance patch files of the submitting machine (their contents in `patchFiles`); stored as `charts/tpg-instance/patches/<name>-<uid>.yaml` (create-instance: applied when the instance is created, section 5) |
| `patchMode` | `Enum` | patch | `apply` or `clear`, for the instance files of this instance |
| `preUpgradeBackup`, `allowMajor` | `Boolean` | upgrade | As the inputs |
| `replicas` | `Integer` | scale (required: key or input) | Read replicas |
| `enableHAIfNeeded` | `Boolean` | scale | As the input |
| `backupType` | `Enum` | backup | As the input |
| `backupTimeoutSeconds` | `Integer` | backup | As the input |
| `retentionDays` | `Integer` | backup-retention | As the input |
| `finalBackup` | `Enum` | delete-instance, delete-apps | As the input |
| `purgePvcs`, `purgeNamespace` | `Boolean` | delete-instance, delete-apps | As the inputs |

A map in a parameter file:

```yaml
# scale.yaml
pushMode: direct
clusterMap: |
  aks-tpg-poc-01:
    instances:
      orders-db: {replicas: 2}
      billing-db: {replicas: 0}
  aks-tpg-poc-02:
    maxReadReplicas: 4                 # a new cap, written with the scale
    instances:
      orders-db: {replicas: 4, postgresVersion: postgres-17.6}
```

```bash
argo submit --from workflowtemplate/tpg-scale-instance --parameter-file scale.yaml --watch
# the same map inline as JSON
argo submit --from workflowtemplate/tpg-scale-instance -p pushMode=direct \
  -p clusterMap='{"aks-tpg-poc-01":{"instances":{"orders-db":{"replicas":2},"billing-db":{"replicas":0}}}}' --watch
```

---

## 4. tpg-day0

Plans the inputs into `clusters/fleet.yaml`, pre-checks every selected cluster, writes the plan of the clusters that passed (one commit), installs cert-manager (and the standalone monitoring agent) as Helm releases, then syncs the operator and instance Applications: by default wave 0 alone first, then the other waves in batches of `maxParallel` (`rolloutMode`). Each cluster is deployed under the mutex `tpg-cluster-<cluster>`, so no other tpg workflow changes it at the same time. A cluster that fails the pre-check gets no `fleet.yaml` entries and is not changed; the others go ahead, and the run ends `Failed` in its last step (`gate`), with the blocked clusters and their reasons in the report.

The operator step waits until the Postgres CRDs are Established and the operator Deployment is available on the target, then hard-refreshes the Application, so it does not wait for the Argo CD cache. An instance is ready when the Postgres resource reports `Running` and its StatefulSets are ready; Argo CD shows it Progressing until then.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `clusters` | `List` | yes, without `clusterMap` | | Registered clusters or `all` |
| `instances` | `List` | yes, without `clusterMap` | | Instances to deploy on every selected cluster (namespace `pg-<instance>`) |
| `clusterMap` | `Map` | no | | Targets and per-target values (section 3); replaces `clusters` and `instances` |
| `highAvailability` | `Boolean` | yes (input or map key) | | `true` (primary and standby, plus `readReplicas`) or `false` (single node) |
| `operatorVersion` | `String (version)` | yes (input or map key) | | Operator chart version |
| `postgresVersion` | `String (version)` | yes (input or map key) | | PostgresVersion name |
| `pushMode` | `Enum` | yes | | `direct` or `pr` |
| `readReplicas` | `Integer` | no | `1` with `highAvailability=true` | Read replicas, only with `highAvailability=true`: 1 to `maxReadReplicas` (default 3); empty means 1, 0 is refused. With `highAvailability=false` leave it empty (or 0): the instance is a single node, written as `readReplicas: 0`, and a value above 0 is refused |
| `storageSize`, `walStorageSize` | `String (quantity)` | no | template (`20Gi`, `10Gi`) | Volume sizes |
| `storageClass` | `String (name)` | no | template (`tpg-data-retain`) | StorageClass |
| `cpu`, `memory` | `String (quantity)` | no | template (requests 1/2Gi, limits 2/4Gi) | Request and limit per Postgres pod |
| `backupSchedule` | `Enum` | no | `fleet` | `fleet`: included in `tpg-backup-full` and `tpg-backup-incr`; `none`: excluded; `operator`: excluded, and the operator backs the instance up on its own PostgresBackupSchedule objects (`operatorFullSchedule`, `operatorIncrementalSchedule`; section 13). A re-run writes this input too: repeat `backupSchedule=operator` (or `none`) for the instances that use it, or the entry returns to `fleet` and the sync removes the schedules |
| `operatorFullSchedule` | `String (cron)` | no | `0 0 * * 0` | `backupSchedule=operator`: cron (UTC) of the full backups |
| `operatorIncrementalSchedule` | `String (cron)` | no | `0 0 * * 1-6` | `backupSchedule=operator`: cron (UTC) of the incremental backups; empty: full backups only |
| `installAddons` | `Boolean` | no | `true` | Install or upgrade cert-manager (and the standalone monitoring agent) |
| `existingAddons` | `Enum` | no | `skip` | A Helm release that differs: `skip` or `upgrade` (section 12) |
| `monitoringOption` | `Enum` | no | `tpg-settings` | Override: `none`, `azure`, `standalone` |
| `backupEnableSSL` | `Boolean` | no | `false` | `enableSSL` of the instances' `PostgresBackupLocation`: `false` uses HTTP to Azure Blob (the storage account must accept HTTP, Terraform `backup_storage_https_only = false`); `true` uses HTTPS and writes the storage account's CA bundle (`tpg-settings` `backupCaBundle`, from Terraform) as `caBundle` |
| `exposure` | `Enum` | no | `clusterIP` | Read-write Service of each instance: `clusterIP` (inside the cluster), `internalLoadBalancer` (Azure internal load balancer, an IP of the cluster VNet) or `loadBalancer` (public IP) |
| `serviceAnnotations` | `Map` | no | | Extra annotations of the read-write Service, for example `{service.beta.kubernetes.io/azure-dns-label-name: orders}` |
| `readOnlyExposure` | `Enum` | no | `clusterIP` | Read-only Service of an HA instance, same values |
| `readOnlyServiceAnnotations` | `Map` | no | | Extra annotations of the read-only Service |
| `allowedSourceRanges` | `List (CIDRs)` | no | | Client ranges a load balancer accepts (annotation `service.beta.kubernetes.io/azure-allowed-ip-ranges`) |
| `internalLoadBalancerSubnet` | `String (Azure name)` | no | | `internalLoadBalancer`: subnet of the cluster VNet for the load balancer IP (empty: the node subnet) |
| `networkPolicy` | `Enum` | no | `none` | `none`, or `baseline`: default deny plus the flows the instance needs, then the rules below (section 9) |
| `ingressFromNamespaces` | `List` | no | | `baseline`: namespaces whose pods may connect on 5432 |
| `ingressFromPodLabels` | `Map` | no | | `baseline`: pod labels allowed on 5432, in `ingressFromNamespaces` or in any namespace |
| `ingressFromCidrs` | `List (CIDRs)` | no | | `baseline`: client ranges allowed on 5432 (clients through a load balancer) |
| `egressToCidrs` | `List (CIDRs)` | no | | `baseline`: extra ranges the instance pods may reach |
| `egressToFqdns` | `List (host names)` | no | | `baseline`: host names the instance pods may reach; needs ACNS (Terraform `acns_enabled`) |
| `ferret` | `Boolean` | no | | `true`: a FerretDB (MongoDB wire protocol on 27017, PostgresFerretDocumentDB, Tech Preview) for each instance; `false`: none (removes it); empty: an existing instance keeps what it has. Needs Postgres 17.5 or later and the documentdb extension, which you prepare by hand (below) |
| `ferretReplicas` | `Integer` | no | `1` | FerretDB read-write proxies (1 or more) |
| `ferretReadOnlyReplicas` | `Integer` | no | `0` | FerretDB read-only proxies on the standby; above 0 needs `highAvailability=true` |
| `ferretExposure` | `Enum` | no | `clusterIP` | FerretDB Services `ferretdb-rw-<instance>` and `ferretdb-ro-<instance>`: `clusterIP`, `internalLoadBalancer` or `loadBalancer`, with the instance's `allowedSourceRanges` and `internalLoadBalancerSubnet` |
| `ferretSecretName` | `String (name)` | no | `<instance>-app-user-db-secret` | Connection Secret of the read-write proxies (created by the operator with the instance) |
| `ferretReadOnlySecretName` | `String (name)` | no | `<instance>-read-only-user-db-secret` | Connection Secret of the read-only proxies |
| `maxParallel` | `Integer` | no | `2` | Clusters per batch after the canary |
| `rolloutMode` | `Enum` | no | `canary` | `canary`, `batches` or `all` (section 2) |
| `dryRun` | `Boolean` | no | `false` | Show the `fleet.yaml` change and run the pre-check only |
| `syncTimeoutSeconds`, `prTimeoutSeconds` | `Integer` | no | `1800`, `3600` | Timeouts |

The pre-check is read-only and runs before anything is written to Git. A cluster that fails it is `BLOCKED`:

| Reason | The cluster is blocked when |
|---|---|
| `FOREIGN_OPERATOR`, `FOREIGN_CRD` | An operator Deployment or a Postgres CRD exists that the cluster's operator Application (`tpg-<cluster>-operator`) does not manage. The operator Deployment (found by its label `app=postgres-operator` or by its image) is ours when its Argo CD tracking annotation names that Application. A CRD is ours when the Application lists it in its resource list or its annotation names it, because the CRDs, installed from the chart's `crds/` directory, carry no annotation. A cluster the fleet deployed is `MANAGED`, never foreign |
| `INSTANCE_NAME_IN_USE` | A Postgres of a requested name exists that its instance Application does not manage |
| `VERSION_NOT_AVAILABLE` | A requested Postgres version is not offered by the running operator (`kubectl get postgresversion`) |
| `AZURE_BACKUP_UNSUPPORTED` | The PostgresBackupLocation CRD on the target has no `spec.storage.azure` (or no `caBundle` for `backupEnableSSL=true`). The 4.5 documentation lists S3 and GCS only; the workflows rely on the live CRD |
| `PGDATA_POOL_NOT_HA_CAPABLE` | `highAvailability=true` and the pool labelled `tpg.fleet/pool=postgres` has fewer than 3 Ready nodes across zones 1, 2 and 3 |
| `CILIUM_NOT_AVAILABLE` | `networkPolicy=baseline` and the cluster has no CiliumNetworkPolicy (Azure CNI powered by Cilium) |
| `ACNS_NOT_ENABLED` | `egressToFqdns` is set and `tpg-settings` `acnsEnabled` is not `true` |
| `FERRET_VERSION_UNSUPPORTED` | `ferret=true` for an instance below Postgres 17.5 |
| `FERRET_CRD_MISSING` | `ferret=true` and the running operator has no PostgresFerretDocumentDB CRD (a new operator is checked again after its sync, and the deploy step fails `FERRET_CRD_MISSING`) |
| `UPGRADE_REQUIRED`, `DOWNGRADE_NOT_ALLOWED`, `VERSION_UNKNOWN` | The target runs other versions (below) |
| `UNREACHABLE` | The API server does not answer the hub |

Warnings (the run goes on): `ORPHAN_CRD` (Postgres CRDs without any operator: the operator sync adopts them), `HA_NODES_EXCEED_ZONES` (an HA instance has more database pods, 1 + `readReplicas`, than the data pool has zones: the 4.5 release notes say that Patroni does not fail over automatically when the zone holding the leader and the synchronous standby is lost), `EXPOSURE_UNRESTRICTED` (`loadBalancer` without `allowedSourceRanges`), `FERRET_EXTENSION_REQUIRED` (a run with `ferret=true`: FerretDB needs the documentdb extension in the instance, which the workflows do not install).

**FerretDB** (design decision D71, Tech Preview in operator 4.5). With `ferret=true` the chart renders a PostgresFerretDocumentDB named like the instance, in sync wave 2 (after the instance is Healthy). The deploy step then checks that the connection Secrets it names exist (`FERRET_SECRET_MISSING`, with the db Secrets found in `pg-<instance>`; set `ferretSecretName` when the operator names them differently) and that the FerretDB Deployments become available (`FERRET_NOT_READY`, usually the missing documentdb extension). The documentdb extension (`shared_preload_libraries = 'pg_cron,pg_documentdb_core,pg_documentdb'`, `cron.database_name`, the `documentdb` database) is prepared by the DBA as the 4.5 documentation shows ("Using FerretDB for PostgreSQL for Kubernetes"); extensions are out of scope of the fleet. With `networkPolicy=baseline`, port 27017 is open to the same clients as 5432 (section 9).

**Backups by the operator** (`backupSchedule=operator`, design decision D70). The instance leaves the CronWorkflows (`backup.scheduled: false`) and the chart renders `PostgresBackupSchedule` `<instance>-backup-full` (and `<instance>-backup-incremental` when `operatorIncrementalSchedule` is set), in sync wave 2. The chart refuses the schedules while `backup.scheduled` is not `false`, so an instance is never backed up by both. tpg-backup-retention expires the operator's backups by chain like the others.

`backupEnableSSL=true` needs the storage account's CA bundle in `tpg-settings` (`backupCaBundle`, written by `tpg-aks-infra/scripts/run.sh` from Terraform); without it the plan step fails with `CA_BUNDLE_MISSING` before anything changes. Between the steps the plan carries the bundle as `@tpg-settings:backupCaBundle@` (one workflow parameter is limited to 128 KiB), and the commit writes the PEM itself; it fails `CA_BUNDLE_MISSING` too when the bundle was removed from `tpg-settings` during the run.

**Re-running tpg-day0** on clusters it deployed is safe. The operator and its CRDs are `MANAGED`, instances that run the requested versions are left as they are, new instances are added, and every instance is checked after the sync: `Running`, backup stanza initialized, and its Services following `exposure` (`EXPOSURE_NOT_APPLIED` when the load balancer addresses do not appear within 5 minutes). To add instances to a running cluster without the operator and add-on steps, use tpg-create-instance (section 5).

**Versions: the cluster decides, not `fleet.yaml`.** `clusters/fleet.yaml` starts empty (`clusters: {}`); `clusters/fleet.example.yaml` shows a filled-in file. For each cluster, tpg-day0 compares the requested operator and Postgres versions with what runs on the target:

| On the target | Result |
|---|---|
| The operator (or the instance) does not run yet | The input is written to `fleet.yaml`, replacing any version declared there. The result carries `FLEET_OVERRIDDEN` with the old value |
| It runs the requested version | Nothing to change on the cluster; a different version declared in `fleet.yaml` is replaced (`FLEET_OVERRIDDEN`) |
| It runs an older version | `BLOCKED` `UPGRADE_REQUIRED`: use tpg-upgrade |
| It runs a newer version | `BLOCKED` `DOWNGRADE_NOT_ALLOWED` |
| The running version cannot be read | `BLOCKED` `VERSION_UNKNOWN`, unless `fleet.yaml` already declares the requested operator version |

A blocked cluster keeps its `fleet.yaml` entry as it was; the other clusters go ahead.

```bash
# 1. Dry run on every registered cluster: validation, fleet.yaml diff, pre-check
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=all -p instances=orders-db -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 \
  -p pushMode=direct -p dryRun=true --watch

# 2. Deploy orders-db with HA and 2 read replicas on all clusters, direct push
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=all -p instances=orders-db -p highAvailability=true -p readReplicas=2 \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct --watch

# 3. Two single-node instances on one new cluster, sized, reviewed through a pull request
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=aks-tpg-poc-04 -p instances=billing-db,reporting-db -p highAvailability=false \
  -p operatorVersion=4.5.0 -p postgresVersion=17.6 \
  -p storageSize=100Gi -p walStorageSize=20Gi -p cpu=2 -p memory=8Gi \
  -p pushMode=pr -p prTimeoutSeconds=7200 --watch

# 4. Lab instance excluded from scheduled backups; cert-manager already installed
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=aks-tpg-poc-03 -p instances=scratch-db -p highAvailability=false \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct \
  -p backupSchedule=none -p installAddons=false --watch

# 5. Three batches of 3 clusters after the canary, longer sync timeout
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=all -p instances=orders-db -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct \
  -p maxParallel=3 -p syncTimeoutSeconds=3600 --watch

# 6. Every cluster at once (no canary), backups over HTTPS (caBundle from tpg-settings)
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=all -p instances=orders-db -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct \
  -p rolloutMode=all -p backupEnableSSL=true --watch

# 7. Internal load balancer in a subnet of the cluster VNet, open to one client range
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=aks-tpg-poc-01 -p instances=orders-db -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct \
  -p exposure=internalLoadBalancer -p internalLoadBalancerSubnet=apps-subnet \
  -p allowedSourceRanges=10.20.0.0/16 --watch

# 8. Default-deny network policy: only pods of namespace orders-app reach the database
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=aks-tpg-poc-01 -p instances=orders-db -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct \
  -p networkPolicy=baseline -p ingressFromNamespaces=orders-app --watch

# 9. Backups by the operator (full on Sunday 01:00 UTC, no incrementals) and FerretDB
#    with one read-only proxy on an HA instance, behind an internal load balancer
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=aks-tpg-poc-01 -p instances=docs-db -p highAvailability=true -p readReplicas=1 \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct \
  -p backupSchedule=operator -p operatorFullSchedule='0 1 * * 0' -p operatorIncrementalSchedule= \
  -p ferret=true -p ferretReadOnlyReplicas=1 -p ferretExposure=internalLoadBalancer --watch
```

With a parameter file:

```yaml
# day0-orders.yaml
clusters: aks-tpg-poc-01,aks-tpg-poc-02,aks-tpg-poc-03
instances: orders-db
highAvailability: "true"
readReplicas: "1"
operatorVersion: v4.5.0
postgresVersion: postgres-17.6
pushMode: direct
```

```bash
argo submit --from workflowtemplate/tpg-day0 --parameter-file day0-orders.yaml --watch
```

Different settings per cluster and instance, with `clusterMap`. The inputs are the defaults (here `operatorVersion`, `postgresVersion` and `highAvailability`), and each map key overrides them:

```yaml
# day0-map.yaml
pushMode: direct
operatorVersion: v4.5.0
postgresVersion: postgres-17.6
highAvailability: "true"
clusterMap: |
  aks-tpg-poc-01:
    instances:
      orders-db: {readReplicas: 2, memory: 8Gi, exposure: internalLoadBalancer}
      billing-db: {highAvailability: false, backupSchedule: none}
  aks-tpg-poc-02:
    maxReadReplicas: 5
    instances:
      orders-db:
        postgresVersion: postgres-16.10
        storageSize: 50Gi
        networkPolicy: baseline
        ingressFromNamespaces: [orders-app, reporting]
        ingressFromPodLabels: {app.kubernetes.io/part-of: orders}
```

```bash
argo submit --from workflowtemplate/tpg-day0 --parameter-file day0-map.yaml -p dryRun=true --watch
```

---

## 5. tpg-create-instance

Adds Postgres instances to clusters that already run the fleet's operator (deployed by tpg-day0). Each cluster can get its own instances and values (`clusterMap`), or every listed instance goes to every listed cluster. The instance inputs are those of tpg-day0; a postgres and a values patch file of the machine that submits the run can be given as well (their contents in `patchFiles`, as for tpg-patch, section 7) and shape the instance from its first render. Each is stored as `charts/tpg-instance/patches/<name>-<uid>.yaml` and recorded as the instance's current patch. The operator, the add-ons and instances that already run are not touched.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `clusters` | `List` | yes, without `clusterMap` | | Registered clusters that run the fleet's operator (`all` is not accepted) |
| `instances` | `List` | yes, without `clusterMap` | | New instances, created on every listed cluster (namespace `pg-<instance>`) |
| `clusterMap` | `Map` | no | | Each cluster with its own instances and values (section 3); replaces `clusters` and `instances` |
| `highAvailability` | `Boolean` | yes (input or map key) | | `true` (primary and standby, plus `readReplicas`) or `false` (single node) |
| `postgresVersion` | `String (version)` | yes (input or map key) | | A PostgresVersion the cluster's operator offers |
| `pushMode` | `Enum` | yes | | `direct` or `pr` |
| `readReplicas` | `Integer` | no | `1` with `highAvailability=true` | Read replicas, only with `highAvailability=true` (1 to `maxReadReplicas`; empty means 1, 0 is refused). Above 0 with `highAvailability=false` is refused |
| `storageSize`, `walStorageSize` | `String (quantity)` | no | template (`20Gi`, `10Gi`) | Volume sizes |
| `storageClass` | `String (name)` | no | template (`tpg-data-retain`) | StorageClass |
| `cpu`, `memory` | `String (quantity)` | no | template | Request and limit per Postgres pod |
| `backupSchedule` | `Enum` | no | `fleet` | `fleet`, `none` (excluded from the backup CronWorkflows) or `operator` (PostgresBackupSchedule objects instead, section 4) |
| `operatorFullSchedule`, `operatorIncrementalSchedule` | `String (cron)` | no | `0 0 * * 0`, `0 0 * * 1-6` | As tpg-day0 |
| `backupEnableSSL` | `Boolean` | no | `false` | As tpg-day0; `true` writes the storage account's CA bundle as `caBundle` |
| `exposure`, `readOnlyExposure` | `Enum` | no | `clusterIP` | As tpg-day0 |
| `serviceAnnotations`, `readOnlyServiceAnnotations` | `Map` | no | | As tpg-day0 |
| `allowedSourceRanges` | `List (CIDRs)` | no | | As tpg-day0 |
| `internalLoadBalancerSubnet` | `String (Azure name)` | no | | As tpg-day0 |
| `networkPolicy` | `Enum` | no | `none` | As tpg-day0 (section 9) |
| `ingressFromNamespaces` | `List` | no | | As tpg-day0 |
| `ingressFromPodLabels` | `Map` | no | | As tpg-day0 |
| `ingressFromCidrs`, `egressToCidrs` | `List (CIDRs)` | no | | As tpg-day0 |
| `egressToFqdns` | `List (host names)` | no | | As tpg-day0; needs ACNS |
| `ferret` | `Boolean` | no | | As tpg-day0: a FerretDB for each new instance (Postgres 17.5 or later) |
| `ferretReplicas`, `ferretReadOnlyReplicas` | `Integer` | no | `1`, `0` | As tpg-day0 |
| `ferretExposure` | `Enum` | no | `clusterIP` | As tpg-day0 |
| `ferretSecretName`, `ferretReadOnlySecretName` | `String (name)` | no | | As tpg-day0 |
| `postgresPatchFilePath` | `String (file path)` | no | | A Postgres patch file of your machine, merged into the new instance (creation rules below) |
| `valuesPatchFilePath` | `String (file path)` | no | | A values patch file of your machine |
| `patchFiles` | `Map (JSON)` | with a patch file | | The contents of the files, `{"<path as given>": "<base64>"}`: `scripts/submit/tpg-create-instance.sh` fills it, `scripts/submit/pack-patch-files.sh FILE...` prints it |
| `maxParallel` | `Integer` | no | `2` | Clusters per batch after the canary |
| `rolloutMode` | `Enum` | no | `canary` | `canary`, `batches` or `all` (section 2) |
| `dryRun` | `Boolean` | no | `false` | Validate, plan, pre-check and dry-run; push and deploy nothing |
| `syncTimeoutSeconds`, `prTimeoutSeconds` | `Integer` | no | `1800`, `3600` | Per cluster, pull request |

The run, in order:

1. **Validate** the inputs and `clusterMap`; each patch file must be in `patchFiles` and fit its input (section 7, step 1).
2. **Plan** `clusters/fleet.yaml` (nothing is pushed yet). Per cluster: the operator must run (`OPERATOR_NOT_INSTALLED` otherwise) and be declared in `fleet.yaml` (`NOT_IN_FLEET`). Per instance: the patch files are stored under their UID names and checked against the creation rules (a declared instance whose current file holds the same contents keeps it, so a repeated run stays `ALREADY_EXISTS`), the instance is rendered with the chart, and the rendered Postgres object is sent to the cluster with `--dry-run=server` (in namespace `default`, under the name `tpg-create-probe`, because `pg-<instance>` does not exist yet), so the operator's admission webhooks judge it before anything is written.
3. **Pre-check** as tpg-day0, with the operator required to be `MANAGED` (section 4).
4. **Commit** the plan of the clusters that passed, without the instances that were blocked, with the stored patch files their entries reference.
5. **Deploy** the new instance Applications, canary first, one run at a time per cluster (the mutex `tpg-cluster-<cluster>`, shared with tpg-day0, tpg-patch, tpg-network-policy and tpg-delete-apps). Each instance is checked like in tpg-day0: `Running`, backup stanza, FerretDB when `ferret=true`, Services following `exposure`.
6. **Gate:** the run ends `Failed` when a cluster or an instance was `BLOCKED`.

| Result of an instance | When |
|---|---|
| `SUCCEEDED` | Created and checked |
| `SUCCEEDED` `ALREADY_EXISTS` | Declared in `fleet.yaml` and running with the requested values: nothing changed, so a re-run is safe |
| `BLOCKED` `INSTANCE_EXISTS` | It runs with other values or another version: use tpg-patch, tpg-scale-instance or tpg-upgrade |
| `BLOCKED` `INSTANCE_NAME_IN_USE` | A Postgres of that name runs but is not declared in `fleet.yaml` |
| `BLOCKED` `PATCH_REFUSED` | A patch file breaks a creation rule (the detail names the file and the field) |
| `BLOCKED` `RENDER_FAILED`, `DRY_RUN_REJECTED` | The chart cannot render the instance, or the API server or the operator's webhooks refuse it |

An instance that is declared in `fleet.yaml` but absent on the cluster (for example after a blocked tpg-day0) is deployed from its entry, with the note `DECLARED_NOT_DEPLOYED`.

**Creation rules for patch files.** Nothing runs yet, so a patch file may set more than in tpg-patch: sizes and `spec.storageClassName` are allowed. Refused, because each of these values has one source:

| Kind | Refused |
|---|---|
| Postgres patch | Anything but `apiVersion`, `kind: Postgres` and `spec`; a field the Postgres CRD does not have; `spec.postgresVersion`, `spec.highAvailability` (the inputs); `spec.serviceType`, `spec.serviceAnnotations`, `spec.readOnlyServiceType`, `spec.readOnlyServiceAnnotations` (the exposure inputs) |
| Values patch | A key the chart does not have; `instance.name`, `instance.postgresVersion`, `instance.highAvailability`, `instance.serviceType` (replaced by `instance.exposure`), `cluster`, `patches`, `valuesOverride` (tpg-restore) |

```bash
# 1. Dry run: a single-node instance on two clusters
argo submit --from workflowtemplate/tpg-create-instance \
  -p clusters=aks-tpg-poc-01,aks-tpg-poc-02 -p instances=reports-db \
  -p highAvailability=false -p postgresVersion=postgres-17.6 -p pushMode=direct -p dryRun=true --watch

# 2. An HA instance behind an internal load balancer, with its own resources patch
#    (from the directory that holds audit-resources.yaml; PACK as in section 7)
PACK=~/src/tpg-fleet/scripts/submit/pack-patch-files.sh
argo submit --from workflowtemplate/tpg-create-instance \
  -p clusters=aks-tpg-poc-01 -p instances=audit-db -p highAvailability=true -p readReplicas=1 \
  -p postgresVersion=postgres-17.6 -p exposure=internalLoadBalancer -p allowedSourceRanges=10.20.0.0/16 \
  -p postgresPatchFilePath=./audit-resources.yaml \
  -p patchFiles="$($PACK ./audit-resources.yaml)" \
  -p pushMode=pr --watch
```

Different instances per cluster, with `clusterMap`:

```yaml
# create-map.yaml
pushMode: direct
postgresVersion: postgres-17.6
highAvailability: "false"
clusterMap: |
  aks-tpg-poc-01:
    instances:
      reports-db: {storageSize: 100Gi}
      audit-db:
        highAvailability: true
        readReplicas: 1
        networkPolicy: baseline
        ingressFromNamespaces: [audit]
  aks-tpg-poc-02:
    instances:
      reports-db: {postgresVersion: postgres-16.10, backupSchedule: none}
```

```bash
argo submit --from workflowtemplate/tpg-create-instance --parameter-file create-map.yaml --watch
```

---

## 6. tpg-upgrade

Upgrades the operator (`component=operator`) or Postgres instances (`component=postgres`), canary first, and writes the new version to `clusters/fleet.yaml`. With `clusterMap`, one run can upgrade the operator and instances to versions that differ per cluster and per instance.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `component` | `Enum` | yes, without `clusterMap` | | `operator` or `postgres`. With `clusterMap`: limits the run to that part, and makes `targetVersion` its default version |
| `targetVersion` | `String (version)` | yes, without `clusterMap` | | Operator: `v4.5.1`; Postgres: `postgres-17.6` |
| `clusters` | `List` | yes, without `clusterMap` | | Registered clusters or `all` |
| `instances` | `List` | yes for `postgres`, without `clusterMap` | | Instances or `all`; not allowed for `operator` |
| `clusterMap` | `Map` | no | | `operatorVersion` per cluster, `postgresVersion`, `preUpgradeBackup` and `allowMajor` per instance (section 3) |
| `pushMode` | `Enum` | yes | | `direct` or `pr` |
| `preUpgradeBackup` | `Boolean` | no | `true` | Full backup of each affected instance first |
| `allowMajor` | `Boolean` | no | `false` | Allow major Postgres upgrades; pauses for approval before every batch after the canary |
| `maxParallel` | `Integer` | no | `1` | Clusters per batch after the canary |
| `rolloutMode` | `Enum` | no | `canary` | `canary`, `batches` or `all` (section 2). With `allowMajor=true`, the approval pause comes before every batch after the first |
| `dryRun` | `Boolean` | no | `false` | Record the planned upgrade (minor or major, current and target) per target |
| `timeoutSeconds`, `prTimeoutSeconds` | `Integer` | no | `1800`, `3600` | Per cluster (operator) or per instance (Postgres) |

Minor or major is detected per instance. Downgrades fail. Instances not selected are reported as `SKIPPED_NOT_SELECTED`. An operator upgrade requires every instance that exists on the cluster to be `Running`; an instance declared in `fleet.yaml` that does not exist on the cluster (never deployed, for example after a blocked tpg-day0) is left out with the warning `INSTANCE_NOT_DEPLOYED`. Only a NotFound answer counts as absent: any other error reading the instance (API timeout, permissions) fails the cluster with `CLUSTER_API_ERROR`. With `clusterMap`, every listed instance must be declared on its cluster, and on each cluster the operator is upgraded first; the Postgres part does not start on a cluster whose operator upgrade failed.

A Postgres upgrade of one instance runs in this order:

1. Full backup (`preUpgradeBackup=true`).
2. `PostgresVersionUpgrade` created on the target and followed with the instance pods printed every 5 seconds; `Failed` or `PreCheckFailed` ends the instance as `FAILED` with the operator's message.
3. The instance is `Running` with the target `status.dbVersion` (`DB_VERSION_MISMATCH` otherwise).
4. The workflow waits up to 5 minutes for the operator to set `spec.postgresVersion.name` to the target (each poll is logged); if it does not, it logs that and goes on, because Argo CD ignores that field.
5. The version is written to `clusters/fleet.yaml`, pushed, and the Application is synced at that commit.
6. `SUCCEEDED` only when the Application is Synced. Otherwise the instance is `FAILED` with the sync reason (`SYNC_REJECTED`, `SYNC_DRIFT`, ...) and the detail "database upgraded to ..., but the Application did not sync", and the later batches do not run.

The `tpg-instances` ApplicationSet ignores `Postgres spec.postgresVersion` (`RespectIgnoreDifferences=true`), so the operator's admission webhook (`postgresVersion.name cannot be changed ...`) does not reject the sync.

**The operator image of a values patch.** A current operator values patch (section 7) that sets `operatorImage` carries the tag of the running version. The version commit stores a copy of that file with the new tag under a new UID name and makes it current (the old file is never changed and becomes `previous` with its commit), and rewrites its copy `patches/operator/clusters/<cluster>.yaml`, so the image follows the chart. A tag that is not the running version stops the upgrade before anything changes (`OPERATOR_IMAGE_PINNED`); so does a Round 11 list of several operator values files, which Round 14 no longer applies (`OPERATOR_PATCH_LIST`). Operator manifest patches and the input `operatorPatches` were removed in Round 14.

```bash
# 1. Operator: dry run on all clusters
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=operator -p targetVersion=v4.5.1 -p clusters=all -p pushMode=direct -p dryRun=true --watch

# 2. Operator: canary cluster only, through a pull request
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=operator -p targetVersion=v4.5.1 -p clusters=aks-tpg-poc-01 -p pushMode=pr --watch

# 3. Operator: remaining clusters two at a time, without pre-upgrade backups
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=operator -p targetVersion=v4.5.1 -p clusters=aks-tpg-poc-02,aks-tpg-poc-03 \
  -p pushMode=direct -p maxParallel=2 -p preUpgradeBackup=false --watch

# 4. Postgres minor upgrade of every instance on every cluster
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=postgres -p targetVersion=postgres-16.10 -p clusters=all -p instances=all \
  -p pushMode=direct --watch

# 5. Postgres major upgrade of orders-db, with approval between batches
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=postgres -p targetVersion=postgres-17.6 -p clusters=all -p instances=orders-db \
  -p allowMajor=true -p pushMode=pr -p timeoutSeconds=7200 --watch
argo resume @latest          # approve the next batch after checking the canary

# 6. Postgres minor upgrade of two instances on one cluster
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=postgres -p targetVersion=17.7 -p clusters=aks-tpg-poc-02 \
  -p instances='orders-db,billing-db' -p pushMode=direct --watch
```

Different versions per cluster and instance, with `clusterMap`:

```yaml
# upgrade-map.yaml
pushMode: direct
clusterMap: |
  aks-tpg-poc-01:
    operatorVersion: v4.5.1              # operator first, then the instances below
    instances:
      orders-db: {postgresVersion: postgres-17.7}
  aks-tpg-poc-02:
    instances:
      orders-db: {postgresVersion: postgres-17.6, allowMajor: true}
      billing-db: {postgresVersion: postgres-16.10, preUpgradeBackup: false}
```

```bash
argo submit --from workflowtemplate/tpg-upgrade --parameter-file upgrade-map.yaml --watch
```

---

## 7. tpg-patch

Changes settings of deployed operators and instances that no other workflow owns (Round 14, design decisions D76 to D79). You write a patch file on the machine where you run `argo`, pass its relative path, and the workflow stores it in the fleet repository, checks it, shows what it changes, and syncs it. There are three kinds of patch file, each with its own input and `clusterMap` key:

| Input and map key | Level | Stored as | Content | How it is applied |
|---|---|---|---|---|
| `postgresPatchFilePath` | instance | `charts/tpg-instance/patches/<name>-<uid>.yaml` | `apiVersion: sql.tanzu.vmware.com/v1`, `kind: Postgres` and a `spec` fragment; every field is checked against the Postgres CRD | The tpg-instance chart reads the file (`.Files.Get`) and merges it into the rendered Postgres `spec` |
| `valuesPatchFilePath` | instance | `charts/tpg-instance/patches/<name>-<uid>.yaml` | A fragment of the chart values; every key must exist in `charts/tpg-instance/values.yaml` or `clusters/_template/`, for example `backup.fullRetention` | Merged into the instance's values before the chart renders |
| `operatorValuesPatchFilePath` | cluster | `patches/operator/<name>-<uid>.yaml` | Only these operator chart values: `operatorImage`, `instanceRegistryRepo`, `ferretDBImageRepo`, `dockerRegistrySecretName`, `certManagerClusterIssuerName`, `certManagerNamespace`, `resources` (`limits` and `requests`, `cpu` and `memory`), `enableSecurityContext`. Any other key fails the run | Copied to `patches/operator/clusters/<cluster>.yaml`, which the `tpg-operator` Application reads as `$fleet/patches/operator/clusters/<cluster>.yaml` |

Operator manifest patches (`operatorManifestPatchFilePath`, server-side apply as field manager `tpg-patch`) were removed in Round 14 (D76).

**The files come from your machine.** The workflow runs on the hub and cannot read your files, so their contents travel in the input `patchFiles`, a JSON map of the path as you gave it to the file's base64. `scripts/submit/tpg-patch.sh` fills it for you; with plain `argo submit`, `scripts/submit/pack-patch-files.sh FILE...` of your tpg-fleet clone prints it (the examples call it `$PACK`). Run it and `argo submit` from the directory that holds the patch files, and give each path relative to it (no leading `/`, no `..`), one `.yaml` or `.yml` file per kind and target; a file may have 256 KiB and `patchFiles` (the base64 JSON) 512 KiB. Linux limits one command-line argument to 128 KiB, which `-p patchFiles=...` reaches with about 90 KiB of files: for larger files write it to a parameter file with `$PACK -o FILE.yaml ...` and submit with `--parameter-file FILE.yaml` (the submit scripts always do). The workflow stores each file under its own name plus a unique 5-character UID (`orders-backup.yaml` becomes `orders-backup-k3x9q.yaml`).

**One current file per kind.** `clusters/fleet.yaml` records, per target and kind, the file that is applied (`current`) and the one before it with the commit that added it (`previous`):

```yaml
clusters:
  aks-tpg-poc-01:
    operator:
      version: v4.5.0
      patches:
        values:
          current: patches/operator/operator-resources-q7m2d.yaml   # repository path
    instances:
      orders-db:
        patches:
          values:
            current: patches/orders-backup-k3x9q.yaml               # relative to charts/tpg-instance/
            previous:
              path: patches/orders-retention-a81zd.yaml
              commit: 4f2c1e9a7b3d5c8e0f1a2b3c4d5e6f7a8b9c0d1e
```

Only `current` is applied, so a new file must hold every override you still want: the diff the workflow prints shows what the old file loses. `patchMode=clear` removes the current file of a kind (it becomes `previous`); name the stored file it removes as the path, for example `valuesPatchFilePath=charts/tpg-instance/patches/orders-backup-k3x9q.yaml`, and send no contents. A Round 11 list with one file counts as current; a list with more than one is refused until you merge the files into one (tpg-fleet README, Upgrading to Round 14).

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `clusters` | `List` | yes, without `clusterMap` | | Registered clusters or `all` |
| `instances` | `List` | with an instance patch file, without `clusterMap` | | Instances or `all`, on every selected cluster |
| `clusterMap` | `Map` | no | | Targets, with the patch file keys and `patchMode` per cluster and per instance (section 3) |
| `postgresPatchFilePath` | `String (file path)` | one patch file input or map key | | A Postgres patch file of your machine, for every selected instance |
| `valuesPatchFilePath` | `String (file path)` | one patch file input or map key | | A values patch file of your machine, for every selected instance |
| `operatorValuesPatchFilePath` | `String (file path)` | one patch file input or map key | | An operator values file of your machine, for every selected cluster |
| `patchFiles` | `Map (JSON)` | with `patchMode=apply` | | The contents of the files: `{"<path as given>": "<base64>"}`, from the submit script or `pack-patch-files.sh` |
| `patchMode` | `Enum` | no | `apply` | `apply`: the files become the current patches. `clear`: the current file named by the path is removed |
| `pushMode` | `Enum` | yes | | `pr`: per cluster a branch and pull request, synced before a person merges it. `direct`: per cluster a commit on the fleet branch |
| `maxParallel` | `Integer` | no | `1` | Clusters per batch after the canary |
| `rolloutMode` | `Enum` | no | `canary` | `canary`, `batches` or `all` (section 2) |
| `dryRun` | `Boolean` | no | `false` | Check, render, dry-run and print the diff; commit and sync nothing |
| `timeoutSeconds` | `Integer` | no | `1800` | Per operator and per instance |
| `prTimeoutSeconds` | `Integer` | no | `3600` | `pushMode=pr`: how long each cluster's pull request may wait for the merge before the cluster is synced back |

The run, in order:

1. **Validate** (before anything is read from Git). The inputs and `clusterMap`; every file must be in `patchFiles` and fit the input it was passed to: a Postgres manifest passed as `valuesPatchFilePath` is refused with the input it belongs to, chart values passed as `postgresPatchFilePath` likewise, an unknown value or Postgres field is named with the closest known key, and an operator key outside the list above is refused.
2. **Plan** (every cluster, nothing committed). On a clone of the fleet branch: the targets are rendered as they are, the files are stored and made current, the checks that need `clusters/fleet.yaml` or the cluster run (refused fields below, smaller volumes, the operator image tag, Secrets and issuers that must exist), the targets are rendered again with helm and sent through the API server with `--dry-run=server`, and the diff is printed: objects the patch no longer renders (the sync prunes them) and `kubectl diff --server-side` of the rendered objects against the live ones. A render or admission error blocks the cluster (`BLOCKED` `PATCH_REFUSED`, named in the log and the report). The fields the `tpg-instances` ApplicationSet ignores (`ignoreDifferences`) take their live values first, so the diff shows what Argo CD compares. A target with no difference is `NO_CHANGE` and is not synced; a cluster with none is not planned. A values patch that changes only what the workflows read on the hub and the chart does not render (`backup.scheduled`, which takes the instance out of the backup CronWorkflows) is committed and not synced.
3. **Apply**, canary first like tpg-day0, one cluster at a time per mutex. On a fresh clone of the fleet branch the step checks, renders and diffs again, then makes one commit with the stored files, `clusters/fleet.yaml` and, for the operator, `patches/operator/clusters/<cluster>.yaml`:
   - `pushMode=pr`: on the branch `tpg/patch/<workflow>/<cluster>`, with a pull request into the fleet branch whose body carries the diff. The Applications are synced at the branch commit **before the merge** (the operator first, source 2 of its multi-source Application; then each instance, with prune) and verified: the operator pods and CRD, the instance pods until `Running`, FerretDB and the Services. Then the workflow waits for a person to merge the pull request. Merged: the Applications compare the new fleet branch head with the objects synced from the branch, which are the same, so they turn Synced without a second sync. Closed without merging, or not merged within `prTimeoutSeconds`: the cluster is reverted (below) and the targets are `FAILED` `PR_NOT_MERGED`.
   - `pushMode=direct`: the commit goes to the fleet branch and the Applications are synced at it and verified the same way.
4. **Revert** when the sync or a check fails (or `PR_NOT_MERGED`): with `pushMode=pr` the pull request is closed first, so nobody can merge it any more; then each Application is synced back (at the fleet branch head of the step when it was Synced before, otherwise at the commit it was last synced at) and the branch deleted, so its commit is gone. A pull request a person merged before the failure is undone like `pushMode=direct`: a `git revert` of the commit (of the merge) is pushed to the fleet branch and the Applications are synced at it. The revert keeps every stored patch file `clusters/fleet.yaml` still names, because clusters of one run share the stored name of a file. The targets are `FAILED` with the reason of the failure, and later batches do not run.

With a `postgresVersion` key in `clusterMap`, an instance that runs another version is `SKIPPED_VERSION_MISMATCH` and left out. When a person merges the pull request with changes of their own and an Application stays OutOfSync after the merge, the target is `FAILED` `MERGED_CONTENT_DIFFERS` and nothing is synced or reverted: compare the pull request with the fleet branch.

**Refused fields.** A field that another workflow owns, or that cannot change on a running instance, is refused, and the message names the workflow to use:

| Kind | Refused |
|---|---|
| Postgres patch | Anything but `apiVersion`, `kind: Postgres` and `spec`; a field the Postgres CRD does not have; `spec.postgresVersion` (tpg-upgrade); `spec.highAvailability` (tpg-scale-instance); `spec.storageClassName`; a `storageSize` or `walStorageSize` smaller than the current one; `spec.serviceType`, `spec.serviceAnnotations`, `spec.readOnlyServiceType`, `spec.readOnlyServiceAnnotations` (set the exposure values in a values patch) |
| Values patch | A key the chart does not have; `instance.name`, `instance.postgresVersion` (tpg-upgrade), `instance.highAvailability` (tpg-scale-instance), `instance.storageClassName`, `instance.serviceType` (replaced by `instance.exposure`), `cluster`, `patches`, `valuesOverride` (tpg-restore); smaller sizes; `backup.additionalParameters`, `backup.enableSSL` and `backup.forcePathStyle`, which the `tpg-instances` ApplicationSet ignores on a running instance (set them when the instance is created) |
| Operator values | Every key but the eight above; `operatorImage` with another tag than the cluster's operator version (the image may move to another registry, its version changes with tpg-upgrade, which also moves the tag in the current file); a `dockerRegistrySecretName` other than `regsecret` without that Secret in `tanzu-postgres-operator`; a `certManagerClusterIssuerName` other than the default without that ClusterIssuer; a `certManagerNamespace` that does not exist |

**Switching the backup scheduler or FerretDB of a running instance** (D70, D71). A values patch may set `backup.scheduled` with `backup.operatorSchedules` (`{full: "0 0 * * 0", incremental: "0 0 * * 1-6"}`), and the `ferret` keys (`enabled`, `replicas`, `readOnlyReplicas`, `exposure`, `secretName`, `readOnlySecretName`). The chart refuses what the workflow inputs refuse (schedules while `backup.scheduled` is not `false`, FerretDB below Postgres 17.5, read-only proxies without HA), so the plan reports `PATCH_REFUSED`; FerretDB switched on is the warning `FERRET_EXTENSION_REQUIRED`. The CronWorkflows follow the values patch too: an instance whose current values patch sets `backup.scheduled: false` leaves them. The instance sync of tpg-patch prunes, so a patch that turns the schedules or FerretDB off removes those objects (the Postgres object and its backup location are `Prune=false` and stay).

```yaml
# ./orders-operator-backups.yaml, on your machine
backup:
  scheduled: false
  operatorSchedules: {full: "0 0 * * 0", incremental: "0 0 * * 1-6"}
```

**Changing the exposure of a running instance.** A values patch may set `instance.exposure`, `instance.readOnlyExposure`, `instance.serviceAnnotations`, `instance.readOnlyServiceAnnotations`, `instance.allowedSourceRanges` and `instance.internalLoadBalancerSubnet`, for example `instance: {exposure: internalLoadBalancer}`. After the sync the workflow waits until the Services match (`EXPOSURE_NOT_APPLIED` after 5 minutes); `loadBalancer` without `allowedSourceRanges` is the warning `EXPOSURE_UNRESTRICTED`. The network policy is changed with tpg-network-policy, not with a patch.

```bash
# Run from the directory that holds the patch files.
PACK=~/src/tpg-fleet/scripts/submit/pack-patch-files.sh   # the helper of your tpg-fleet clone
# 1. Dry run: raise the memory of orders-db on every cluster (prints the diff per cluster)
argo submit --from workflowtemplate/tpg-patch \
  -p clusters=all -p instances=orders-db \
  -p postgresPatchFilePath=./orders-memory.yaml \
  -p patchFiles="$($PACK ./orders-memory.yaml)" \
  -p pushMode=pr -p dryRun=true --watch

# 2. Apply it through pull requests, canary first, then two clusters at a time;
#    merge each cluster's pull request when the workflow waits for it
argo submit --from workflowtemplate/tpg-patch \
  -p clusters=all -p instances=orders-db \
  -p postgresPatchFilePath=./orders-memory.yaml \
  -p patchFiles="$($PACK ./orders-memory.yaml)" \
  -p pushMode=pr -p maxParallel=2 --watch

# 3. A values file for two instances on one cluster, committed to the fleet branch
argo submit --from workflowtemplate/tpg-patch \
  -p clusters=aks-tpg-poc-02 -p instances=orders-db,billing-db \
  -p valuesPatchFilePath=./backup-retention.yaml \
  -p patchFiles="$($PACK ./backup-retention.yaml)" \
  -p pushMode=direct --watch

# 4. Operator resources on two clusters
argo submit --from workflowtemplate/tpg-patch \
  -p clusters=aks-tpg-poc-01,aks-tpg-poc-02 \
  -p operatorValuesPatchFilePath=./operator-resources.yaml \
  -p patchFiles="$($PACK ./operator-resources.yaml)" \
  -p pushMode=pr --watch

# 5. Remove the current values patch of orders-db (name the stored file; no contents)
argo submit --from workflowtemplate/tpg-patch \
  -p clusters=aks-tpg-poc-02 -p instances=orders-db -p patchMode=clear \
  -p valuesPatchFilePath=charts/tpg-instance/patches/backup-retention-k3x9q.yaml \
  -p pushMode=direct --watch
```

```yaml
# ./operator-resources.yaml, on your machine
resources:
  limits: {cpu: 500m, memory: 300Mi}
  requests: {cpu: 500m, memory: 300Mi}
enableSecurityContext: true
```

Different files per cluster and instance, with `clusterMap` (every path in the map needs its contents in `patchFiles`):

```yaml
# patch-map.yaml
pushMode: pr
clusterMap: |
  aks-tpg-poc-01:
    operatorValuesPatchFilePath: ./operator-resources.yaml
    instances:
      orders-db:
        postgresPatchFilePath: ./orders-memory.yaml
        postgresVersion: postgres-17.6          # guard: skipped when it runs another version
  aks-tpg-poc-02:
    instances:
      orders-db:
        valuesPatchFilePath: ./backup-retention.yaml
```

```bash
# patchFiles goes into the same parameter file (-o adds or replaces its line)
$PACK -o patch-map.yaml ./operator-resources.yaml ./orders-memory.yaml ./backup-retention.yaml
argo submit --from workflowtemplate/tpg-patch --parameter-file patch-map.yaml --watch
```

---

## 8. tpg-scale-instance

Sets the read replica count of the selected instances in `clusters/fleet.yaml` (one commit for the run), then syncs and verifies each instance, cluster by cluster as `rolloutMode` says. It also changes `maxReadReplicas`, the cap on read replicas of a cluster, with a scale or alone (Round 14, D80).

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `clusters` | `List` | yes, without `clusterMap` | | Registered clusters (`all` is not accepted) |
| `instances` | `List` | with `replicas`, without `clusterMap` | | Instances to scale on every listed cluster (`all` is not accepted). Each instance must be declared on each listed cluster. Leave it empty to change only `maxReadReplicas` |
| `clusterMap` | `Map` | no | | `maxReadReplicas` per cluster, `replicas` and `enableHAIfNeeded` per instance (section 3; examples below) |
| `replicas` | `Integer` | with `instances` (input or map key) | | Read replicas, 1 to `maxReadReplicas`; `0` makes the instance a single node (high availability off) |
| `maxReadReplicas` | `Integer` | no | | The new cap for every selected cluster (`clusters.<cluster>.cluster.maxReadReplicas`, default 3), 1 or more; empty keeps it. It bounds the `replicas` of the same run. A cap below the read replicas an instance of the cluster has, or gets in this run, is refused in the validate step (`MAX_BELOW_CURRENT`) |
| `pushMode` | `Enum` | yes | | `direct` or `pr` |
| `enableHAIfNeeded` | `Boolean` | no | `true` | `replicas > 0` on an instance without HA: turn HA on (`true`), or refuse it (`false`): the validate step reads `clusters/fleet.yaml` and fails before any change for every single-node instance that would get `replicas` above 0 (`HA_DISABLED`) |
| `rolloutMode` | `Enum` | no | `all` | `all`: every cluster at once. `canary`: one wave-0 cluster first, then batches of `maxParallel`. `batches`: batches of `maxParallel`, no canary. A failed batch stops the later ones |
| `maxParallel` | `Integer` | no | `2` | Clusters per batch for `canary` and `batches` |
| `dryRun` | `Boolean` | no | `false` | Record the change only |
| `timeoutSeconds`, `prTimeoutSeconds` | `Integer` | no | `900`, `3600` | Per instance, pull request |

An instance that is not declared on one of the listed clusters fails the run with `UNKNOWN_INSTANCE` before anything changes. `replicas=0` scales the instance down to a single node, as the 4.5 documentation does: `clusters/fleet.yaml` gets `enabled: false` and `readReplicas: 0`, and the chart renders no `highAvailability` block (design decision D72). It is refused with `FERRET_READONLY_NEEDS_HA` while the instance runs read-only FerretDB proxies (set `ferret.readOnlyReplicas` to 0 with a tpg-patch values file first). The sync removes `spec.highAvailability` from the live object only when Argo CD is the only field manager of those fields; when another manager (the operator) co-owns `enabled` and it stays `true`, the step applies `enabled: false` and `readReplicas: 0` with a server-side apply as field manager `tpg-scale` and records the warning `HA_FIELD_CO_OWNED` with the managers it found. When the new count gives an instance more database pods (1 + `replicas`) than its data pool has zones, the run warns `HA_NODES_EXCEED_ZONES` (section 4) and goes on.

The plan step writes every count and cap in one commit. A cap is written after the counts: when the scale of an instance does not happen (not `Running`, for example) and the instance would be left above the new cap, the cap stays as it was (`MAX_BELOW_CURRENT` on `result.<cluster>.maxReadReplicas`). A run that only changes caps syncs nothing, because the cap is read by the workflows, not by the cluster. When a batch fails, the later batches do not run; the exit handler then gives every instance the rollout did not reach its previous `highAvailability` back in `clusters/fleet.yaml` (one commit) and records it `NOT_RUN`, so no later sync scales it unasked. Instances that ran keep what they got, as their result says.

Then the rollout: the clusters with an instance to sync are put into batches by `rolloutMode` and `maxParallel` (as in tpg-day0, section 2); within a batch every instance of its clusters runs in parallel, one run at a time per instance. Each instance Application is synced at the pushed commit and waited on until the Postgres resource is `Running`; after a 30-second settle (logged) the workflow checks the pods and StatefulSets with the pod watch.

```bash
# 1. Scale out to 2 read replicas
argo submit --from workflowtemplate/tpg-scale-instance \
  -p clusters=aks-tpg-poc-02 -p instances=orders-db -p replicas=2 -p pushMode=direct --watch

# 2. Dry run of scaling two instances on two clusters to 3
argo submit --from workflowtemplate/tpg-scale-instance \
  -p clusters=aks-tpg-poc-01,aks-tpg-poc-02 -p instances=orders-db,billing-db \
  -p replicas=3 -p pushMode=direct -p dryRun=true --watch

# 3. Scale down to a single node (high availability off) through a pull request
argo submit --from workflowtemplate/tpg-scale-instance \
  -p clusters=aks-tpg-poc-01 -p instances=orders-db -p replicas=0 -p pushMode=pr --watch

# 4. Refuse to turn HA on for a single-node instance
argo submit --from workflowtemplate/tpg-scale-instance \
  -p clusters=aks-tpg-poc-04 -p instances=reporting-db -p replicas=1 \
  -p enableHAIfNeeded=false -p pushMode=direct --watch

# 5. Raise the cap to 5 on two clusters and scale orders-db to 4, canary first
argo submit --from workflowtemplate/tpg-scale-instance \
  -p clusters=aks-tpg-poc-01,aks-tpg-poc-02 -p instances=orders-db -p replicas=4 \
  -p maxReadReplicas=5 -p rolloutMode=canary -p maxParallel=1 -p pushMode=direct --watch

# 6. Only the cap (no instances, nothing synced)
argo submit --from workflowtemplate/tpg-scale-instance \
  -p clusters=aks-tpg-poc-03 -p maxReadReplicas=2 -p pushMode=direct --watch
```

Different counts per cluster and instance, with `clusterMap`:

```yaml
# scale-map.yaml
pushMode: pr
rolloutMode: batches
maxParallel: "2"
clusterMap: |
  aks-tpg-poc-01:
    maxReadReplicas: 4                   # the new cap of this cluster
    instances:
      orders-db: {replicas: 3}
      billing-db: {replicas: 0}          # single node
  aks-tpg-poc-02:
    instances:
      orders-db: {replicas: 2, postgresVersion: postgres-17.6}   # guard: skipped when it runs another version
      reporting-db: {replicas: 1, enableHAIfNeeded: false}      # refused if reporting-db is a single node
  aks-tpg-poc-03:
    maxReadReplicas: 2                   # cap only: no instance of this cluster is synced
```

```bash
argo submit --from workflowtemplate/tpg-scale-instance --parameter-file scale-map.yaml --watch

# replicas as the default of every map instance that has no replicas key
argo submit --from workflowtemplate/tpg-scale-instance -p pushMode=direct -p replicas=2 \
  -p clusterMap='{"aks-tpg-poc-01":{"instances":{"orders-db":{},"billing-db":{"replicas":1}}}}' --watch
```

---

## 9. tpg-network-policy

Creates, changes or removes the network policy of Postgres instances. The rules are written to `clusters/fleet.yaml` (`clusters.<c>.instances.<i>.network`) and rendered by the tpg-instance chart, so Argo CD owns the two objects in `pg-<instance>` like the rest of the instance:

- **NetworkPolicy `tpg-ingress`** (every pod of the namespace): selecting the pods makes ingress default deny.
- **CiliumNetworkPolicy `tpg-egress`** (every endpoint of the namespace): an egress section makes egress default deny. AKS runs Azure CNI powered by Cilium (Terraform `network_policy = "cilium"`), which enforces both kinds and adds up their allow rules.

`networkPolicy=baseline` on tpg-day0 and tpg-create-instance sets the same policy when an instance is created.

| Direction | Allowed by the baseline | Added by the inputs |
|---|---|---|
| Ingress | The pods of the namespace (replication, Patroni REST API, pgBackRest, FerretDB to Postgres); the operator namespace; port 9187 (metrics) from `monitoring` and `kube-system`; the Azure load balancer health probe address `168.63.129.16/32` when a Service is a load balancer | Port 5432 from `ingressFromNamespaces`, `ingressFromPodLabels` (in those namespaces, or in any namespace when no namespace is given) and `ingressFromCidrs`; with FerretDB (D71), port 27017 from the same clients, plus the probe address when `ferretExposure` is a load balancer |
| Egress | The namespace and the operator namespace; DNS (kube-dns, AKS LocalDNS `169.254.10.0/24` and the node, UDP and TCP 53); the Kubernetes API server (Patroni keeps its leader lock there); Azure Blob for pgBackRest: `*.blob.core.windows.net` on 443 with ACNS, otherwise any address on 443 (and 80 while `enableSSL` is `false`) | `egressToCidrs`; `egressToFqdns` (needs ACNS) |

A rule is rendered only for a non-empty input, and no peer list is ever empty: an empty list in a NetworkPolicy peer allows every source.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `clusters` | `List` | yes, without `clusterMap` | | Registered clusters (`all` is not accepted) |
| `instances` | `List` | yes, without `clusterMap` | | Instances on every listed cluster; each must be declared there and exist |
| `clusterMap` | `Map` | no | | Rules per instance (section 3); a `postgresVersion` key is a guard |
| `mode` | `Enum` | yes | | `apply`: the baseline policy with exactly the rules given (a rule that is not given is removed). `update`: only the rules given change, the others stay. `remove`: delete both policies (no rules may be given) |
| `pushMode` | `Enum` | yes | | `direct` or `pr` |
| `ingressFromNamespaces` | `List` | no | | Namespaces whose pods may connect on 5432 |
| `ingressFromPodLabels` | `Map` | no | | Pod labels allowed on 5432, in `ingressFromNamespaces` or in any namespace |
| `ingressFromCidrs`, `egressToCidrs` | `List (CIDRs)` | no | | Client ranges allowed on 5432 (clients through a load balancer); extra ranges the pods may reach |
| `egressToFqdns` | `List (host names)` | no | | Host names the pods may reach (`toFQDNs`); needs ACNS |
| `connectivityCheck` | `Boolean` | no | `true` | After the sync, check WAL archiving and client access (below) |
| `maxParallel` | `Integer` | no | `2` | Clusters per batch after the canary |
| `rolloutMode` | `Enum` | no | `canary` | `canary`, `batches` or `all` (section 2) |
| `dryRun` | `Boolean` | no | `false` | Plan and dry-run the policies on each cluster; push and sync nothing |
| `timeoutSeconds`, `prTimeoutSeconds` | `Integer` | no | `900`, `3600` | Per cluster, pull request |

The run, in order:

1. **Validate** the inputs and `clusterMap`.
2. **Plan.** The rules of each instance (map keys over the inputs) are written to `fleet.yaml`, the two policies are rendered and applied to the instance namespace with `--dry-run=server`. A cluster without CiliumNetworkPolicy (`CILIUM_NOT_AVAILABLE`) or whose dry run fails (`DRY_RUN_REJECTED`, `RENDER_FAILED`) is `BLOCKED` and not written. An instance with `egressToFqdns` on clusters without ACNS fails (`ACNS_NOT_ENABLED`); one that does not exist fails (`INSTANCE_NOT_FOUND`). One commit.
3. **Apply**, canary first, one cluster at a time per mutex: each instance Application is synced at the pushed commit (with prune for `mode=remove`), then:
   - both objects exist, or both are gone for `remove` (`POLICY_NOT_APPLIED`, `POLICY_NOT_REMOVED`);
   - WAL archiving still reaches the backup storage: `txid_current()` (so an idle instance has a WAL segment to switch) and `pg_switch_wal()` on the primary, then `pg_stat_archiver` must show a new archived WAL within 2 minutes (`BACKUP_EGRESS_BLOCKED` when it does not, or when `failed_count` grows);
   - a probe pod in the first `ingressFromNamespaces` namespace (with the `ingressFromPodLabels` labels) must reach port 5432 (`CLIENT_BLOCKED`), and a probe pod in namespace `default` must not, unless `default` is allowed (`NOT_ISOLATED`). A probe pod that cannot run is the warning `PROBE_NOT_RUN`.
4. **Gate:** the run ends `Failed` when a cluster was `BLOCKED`, after the other clusters were applied.

Clients outside the cluster reach the database through a load balancer and are matched by `ingressFromCidrs` on their source address. Check in the lab that the client address reaches the pod unchanged before relying on it (it depends on the Service's `externalTrafficPolicy`).

```bash
# 1. Dry run: baseline policy for orders-db, clients from namespace orders-app
argo submit --from workflowtemplate/tpg-network-policy \
  -p clusters=aks-tpg-poc-01 -p instances=orders-db -p mode=apply \
  -p ingressFromNamespaces=orders-app -p pushMode=direct -p dryRun=true --watch

# 2. Apply it on every listed cluster, canary first
argo submit --from workflowtemplate/tpg-network-policy \
  -p clusters=aks-tpg-poc-01,aks-tpg-poc-02 -p instances=orders-db -p mode=apply \
  -p ingressFromNamespaces=orders-app -p ingressFromPodLabels='{app: orders-api}' -p pushMode=direct --watch

# 3. Add a client range, keep the other rules
argo submit --from workflowtemplate/tpg-network-policy \
  -p clusters=aks-tpg-poc-01 -p instances=orders-db -p mode=update \
  -p ingressFromCidrs=10.20.0.0/16 -p pushMode=pr --watch

# 4. Remove the policy
argo submit --from workflowtemplate/tpg-network-policy \
  -p clusters=aks-tpg-poc-01 -p instances=orders-db -p mode=remove -p pushMode=direct --watch
```

Different rules per instance, with `clusterMap`:

```yaml
# netpol-map.yaml
mode: apply
pushMode: direct
clusterMap: |
  aks-tpg-poc-01:
    instances:
      orders-db: {ingressFromNamespaces: [orders-app], egressToCidrs: [10.30.0.0/24]}
      billing-db: {ingressFromNamespaces: [billing], ingressFromPodLabels: {role: api}}
```

```bash
argo submit --from workflowtemplate/tpg-network-policy --parameter-file netpol-map.yaml --watch
```

---

## 10. tpg-delete-apps

Deletes Tanzu Postgres applications per cluster: Postgres instances (`tpg-instances`) and the operator with its CRDs (`tpg-operator`). Deleting the operator removes these CRDs: `postgres`, `postgresbackups`, `postgresbackuplocations`, `postgresbackupschedules`, `postgresferretdocumentdbs`, `postgresmigrations`, `postgresrestores`, `postgresversions` and `postgresversionupgrades` (all `.sql.tanzu.vmware.com`).

The applications per cluster come from `apps` (JSON) or from `clusterMap`: the instances listed under a cluster are deleted, and `deleteOperator: true` deletes the operator after them.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `clusters` | `List` | yes, without `clusterMap` | | Registered clusters to clean up |
| `apps` | `Map (JSON)` | yes, without `clusterMap` | | Cluster to list of `tpg-instances`, `tpg-instances:<i>[,<i>]`, `tpg-operator`. Every cluster in `clusters` needs an entry |
| `clusterMap` | `Map` | no | | Instances per cluster, `deleteOperator` and `force` per cluster, `finalBackup`, `purgePvcs` and `purgeNamespace` per instance (section 3) |
| `confirm` | `List` | yes | | Repeat the cluster names (`clusters`, or the clusters of `clusterMap`) |
| `dryRun` | `Boolean` | no | `true` | `true` records the plan; `false` deletes (set `false` explicitly to delete) |
| `purgePvcs` | `Boolean` | yes (input or map key per instance) | | `true` deletes PVCs and Azure disks; `false` keeps them |
| `purgeNamespace` | `Boolean` | yes (input or map key per instance) | | `true` deletes `pg-<instance>` (needs `purgePvcs=true`); `false` keeps it |
| `pushMode` | `Enum` | yes | | `direct` or `pr` |
| `force` | `Boolean` | no | `false` | With the operator: also delete Postgres instances not listed, and do not wait for running backups or restores |
| `finalBackup` | `Enum` | no | `true` | `true`, `false` or `required` (fail when the instance is not Running) |
| `timeoutSeconds`, `prTimeoutSeconds` | `Integer` | no | `1800`, `3600` | Timeouts |

Order per cluster: instances (final backup, `fleet.yaml` removal, Application removal without cascade, Postgres objects, optional PVC and namespace purge), remaining Tanzu Postgres custom resources, operator (`fleet.yaml`, Application, leftover cluster-scoped objects, namespace `tanzu-postgres-operator`), CRDs. The Azure Blob backup repository is never deleted. With a `postgresVersion` key in `clusterMap`, an instance that runs another version is `SKIPPED_VERSION_MISMATCH` and kept.

```bash
# 1. Plan (dry run) a full clean-up of two clusters
argo submit --from workflowtemplate/tpg-delete-apps \
  -p clusters=aks-tpg-poc-03,aks-tpg-poc-04 \
  -p apps='{"aks-tpg-poc-03":["tpg-instances","tpg-operator"],"aks-tpg-poc-04":["tpg-instances","tpg-operator"]}' \
  -p confirm=aks-tpg-poc-03,aks-tpg-poc-04 \
  -p dryRun=true -p purgePvcs=false -p purgeNamespace=false -p pushMode=direct --watch

# 2. Run it: remove everything, including volumes and namespaces
argo submit --from workflowtemplate/tpg-delete-apps \
  -p clusters=aks-tpg-poc-03,aks-tpg-poc-04 \
  -p apps='{"aks-tpg-poc-03":["tpg-instances","tpg-operator"],"aks-tpg-poc-04":["tpg-instances","tpg-operator"]}' \
  -p confirm=aks-tpg-poc-03,aks-tpg-poc-04 \
  -p dryRun=false -p purgePvcs=true -p purgeNamespace=true -p pushMode=direct --watch

# 3. Different applications per cluster: one instance on 01, all instances on 02 (keep volumes)
argo submit --from workflowtemplate/tpg-delete-apps \
  -p clusters=aks-tpg-poc-01,aks-tpg-poc-02 \
  -p apps='{"aks-tpg-poc-01":["tpg-instances:billing-db"],"aks-tpg-poc-02":["tpg-instances"]}' \
  -p confirm=aks-tpg-poc-01,aks-tpg-poc-02 \
  -p dryRun=false -p purgePvcs=false -p purgeNamespace=false -p pushMode=pr --watch

# 4. Operator only, forcing removal of instances created outside Git, no final backups
argo submit --from workflowtemplate/tpg-delete-apps \
  -p clusters=aks-tpg-poc-04 -p apps='{"aks-tpg-poc-04":["tpg-operator"]}' -p confirm=aks-tpg-poc-04 \
  -p dryRun=false -p purgePvcs=true -p purgeNamespace=true -p pushMode=direct \
  -p force=true -p finalBackup=false --watch
```

With a parameter file (easier for JSON):

```yaml
# delete-lab.yaml
clusters: aks-tpg-poc-03
apps: '{"aks-tpg-poc-03": ["tpg-instances:scratch-db,test-db", "tpg-operator"]}'
confirm: aks-tpg-poc-03
dryRun: "false"
purgePvcs: "true"
purgeNamespace: "true"
pushMode: direct
```

```bash
argo submit --from workflowtemplate/tpg-delete-apps --parameter-file delete-lab.yaml --watch
```

With `clusterMap`, settings per instance:

```yaml
# delete-map.yaml
confirm: aks-tpg-poc-03,aks-tpg-poc-04
dryRun: "false"
pushMode: direct
purgePvcs: "false"            # default of every instance
purgeNamespace: "false"
clusterMap: |
  aks-tpg-poc-03:
    deleteOperator: true
    force: true
    instances:
      scratch-db: {purgePvcs: true, purgeNamespace: true, finalBackup: false}
      test-db: {}
  aks-tpg-poc-04:
    instances:
      billing-db: {finalBackup: required}
```

```bash
argo submit --from workflowtemplate/tpg-delete-apps --parameter-file delete-map.yaml --watch
```

---

## 11. tpg-delete-instance

Guarded delete of instances (the per-instance step that `tpg-delete-apps` uses). Instances are deleted one at a time.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `clusters` | `List` | yes, without `clusterMap` | | Registered clusters (`all` is not accepted) |
| `instances` | `List` | yes, without `clusterMap` | | Instances to delete on every listed cluster. Each instance must be declared on each listed cluster |
| `clusterMap` | `Map` | no | | Instances per cluster, with `finalBackup`, `purgePvcs` and `purgeNamespace` per instance (section 3) |
| `confirm` | `List` | yes | | Repeat the `instances` value; with `clusterMap`, repeat its cluster names |
| `finalBackup` | `Enum` | no | `true` | `true`, `false` or `required` (fail when the instance is not Running) |
| `purgePvcs` | `Boolean` | no | `false` | `true` deletes PVCs and Azure disks |
| `purgeNamespace` | `Boolean` | no | `false` | `true` deletes `pg-<instance>` (needs `purgePvcs=true`) |
| `pushMode` | `Enum` | no | `direct` | `direct` or `pr` |
| `timeoutSeconds`, `prTimeoutSeconds` | `Integer` | no | `1800`, `3600` | Per instance, pull request |

An instance that is not declared on one of the listed clusters fails the run with `UNKNOWN_INSTANCE` before anything is deleted. The instance's FerretDB and its operator backup schedules (D70, D71) are deleted after the final backup and before the entry leaves `clusters/fleet.yaml`: FerretDB would lose its backend, and no scheduled backup may start during the delete. A run that stops earlier (a guard, a failed final backup) leaves both in place.

```bash
# 1. Delete billing-db, keep volumes and namespace
argo submit --from workflowtemplate/tpg-delete-instance \
  -p clusters=aks-tpg-poc-01 -p instances=billing-db -p confirm=billing-db --watch

# 2. Require a final backup, purge volumes and namespace, through a pull request
argo submit --from workflowtemplate/tpg-delete-instance \
  -p clusters=aks-tpg-poc-02 -p instances=orders-db -p confirm=orders-db \
  -p finalBackup=required -p purgePvcs=true -p purgeNamespace=true -p pushMode=pr --watch

# 3. Two lab instances on two clusters
argo submit --from workflowtemplate/tpg-delete-instance \
  -p clusters=aks-tpg-poc-03,aks-tpg-poc-04 -p instances=scratch-db,test-db \
  -p confirm=scratch-db,test-db -p finalBackup=false --watch

# 4. Per instance settings, with clusterMap
argo submit --from workflowtemplate/tpg-delete-instance -p confirm=aks-tpg-poc-01,aks-tpg-poc-02 \
  -p clusterMap='{"aks-tpg-poc-01":{"instances":{"billing-db":{}}},"aks-tpg-poc-02":{"instances":{"scratch-db":{"purgePvcs":true,"purgeNamespace":true}}}}' --watch
```

---

## 12. tpg-helm-addons

Installs or upgrades the Helm releases on target clusters: `cert-manager`, `vault-secrets-operator`, and for the standalone monitoring option `kps` (Prometheus agent) and `tpg-ksm`. The hub releases (`vault`, `vault-secrets-operator`, `kps`) are installed by `tpg-aks-infra/scripts/run.sh --only vault` and `--only addons`. The `vault` release shows its pod table like the others; it is done when `vault-0` has started (shown as `Started`), because Vault turns Ready only after it is initialized and unsealed, which the next part of the step does.

The steps run `alpine/k8s:1.35.8`, which ships **Helm 4**. Helm 4 removed
the `-a` flag from `helm list` (it lists every release state by default), renamed `--atomic` to
`--rollback-on-failure` and `--force` to `--force-replace`, and takes a registry
domain without a path for `helm registry login`. The shared Helm helpers
(`workflows/scripts/common.sh`, the same block as `tpg-aks-infra/scripts/lib/common.sh`)
select the release states with `--deployed --failed --pending --superseded --uninstalled
--uninstalling` (`HR_LIST_ALL`), which Helm 3 and Helm 4 both accept, so the same script runs on
a workstation with either version. `tpg-fleet/tests/cli-flags` fails the build
when a removed flag comes back.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `clusters` | `List` | yes | | Registered clusters or `all` |
| `components` | `List` | no | `auto` | `auto` (cert-manager and vso, plus monitoring when `tpg-settings monitoringOption=standalone`), or a list of `cert-manager`, `vso`, `monitoring` |
| `existingAddons` | `Enum` | no | `skip` | A release that exists with another chart version or other values: `skip` (report `SKIPPED_EXISTS`) or `upgrade` |
| `dryRun` | `Boolean` | no | `false` | `helm upgrade --install --dry-run=server` |

Every component is classified before anything is installed, and the result is reported per release:

| Status | Meaning |
|---|---|
| `INSTALLED`, `UPGRADED` | The release was created or upgraded by this run |
| `UP_TO_DATE` | Our release, same chart version, same values |
| `SKIPPED_EXISTS` | Our release differs; rerun with `existingAddons=upgrade` to apply |
| `SKIPPED_NEWER` | The installed chart is newer than the pinned version; never downgraded |
| `REUSED_EXISTING` | A cert-manager or Vault Secrets Operator installed by someone else is recent enough and is used as it is |
| `BLOCKED` | Another installation that cannot be reused (a foreign `kps` or Vault, an operation in progress, a controller too old). The cluster is not changed |

While `helm --wait` runs, the pod watch prints the pods of the release's namespace every 5 seconds and stops the install when one cannot start (section 2).

With standalone monitoring, the target's `kps` writes to the hub gateway over https with basic auth: the step first creates the `VaultStaticSecret monitoring/tpg-remote-write` (Vault `tpg/shared/monitoring-remote-write`) and copies the Vault CA to `monitoring/tpg-remote-write-ca`. After the install, the run checks for 5 minutes (`MONITORING_FLOW_TIMEOUT`) that the hub Prometheus receives series labelled `cluster=<cluster>`; if none arrive the cluster ends `FAILED` with `MONITORING_NOT_FLOWING`, and the step log names what to check (the gateway Service, the target's Prometheus logs, the credential). With the Azure option it checks that the `ama-metrics` pods run.

```bash
# 1. Everything the cluster needs, on every cluster
argo submit --from workflowtemplate/tpg-helm-addons -p clusters=all --watch

# 2. cert-manager only on a new cluster
argo submit --from workflowtemplate/tpg-helm-addons -p clusters=aks-tpg-poc-04 -p components=cert-manager --watch

# 3. Dry run of the monitoring agent upgrade on two clusters
argo submit --from workflowtemplate/tpg-helm-addons \
  -p clusters=aks-tpg-poc-01,aks-tpg-poc-02 -p components=monitoring -p dryRun=true --watch

# 4. Bring existing releases up to the pinned chart versions and values
argo submit --from workflowtemplate/tpg-helm-addons -p clusters=all -p existingAddons=upgrade --watch
```

---

## 13. tpg-backup

Creates one `PostgresBackup` per selected instance and waits for it.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `backupType` | `Enum` | no | `full` | `full` starts a new chain; `incremental` holds the changes since the previous backup (the daily schedule); `differential` holds the changes since the last full backup |
| `clusters` | `List` | no | `all` | Registered clusters or `all` |
| `instances` | `List` | no | every instance | Instances or `all`; each must be declared on at least one selected cluster |
| `clusterMap` | `Map` | no | | Instances per cluster, with `backupType` and `backupTimeoutSeconds` per instance (section 3) |
| `scheduledOnly` | `Boolean` | no | `false` | `true` (used by the CronWorkflows): skip instances with `backup.scheduled: false` |
| `backupTimeoutSeconds` | `Integer` | no | `10800` | Time to wait per backup |

The schedule is one full backup a week and an incremental one on the other days:

| CronWorkflow | Schedule (UTC) | Type |
|---|---|---|
| `tpg-backup-full` | Sunday 00:00 | full |
| `tpg-backup-incr` | Monday to Saturday 00:00 | incremental |
| `tpg-backup-retention` | daily 02:00 | expiry (section 14) |

An instance with `backupSchedule=operator` (section 4) is not in the CronWorkflows: its PostgresBackupSchedule objects back it up on their own crons (UTC, the operator's clock). tpg-backup without `scheduledOnly` still backs it up on demand, and tpg-backup-retention expires its backups like the others.

```bash
# The operator schedules of an instance, and the backups they created
kubectl --context aks-tpg-poc-01 -n pg-docs-db get postgresbackupschedule
kubectl --context aks-tpg-poc-01 -n pg-docs-db get postgresbackup -o custom-columns=NAME:.metadata.name,TYPE:.spec.type,PHASE:.status.phase
```

An incremental backup depends on the full backup and on every incremental before it, so pgBackRest can only expire a whole chain: the full backup and its incrementals go together. That is what makes the retention workflow expire chains rather than single backups. A differential backup depends only on its full backup, which makes single backups expirable but every differential larger than the incremental of the same day; the POC uses incrementals and keeps `differential` available for a manual run.

```bash
# 1. Full backup of every instance on every cluster
argo submit --from workflowtemplate/tpg-backup -p backupType=full -p clusters=all --watch

# 2. Incremental backup on one cluster
argo submit --from workflowtemplate/tpg-backup -p backupType=incremental -p clusters=aks-tpg-poc-01 --watch

# 3. Same selection as the CronWorkflows (skips backup.scheduled=false instances)
argo submit --from workflowtemplate/tpg-backup -p backupType=full -p clusters=all -p scheduledOnly=true --watch

# 4. Two instances, wherever they are declared
argo submit --from workflowtemplate/tpg-backup -p instances=orders-db,billing-db --watch

# 5. Different instances and types per cluster
argo submit --from workflowtemplate/tpg-backup \
  -p clusterMap='{"aks-tpg-poc-01":{"instances":{"orders-db":{"backupType":"full"}}},"aks-tpg-poc-02":{"instances":{"billing-db":{"backupType":"incremental"}}}}' --watch

# Run a CronWorkflow now
argo cron list
argo submit --from cronwf/tpg-backup-full --watch
```

```bash
# What exists, per instance
kubectl --context aks-tpg-poc-01 -n pg-orders-db get postgresbackup \
  -o custom-columns=NAME:.metadata.name,TYPE:.spec.type,PHASE:.status.phase,STARTED:.status.timeStarted
```

---

## 14. tpg-backup-retention

Expires backups that are older than the retention window. It groups every instance's backups into chains (one full backup and the incrementals that follow it), and expires a chain only when its newest backup is older than the window, so no chain is ever left without its full backup. The newest chain is always kept, however old it is, and a backup that is still running, already expired or marked `Failed` is left alone.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `clusters` | `List` | no | `all` | Registered clusters or `all` |
| `instances` | `List` | no | every instance | Instances or `all`; each must be declared on at least one selected cluster |
| `clusterMap` | `Map` | no | | Instances per cluster, with `retentionDays` per instance (section 3) |
| `retentionDays` | `Integer` | no | per instance | Override `backup.retentionDays` (`clusters/_template/cluster.yaml`: 35) for this run |
| `dryRun` | `Boolean` | no | `false` | `true`: report the chains that would be expired; change nothing |

```bash
# 1. What the daily run would expire today
argo submit --from workflowtemplate/tpg-backup-retention -p clusters=all -p dryRun=true --watch

# 2. Apply the fleet.yaml retention on every cluster (what the CronWorkflow does)
argo submit --from workflowtemplate/tpg-backup-retention -p clusters=all --watch

# 3. Free space on one cluster: keep two weeks
argo submit --from workflowtemplate/tpg-backup-retention \
  -p clusters=aks-tpg-poc-03 -p retentionDays=14 --watch

# 4. A different window per instance
argo submit --from workflowtemplate/tpg-backup-retention \
  -p clusterMap='{"aks-tpg-poc-03":{"instances":{"scratch-db":{"retentionDays":7},"orders-db":{"retentionDays":21}}}}' --watch
```

The per-instance result reads, for example, `EXPIRED 5 backups in 2 chain(s)`, `DRY_RUN would expire 2 of 3 chain(s) older than 35 days` or `NOTHING_TO_EXPIRE`. Expiry is a request to the operator (`spec.expire` on the full backup of the chain): the repository is cleaned by pgBackRest, and the `PostgresBackup` objects disappear when the operator has finished.

---

## 15. tpg-restore

Restores one instance to a chosen recovery point. Four things are chosen independently: the source instance, the recovery point (`mode`), where it is restored to, and whether that target already exists.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `sourceCluster` | `String (name)` | yes | | Registered cluster that runs the instance to restore from |
| `instance` | `String (name)` | yes | | Source instance (namespace `pg-<instance>`) |
| `mode` | `Enum` | yes | | `time`, `latest`, `backup`, `lsn` or `xid` |
| `targetTime` | `String (UTC time)` | with `mode=time` | | UTC timestamp, for example `2026-09-15T08:30:00Z` |
| `backupName` | `String (name)` | with `mode=backup` | | A `PostgresBackup` name in the source namespace |
| `lsn` | `String (LSN)` | with `mode=lsn` | | Log sequence number |
| `xid` | `Integer` | with `mode=xid` | | Transaction ID |
| `targetCluster` | `String (name)` | no | `sourceCluster` | Registered cluster to restore into |
| `targetInstance` | `String (name)` | no | `<instance>-restore-<yyyymmddhhmm>` | Instance to restore into; the source instance name means in place |
| `confirm` | `String (name)` | when the target instance exists | | Repeat the target instance name: the restore overwrites its data |
| `pushMode` | `Enum` | no | `direct` | Cross-cluster restore to a new instance: how the `clusters/fleet.yaml` entry is published |
| `bestEffort` | `Boolean` | no | `false` | Recover as far as the WAL allows instead of failing |
| `restoreTimeoutSeconds`, `prTimeoutSeconds` | `Integer` | no | `7200`, `3600` | Timeouts |

| Target | What the workflow does |
|---|---|
| New instance, same cluster | A one-off clone in its own namespace, not managed by Argo CD. Delete it when the validation is done, or add it to `clusters/fleet.yaml` |
| New instance, another cluster | The instance is added to `clusters/fleet.yaml` with the source settings (its backup scheduler included, `backupSchedule=operator` too; FerretDB is not copied: the `ferret` block is left out, and when a copied values patch turns FerretDB on, the entry gets `valuesOverride: {ferret: {enabled: false}}`, which wins over patch files; `ferret=true` on tpg-day0 or a tpg-patch values file that sets `ferret.enabled: true` lifts it), its Secrets (from Vault) and its own backup location are rendered from the chart, and the Argo CD Application adopts it after the restore (the operator backup schedules come with that sync) |
| The same instance (in place) | Destructive; needs `confirm=<instance>` |
| Another existing instance | Destructive; needs `confirm=<instance>` |

Before it starts, the workflow reads the source instance's backup location, stanza and Postgres version, and refuses a `targetTime` that is in the future or older than the oldest full backup (`OUTSIDE_RECOVERY_WINDOW`). For a restore into another namespace or cluster it creates a read-only copy of the source backup location there, so `backupSync` lists the source backups for the restore; `mode=backup` restores only inside the source namespace, because a `PostgresBackup` name is namespaced: it needs `targetInstance=<instance>` and `confirm=<instance>` (in place), and the validate step refuses it without them.

```bash
# 1. Point in time into a new instance on the same cluster
argo submit --from workflowtemplate/tpg-restore \
  -p sourceCluster=aks-tpg-poc-01 -p instance=orders-db \
  -p mode=time -p targetTime=2026-09-15T08:30:00Z --watch

# 2. Latest recoverable point, in place (destructive)
argo submit --from workflowtemplate/tpg-restore \
  -p sourceCluster=aks-tpg-poc-01 -p instance=orders-db -p mode=latest \
  -p targetInstance=orders-db -p confirm=orders-db --watch

# 3. From one named backup, in place (mode=backup restores only inside the source
#    namespace, so the target is the source instance; destructive)
argo submit --from workflowtemplate/tpg-restore \
  -p sourceCluster=aks-tpg-poc-01 -p instance=orders-db \
  -p mode=backup -p backupName=orders-db-full-20260914000000 \
  -p targetInstance=orders-db -p confirm=orders-db --watch

# 4. Clone to another cluster, managed by Argo CD afterwards
argo submit --from workflowtemplate/tpg-restore \
  -p sourceCluster=aks-tpg-poc-01 -p instance=orders-db -p mode=latest \
  -p targetCluster=aks-tpg-poc-02 -p targetInstance=orders-db-dr -p pushMode=direct --watch

# 5. Up to a transaction ID, best effort
argo submit --from workflowtemplate/tpg-restore \
  -p sourceCluster=aks-tpg-poc-01 -p instance=orders-db \
  -p mode=xid -p xid=987654 -p bestEffort=true --watch
```

Afterwards:

```bash
kubectl --context aks-tpg-poc-01 -n pg-orders-db-restore-202609151030 get postgres,postgresrestore
# The copy of the source backup location is kept on purpose. Delete it only when the
# restore is validated: deleting it also removes the PostgresBackup objects that were
# synced from the source repository into that namespace.
kubectl --context aks-tpg-poc-01 -n pg-orders-db-restore-202609151030 \
  get postgresbackuplocation -l tpg.fleet/restore-source
```

---

## 16. tpg-rotate-credential

The credential itself is changed in Vault; the workflow then verifies that the new value reached everything that uses it. Nothing is edited in a Kubernetes Secret by hand.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `secretType` | `Enum` | no | `broadcom-registry` | `broadcom-registry`, `backup-storage`, `git-push` or `git-read` (table below) |
| `clusters` | `List` | no | `all` | Registered clusters to verify, or `all` |
| `maxParallel` | `Integer` | no | `5` | Clusters verified at the same time |

```bash
# 1. Write the new value to Vault. In the UI (scripts/run.sh --only access prints the
#    URL and the tpg-admin password), or in a shell in the Vault pod:
kubectl --context aks-tpg-hub -n vault exec -it vault-0 -- sh
#   vault login -method=userpass username=tpg-admin          (prompts for the password)
#   vault kv put tpg/shared/broadcom-registry username=<user> token=<new token>
#   exit

# 2. Verify the propagation
argo submit --from workflowtemplate/tpg-rotate-credential -p secretType=broadcom-registry --watch
argo submit --from workflowtemplate/tpg-rotate-credential -p secretType=backup-storage --watch
argo submit --from workflowtemplate/tpg-rotate-credential -p secretType=git-push --watch
argo submit --from workflowtemplate/tpg-rotate-credential -p secretType=git-read --watch
```

| `secretType` | Vault path | What is checked |
|---|---|---|
| `broadcom-registry` | `tpg/shared/broadcom-registry` | The hub `VaultStaticSecret` and the Argo CD OCI repository connection, then on every cluster: `regsecret` matches Vault, and a test pod pulls an image |
| `backup-storage` | `tpg/shared/backup-storage` | `backup-storage` matches Vault on every cluster, the backup locations are re-read by the operator, and the Blob container answers with HTTP 200 for the new key |
| `git-push` | `tpg/shared/github-push` | The workflow's own Git credential: a clone and a `git push --dry-run` to the fleet branch |
| `git-read` | `tpg/shared/github-read` | The Argo CD repository credential: `repo-tpg-fleet` matches Vault (Vault Secrets Operator) and the Argo CD connection to the fleet repository is Successful |

`tpg/shared/monitoring-remote-write` (standalone monitoring: `username`, `password`) has no `secretType`. After changing it in Vault, run `tpg-aks-infra/scripts/run.sh --only addons`: the hub gateway's htpasswd is rebuilt from Vault and the gateway restarted, and the Vault Secrets Operator updates `monitoring/tpg-remote-write` on every target (within its refresh interval); the step then checks that each target's metrics still reach the hub.

---

## 17. Interactive submit scripts

`scripts/submit/tpg-<workflow>.sh` starts a workflow without composing the `argo submit` line by hand: one script per WorkflowTemplate (13). Each script reads the inputs, defaults, allowed values and descriptions from `workflows/templates/<template>.yaml` and the types from `workflows/params/types.yaml`, so it stays in step with the template.

1. The targets first: `clusterMap` or the lists, where the workflow takes both. `clusterMap` can be built step by step (the registered clusters are listed from the hub, then the instances declared in your `clusters/fleet.yaml`, then the keys the workflow accepts, with their types), loaded from a file, or pasted. It is checked with the same `clustermap.py` as the `validate` step.
2. The mandatory inputs, each with its type and an example. A value that does not match its type is refused with the reason and asked again.
3. A menu of the optional inputs with their current values or defaults (arrow keys and Enter, or numbers). After each one the script asks whether to set another.
4. A summary, the equivalent `argo submit` command, then Submit, Change optional inputs, or Cancel.
5. The submit: `argo submit` when the argo CLI is installed, otherwise `kubectl create` of a Workflow object (the hub admission policy checks it the same way). The script can then follow the run and print its report.

Requirements: bash 3.2 or later (the macOS bash works), mikefarah `yq` v4, `jq`, `python3`, `kubectl` with a context for the hub; the argo CLI is optional.

| Variable | Meaning |
|---|---|
| `HUB_CONTEXT` | kubectl context of the hub (default: the current context) |
| `ARGO_NS` | Namespace of the WorkflowTemplates (default `argo`) |
| `TPG_PLAIN=1` | Numbered menus instead of arrow keys (also when the terminal is not interactive) |
| `TPG_NO_WATCH=1` | Do not offer to follow the run |

```bash
cd tpg-fleet
HUB_CONTEXT=aks-tpg-hub scripts/submit/tpg-create-instance.sh
TPG_PLAIN=1 HUB_CONTEXT=aks-tpg-hub scripts/submit/tpg-network-policy.sh
# patch files: run the script from the directory that holds them
cd ~/patches && HUB_CONTEXT=aks-tpg-hub ~/tpg-fleet/scripts/submit/tpg-patch.sh
```

Some inputs depend on an earlier answer: `tpg-upgrade.sh` asks `instances` for `component=postgres`, `tpg-restore.sh` asks the recovery point of the chosen `mode`, `tpg-scale-instance.sh` asks whether the run scales instances (`instances` and `replicas`), changes only the cap (`maxReadReplicas`), or both, and `tpg-patch.sh` does not submit before a patch file input is set (and `instances` for instance patch files).

**Patch files (Round 14).** `tpg-patch.sh` and `tpg-create-instance.sh` read every file that the path inputs and `clusterMap` name (relative to the current directory; not with `patchMode=clear`), refuse a missing file or one over 256 KiB, and send their contents as `patchFiles`; you never type that input. The equivalent command they print uses the helper instead of the base64:

```bash
argo submit -n argo --from workflowtemplate/tpg-patch -p clusters=aks-tpg-poc-01 -p instances=orders-db \
  -p valuesPatchFilePath=./orders-backup.yaml -p pushMode=pr \
  -p "patchFiles=$(/home/me/src/tpg-fleet/scripts/submit/pack-patch-files.sh ./orders-backup.yaml)"
```

The scripts themselves submit `patchFiles` through a parameter file, so the Linux limit of 128 KiB per command-line argument does not apply to them. `scripts/submit/pack-patch-files.sh FILE...` prints `{"<path as given>": "<base64>"}` for plain `argo submit`; with `-o FILE.yaml` it writes (or replaces) the line `patchFiles: '...'` in a parameter file instead, for `--parameter-file`. Give each path exactly as in the path inputs.

---

## 18. Test data: pgdata

`tools/pgdata/pgdata.py` creates a database and tables on an instance, inserts random rows and reads them back, to try a deployment, a backup and restore, or a network policy with real data. It needs Python 3.9 or later and psycopg 3 (`pip install "psycopg[binary]"`).

The connection is given by hand; nothing is read from the cluster. Reach the instance through its load balancer address (`exposure`), or port-forward its Service first. The credentials are in the Secret `pg-<instance>/<instance>-db-secret`, keys `username` and `password`:

```bash
kubectl --context aks-tpg-poc-01 -n pg-orders-db port-forward svc/orders-db 5432 &
export PGPASSWORD="$(kubectl --context aks-tpg-poc-01 -n pg-orders-db get secret orders-db-db-secret -o jsonpath='{.data.password}' | base64 -d)"
PGUSER="$(kubectl --context aks-tpg-poc-01 -n pg-orders-db get secret orders-db-db-secret -o jsonpath='{.data.username}' | base64 -d)"
C=(--host 127.0.0.1 --port 5432 --user "$PGUSER" --sslmode require)
```

The password comes from `--password`, else `PGPASSWORD`, else a hidden prompt (`--password` is visible in the process list). Without a command, or with `--interactive`, the script asks for the connection and the action step by step.

| Command | Options |
|---|---|
| `create-db` | `--name NAME [--owner ROLE] [--if-not-exists]` |
| `create-table` | `--database DB --table [SCHEMA.]TABLE` with `--preset customers\|orders\|sales_events` or `--columns "name:type,..."`; `[--primary-key COLUMN] [--if-not-exists]`. A missing schema is created |
| `insert` | `--database DB --table TABLE [--rows 100] [--batch-size 1000] [--seed N]`: values generated from the column types, loaded with COPY |
| `read` | `--database DB --table TABLE [--limit 20] [--where "COLUMN OP VALUE"] [--order-by COLUMN [--desc]] [--count] [--format table\|csv\|json]`, or `--sql "SELECT ..."` in a READ ONLY transaction |

Column types: `smallint`, `integer`, `bigint`, `serial`, `bigserial`, `real`, `double precision`, `boolean`, `text`, `date`, `timestamp`, `timestamptz`, `uuid`, `json`, `jsonb`, `numeric` or `numeric(P,S)`, `varchar(N)`, `char(N)`, and `identity` for a generated `bigint` key. Identifiers are checked and quoted, values are passed as query parameters, and `--where` takes one comparison (`=`, `!=`, `<`, `<=`, `>`, `>=`, `like`, `ilike`, `is null`, `is not null`).

```bash
python3 tools/pgdata/pgdata.py "${C[@]}" create-db --name shop
python3 tools/pgdata/pgdata.py "${C[@]}" create-table --database shop --table customers --preset customers
python3 tools/pgdata/pgdata.py "${C[@]}" create-table --database shop --table sales.events \
  --columns "id:identity,at:timestamptz,amount:numeric(10,2),tag:varchar(20),doc:jsonb"
python3 tools/pgdata/pgdata.py "${C[@]}" insert --database shop --table customers --rows 10000 --seed 42
python3 tools/pgdata/pgdata.py "${C[@]}" read --database shop --table customers --where "city ilike b%" --order-by id --limit 5
python3 tools/pgdata/pgdata.py "${C[@]}" read --database shop --table customers --count
python3 tools/pgdata/pgdata.py "${C[@]}" read --database shop --sql "select tag, count(*) from sales.events group by tag" --format csv
```

---

## 19. Follow, approve, stop and clean up runs

```bash
argo list                                   # runs with status and duration
argo list --running
argo list -l workflows.argoproj.io/workflow-template=tpg-day0
argo get @latest                            # step tree of the newest run
argo watch @latest
argo logs @latest --follow
argo logs <workflow> -c main | sed -n '/tpg run report/,$p'
kubectl -n argo get configmap tpg-run-<workflow> -o yaml   # raw results per target

argo resume <workflow>                      # approve a suspended step (tpg-upgrade allowMajor=true)
argo suspend <workflow>
argo stop <workflow>                        # run exit handlers (report), then stop
argo terminate <workflow>                   # stop immediately, no exit handler
argo retry <workflow>                       # rerun failed steps
argo resubmit <workflow> --memoized         # new run with the same inputs
argo delete <workflow>                      # also deletes tpg-run-<workflow>
argo delete --older 7d
```

### Archived step logs

Every step's log is archived to Azure Blob when the step ends (container `argo-logs` of the backup storage account). The Argo UI shows the log of a finished step even after its pod has been deleted, for as long as the Workflow exists (7 days). After that, or from a terminal:

```bash
cd tpg-aks-infra
scripts/wf-logs.sh <workflow> --list              # the archived logs of a run
scripts/wf-logs.sh <workflow>                      # print every step log
scripts/wf-logs.sh <workflow> --grep 'RESULT|POD_' # only the matching lines, per step
make wf-logs WF=<workflow>
```

The logs are deleted by the storage lifecycle rule after 90 days (Terraform `argo_logs_retention_days`).

### Reading a failed step

Every step writes its own result: one line `RESULT <key> <status> <reason>
<detail>` in the step log, one key in `tpg-run-<workflow>`, and the output
parameter the report and the Prometheus metric read. A step that fails before it
gets that far records `UNEXPECTED_ERROR` with the script and line number, so a
run never ends with a bare `UNKNOWN`.

```bash
argo logs @latest -c main | grep RESULT
kubectl -n argo get configmap tpg-run-<workflow> -o json | jq '.data | map_values(fromjson)'
```

Reasons written by the sync engine, the pod watch and the checks before a change:

| Reason | Meaning | Look at |
|---|---|---|
| `SYNC_REJECTED` | The API server or an admission webhook refused the manifests (invalid or immutable field). Not retried | The detail holds Argo CD's message; fix the spec in Git |
| `SYNC_FAILED` | The sync operation failed for another reason, after the retries | `argocd app get <app> --show-operation` |
| `SYNC_TIMEOUT` | The sync operation did not finish in time | `argocd app get <app>`, the pod table in the step log |
| `SYNC_BUSY` | Another operation on the Application did not end in time | `argocd app get <app> --show-operation`; ask the platform team if it is stuck (section 20) |
| `SYNC_DRIFT` | Synced, but resources stay OutOfSync (listed in the detail) | `argocd app diff <app>` |
| `HEALTH_TIMEOUT` | Synced, but not Healthy in time | The Postgres resource `status.currentState`, the pod table |
| `POD_<REASON>` | A pod could not start (`POD_CRASHLOOPBACKOFF`, `POD_IMAGEPULLBACKOFF`, `POD_UNSCHEDULABLE`, ...) | The status, events and logs printed below the pod table |
| `MONITORING_NOT_FLOWING` | A target's metrics did not reach the hub within 5 minutes | `kubectl -n monitoring logs deploy/tpg-remote-write` on the hub, the target's Prometheus logs |
| `UNKNOWN_INSTANCE` | A selected instance is not declared on the cluster in `clusters/fleet.yaml`. Nothing was changed | The detail lists the declared instances |
| `SKIPPED_VERSION_MISMATCH` | The `postgresVersion` key of `clusterMap` differs from the running version; the instance was left alone | The detail holds both versions |
| `FLEET_OVERRIDDEN` | tpg-day0: nothing ran on the target, so the input replaced the version declared in `fleet.yaml` | The detail holds the old value |
| `UPGRADE_REQUIRED`, `DOWNGRADE_NOT_ALLOWED`, `VERSION_UNKNOWN` | tpg-day0: the target runs another version (section 4) | tpg-upgrade, or the running operator and instances |
| `PATCH_REFUSED` | tpg-patch, tpg-create-instance: a file holds a refused field, the render or the server-side dry run failed on the target, or `patchMode=clear` names another file than the current one | The pre-check detail names the file, the field and the owning workflow; the step log holds the render error |
| `NO_CHANGE` | tpg-patch: the patch renders the objects that already run (no difference); nothing was committed or synced | The diff in the plan step log is empty |
| `PR_NOT_MERGED` | tpg-patch `pushMode=pr`: the pull request of the cluster was closed without merging, or not merged within `prTimeoutSeconds`; the cluster was synced back and the branch deleted | Run tpg-patch again and merge the pull request while the workflow waits |
| `OPERATION_IN_PROGRESS` | tpg-patch, tpg-scale-instance: an upgrade or a restore of the instance is still running; tpg-patch reverts the cluster | Run the workflow again when it has finished (`kubectl -n pg-<instance> get postgresversionupgrade,postgresrestore`) |
| `SKIPPED_NOT_PLANNED` | tpg-patch: the cluster was blocked in the plan, or none of its targets has a change | The pre-check of the cluster |
| `OPERATOR_PATCH_LIST` | tpg-upgrade: `clusters.<cluster>.operator.patches.values` is a Round 11 list of several files, which Round 14 does not apply | Merge them into one file and apply it with tpg-patch (tpg-fleet README, Upgrading to Round 14) |
| `MERGED_CONTENT_DIFFERS` | tpg-patch `pushMode=pr`: after the merge the Application stays OutOfSync, so the fleet branch renders other objects than the ones synced from the pull request (changes made in the pull request, or merged with other commits); nothing was synced or reverted | Compare the pull request with the fleet branch; `argocd app diff <app>` |
| `GIT_PUSH_FAILED` | The commit or the branch could not be pushed, or the pull request not opened | The push token (`tpg/shared/github-push`), branch protection |
| `OPERATOR_IMAGE_PINNED` | tpg-upgrade: the current operator values patch sets `operatorImage` with a tag that is not the running version | Fix the file with tpg-patch first |
| `MAX_BELOW_CURRENT` | tpg-scale-instance: the new `maxReadReplicas` is below the read replicas of an instance of the cluster (in the validate step; in the plan when that instance's scale did not happen) | Scale the instances down in the same run, or choose a larger cap |
| `FOREIGN_OPERATOR`, `FOREIGN_CRD`, `INSTANCE_NAME_IN_USE` | tpg-day0, tpg-create-instance: an object the fleet's Applications do not manage (section 4) | `argocd app get tpg-<cluster>-operator` lists what the Application manages |
| `OPERATOR_NOT_INSTALLED`, `NOT_IN_FLEET` | tpg-create-instance: the cluster has no operator of the fleet, or `fleet.yaml` does not declare it | Run tpg-day0 for the cluster first |
| `INSTANCE_EXISTS` | tpg-create-instance: the instance runs with other values (section 5) | tpg-patch, tpg-scale-instance or tpg-upgrade |
| `RENDER_FAILED`, `DRY_RUN_REJECTED` | tpg-create-instance, tpg-network-policy: the chart cannot render the objects, or the API server refuses them in a server-side dry run | The detail holds the message |
| `SPEC_NOT_APPLIED` | tpg-scale-instance: the live `spec.highAvailability` does not match the request after the sync (and, for `replicas=0`, after the `tpg-scale` apply) | `kubectl -n pg-<instance> get postgres <instance> -o yaml --show-managed-fields` |
| `CA_BUNDLE_MISSING` | `backupEnableSSL=true` or `enableSSL: true`, and `tpg-settings` has no `backupCaBundle` (at the plan, or removed before the commit) | `tpg-aks-infra/scripts/run.sh --only hub-secrets` |
| `CLUSTER_API_ERROR` | tpg-upgrade: a declared instance could not be read on the target (an error other than NotFound) | The detail holds the API error; check the cluster's API server and its kubeconfig Secret |
| `AZURE_BACKUP_UNSUPPORTED` | The PostgresBackupLocation CRD on the target has no `spec.storage.azure` (or `caBundle`) | `kubectl explain postgresbackuplocation.spec.storage` on the target |
| `CILIUM_NOT_AVAILABLE`, `ACNS_NOT_ENABLED` | A network policy needs Cilium, or `egressToFqdns` needs ACNS | Terraform `acns_enabled = true`, then `run.sh --only hub-secrets` |
| `EXPOSURE_NOT_APPLIED` | The instance's Services did not reach the requested exposure (load balancer addresses) within 5 minutes | `kubectl -n pg-<instance> get svc`, the Service events (subnet, quota, annotations) |
| `FLEET_CHANGED_DURING_RUN` | tpg-day0, tpg-create-instance: `clusters/fleet.yaml` changed for that cluster between the plan and the commit; the plan was not written for it | Run again |
| `POLICY_NOT_APPLIED`, `POLICY_NOT_REMOVED`, `BACKUP_EGRESS_BLOCKED`, `CLIENT_BLOCKED`, `NOT_ISOLATED` | tpg-network-policy checks after the sync (section 9) | The detail; `kubectl -n pg-<instance> get networkpolicy,ciliumnetworkpolicy` |
| `INVALID_INPUT` (`highAvailability=true needs readReplicas 1 or more`) | tpg-day0, tpg-create-instance: an HA instance with 0 read replicas (D69) | Set `readReplicas`, or `highAvailability=false` for a single node |
| `INVALID_INPUT` (`readReplicas N needs highAvailability=true`) | tpg-day0, tpg-create-instance: read replicas for a single node, in the inputs or on one `clusterMap` entry | Set `highAvailability=true`, or remove `readReplicas` |
| `FERRET_VERSION_UNSUPPORTED`, `FERRET_CRD_MISSING` | FerretDB below Postgres 17.5, or an operator without the PostgresFerretDocumentDB CRD (section 4) | `postgresVersion`; `kubectl get crd postgresferretdocumentdbs.sql.tanzu.vmware.com` |
| `FERRET_SECRET_MISSING` | The connection Secret a FerretDB names does not exist 2 minutes after the instance runs | The detail lists the db Secrets of `pg-<instance>`; set `ferretSecretName` or `ferretReadOnlySecretName` |
| `FERRET_NOT_READY` | The FerretDB Deployments did not become available | `kubectl -n pg-<instance> get pods -l 'app in (ferretdb-rw-<instance>,ferretdb-ro-<instance>)'`; the documentdb extension |
| `FERRET_READONLY_NEEDS_HA` | tpg-scale-instance `replicas=0` while FerretDB runs read-only proxies | Set `ferret.readOnlyReplicas: 0` with a tpg-patch values file first |

A `BLOCKED` cluster or instance fails a tpg-day0, tpg-create-instance or tpg-network-policy run in its last step (`gate`), after the other targets were deployed, so a partial run never ends `Succeeded`.

Warnings do not fail a run. They are listed in the Warnings part of the report:

| Warning | Meaning |
|---|---|
| `MANUAL_SYNC_DETECTED` | The last operation on a tpg target Application was started by a named user other than `workflow-bot`, or was an automated sync. Section 20 explains why that is refused. The workflow syncs the Application itself at its commit and carries on |
| `ORPHAN_CRD` | tpg-day0: Postgres CRDs exist without any operator; the operator sync adopts them |
| `HA_NODES_EXCEED_ZONES` | An HA instance has more database pods than its data pool has zones: Patroni does not fail over automatically when the zone of the leader and the synchronous standby is lost (section 4) |
| `EXPOSURE_UNRESTRICTED` | `loadBalancer` without `allowedSourceRanges`: port 5432 is open to the internet |
| `INSTANCE_NOT_DEPLOYED` | tpg-upgrade: an instance declared in `fleet.yaml` does not exist on the cluster and was left out (section 6) |
| `PROBE_NOT_RUN` | tpg-network-policy: a probe pod could not run; check that path by hand |
| `FERRET_EXTENSION_REQUIRED` | tpg-day0, tpg-create-instance, tpg-patch: FerretDB was switched on; it needs the documentdb extension in the instance, which the DBA prepares (section 4) |
| `HA_FIELD_CO_OWNED` | tpg-scale-instance `replicas=0`: `spec.highAvailability.enabled` stayed `true` after the sync because another field manager co-owns it; the step applied the single-node values as field manager `tpg-scale` (section 8) |

One line in the executor log is **not** an error, however it reads:

```text
level=INFO msg="saving parameter" argo=true src=/tmp/result dst=/var/run/argo/outputs/parameters//tmp/result
```

The Argo executor builds that destination as `/var/run/argo` +
`/outputs/parameters/` + the source path, so an absolute source path always
produces two slashes, and POSIX treats `//` inside a path as one separator. The
failure in such a log is the line above it (`sub-process exited ... exit status
1`): read the step's own `RESULT` line for what went wrong.

---

## 20. argocd CLI: inspect the sync steps behind the workflows

The workflows call the Argo CD API as the local account `workflow-bot`. Applications: `tpg-<cluster>-platform`, `tpg-<cluster>-operator`, `tpg-<cluster>-<instance>` (project `tpg`, the target Applications), and `tpg-hub-workflows` and `tpg-hub-monitoring` (project `tpg-hub`).

**Only the workflows sync the target Applications.** A sync started elsewhere would bypass the workflow gates: the pre-check, backups, the rollout order, the pod watch, and the revert of a failed patch. Three layers enforce this:

1. **Argo CD RBAC.** People are denied `sync` (which also covers rollback and terminating an operation), `override`, `update` and `delete` on `tpg/*`. `workflow-bot` (`role:tpg-sync`) may get and sync them. The deny lines are a marked block in `policy.csv` (`tpg-aks-infra argo/argocd-values.yaml`; on an existing hub, `scripts/hub/existing/check-argo.sh --yes` adds a line for every subject that could act on project `tpg`).
2. **Admission policy `tpg-application-sync`** on the hub. It refuses a new operation on a target Application unless argocd-server writes it for `workflow-bot`, and refuses switching on automated sync. It also covers a `kubectl edit` of the Application object, which Argo CD RBAC does not see. The Argo CD UI then shows `only the tpg workflows (Argo CD account workflow-bot) may sync tpg-...`.
3. **Detection.** Each workflow sync first checks who started the last operation on the Application, and reports `MANUAL_SYNC_DETECTED` (section 19) when a named user other than `workflow-bot` started it, or when it was an automated sync.

The hub Applications in project `tpg-hub` stay manageable. There is no break-glass role: fix the cause in Git and rerun the workflow.

```bash
# What exists and its state
argocd app list -l tpg.fleet/cluster=aks-tpg-poc-01
argocd app list -l tpg.fleet/component=operator
argocd app get tpg-aks-tpg-poc-01-orders-db --show-operation
argocd appset get tpg-instances
argocd cluster list

# Who started the last operation (workflow-bot, or workflow-bot:apiKey for its token)
argocd app get tpg-aks-tpg-poc-01-orders-db -o json | jq -r '.status.operationState.operation.initiatedBy'

# Hub workflows (templates, scripts, RBAC, admission policies) after a change in Git: project tpg-hub, allowed
argocd app get tpg-hub-workflows --refresh
argocd app sync tpg-hub-workflows && argocd app wait tpg-hub-workflows --health --timeout 300

# Regenerate Applications right after a fleet.yaml commit (same as the workflows; not a sync)
kubectl -n argocd annotate applicationset tpg-instances argocd.argoproj.io/application-set-refresh=true --overwrite
kubectl -n argocd annotate applicationset tpg-operator argocd.argoproj.io/application-set-refresh=true --overwrite

# Operator upgrade check: the rendered chart version and the fleet value file after the fleet.yaml commit
argocd app get tpg-aks-tpg-poc-01-operator -o json | jq '.spec.sources'
argocd app diff tpg-aks-tpg-poc-01-operator

# tpg-patch with pushMode=pr: the commit each Application was last synced at (the
# pull request branch until the merge), and the source revisions of the operator
argocd app history tpg-aks-tpg-poc-02-orders-db
argocd app get tpg-aks-tpg-poc-01-operator -o json | jq '.status.history[-1].revisions'

# Scale or patch check: the Postgres spec Argo CD will apply
argocd app manifests tpg-aks-tpg-poc-02-orders-db --source git | yq 'select(.kind == "Postgres") | .spec'

# Before Round 14: fields the removed tpg-patch field manager still owns on the target
# (release them as the tpg-fleet README, Upgrading to Round 14, shows)
kubectl --context aks-tpg-poc-01 -n tanzu-postgres-operator get deploy -o json --show-managed-fields \
  | jq '.items[] | {name: .metadata.name, tpgPatch: [.metadata.managedFields[] | select(.manager == "tpg-patch") | .fieldsV1]}'

# The operator's CRDs and Deployment, which the workflows check directly before hard-refreshing
kubectl --context aks-tpg-poc-01 get crd postgres.sql.tanzu.vmware.com -o jsonpath='{.status.conditions[?(@.type=="Established")].status}'
kubectl --context aks-tpg-poc-01 -n tanzu-postgres-operator get deploy

# Troubleshooting a failed sync (read-only)
argocd app get tpg-aks-tpg-poc-01-orders-db --hard-refresh
argocd app history tpg-aks-tpg-poc-01-orders-db
argocd repo list

# These are refused for people on tpg/* (RBAC, then the admission policy)
#   argocd app sync tpg-aks-tpg-poc-01-orders-db        -> permission denied
#   argocd app rollback tpg-aks-tpg-poc-01-orders-db 3  -> permission denied
#   argocd app terminate-op tpg-aks-tpg-poc-01-orders-db
#   argocd app set tpg-aks-tpg-poc-01-orders-db --sync-policy automated
```

The delete workflows remove target Applications by removing their `clusters/fleet.yaml` entries (the ApplicationSet deletes the Application without cascade) and delete database objects in order; `argocd app delete` is refused for people.
