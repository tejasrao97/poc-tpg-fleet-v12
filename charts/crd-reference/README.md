# charts/crd-reference: the 9 Tanzu for Postgres CRDs

Reference only. No Argo CD Application points at this folder and nothing installs it. It holds the
9 custom resource definitions of the Tanzu for Postgres operator 4.5.0 as they run in the lab, and
one template per kind that documents every field with its default (design decision D73). The
fleet's rule for zero defaults (design decision D69) is generated from here.

## 1. Contents

| Path | What it is | Edited by |
|---|---|---|
| `source-crds/*.yaml` | The live CRDs (`kubectl get crd <name> -o yaml`, volatile metadata and status removed). The folder is not named `crds/`, so Helm would never install them | Hand, when the operator version changes |
| `defaults-overlay.yaml` | Defaults the operator applies itself that the schemas do not declare, with the documentation page each comes from | Hand |
| `templates/<kind>.yaml` | One reference template per kind: the table of its fields (type, default, required, skipped when), then the render | `tools/crd-defaults/generate.py` |
| `templates/_prune.tpl` | Copy of `charts/tpg-instance/templates/_prune.tpl` | `tools/crd-defaults/generate.py` |
| `files/zero-defaults.yaml` | The registry of fields left out when they hold their zero default (also written to `charts/tpg-instance/files/`) | `tools/crd-defaults/generate.py` |
| `schemas/sql.tanzu.vmware.com/<kind>_v1.json` | JSON schemas for `kubeconform -strict` (`scripts/validate.sh`, `tests/chart`, `tests/crd-reference`) | `tools/crd-defaults/generate.py` |
| `examples/<kind>.yaml` | The 4.5 documentation sample of each kind, adapted to the fleet names | Hand |
| `values.yaml` | Every kind off, with an empty spec | Hand |

The 9 kinds: Postgres, PostgresBackupLocation, PostgresBackup, PostgresBackupSchedule,
PostgresRestore, PostgresMigration, PostgresVersion (cluster-scoped), PostgresVersionUpgrade and
PostgresFerretDocumentDB.

## 2. Where each kind is rendered in the fleet

| Kind | Rendered by |
|---|---|
| Postgres, PostgresBackupLocation | `charts/tpg-instance` (the instance Application) |
| PostgresBackupSchedule | `charts/tpg-instance`, only with `backup.operatorSchedules` (input `backupSchedule=operator`, D70) |
| PostgresFerretDocumentDB | `charts/tpg-instance`, only with `ferret.enabled` (input `ferret=true`, D71) |
| PostgresBackup | `workflows/scripts/backup-instance.sh` (inline), and the operator from a PostgresBackupSchedule |
| PostgresRestore, and the source PostgresBackupLocation copy | `workflows/scripts/restore.sh` (inline) |
| PostgresVersionUpgrade | `workflows/scripts/postgres-upgrade.sh` (inline) |
| PostgresVersion | The operator chart (the `tpg-operator` Application) |
| PostgresMigration | Nothing in the fleet |

The inline objects of the workflow scripts carry no zero default either: `tests/crd-reference`
renders the matching reference template for the same spec and fails when they differ.

## 3. The zero-default rule (D69)

A field left out takes the same default on the API server (schema defaults) or in the operator
(documented defaults), so declaring a zero default gains nothing. It costs a diff that no sync
settles wherever a writer drops the field: the PostgresBackupLocation fields the CRD serializes with
`omitempty` (Round 9), and the single-node `highAvailability: {enabled: false, readReplicas: 0}`
block reported OutOfSync in Round 12. Every object the fleet renders therefore leaves out a field
that holds its zero default. A field is in the registry when:

- its schema default is `false`, `0`, `[]` or `{}` (a required field with such a default is
  included: the API server fills the default before it validates), or
- `defaults-overlay.yaml` names it: no schema default, but the 4.5 documentation gives a zero
  default (`highAvailability.enabled` false, `readReplicas` 0, `dataPodConfig.tolerations` and
  `env` [], the Service annotation maps, `forcePathStyle` false, `pvc.keepAfterDelete` false,
  `pitr.bestEffort` false, PostgresMigration `instances` []).

Never in the registry: a field whose default is not zero (`enableSSL`, `backupSync.enabled` and
`backupIntegrityValidation.enabled` default to `true`, `dedicatedWalLogVolume` too, FerretDB
`readWrite.replicas` and `readOnly.replicas` to 1), and a field that is required without a
default (`deploymentOptions.continuousRestoreTarget`). Where such a field holds the zero value and
the whole object means "not set", the overlay drops the object instead (`dropWhenEqual`):
`deploymentOptions: {continuousRestoreTarget: false}`, FerretDB `readOnly: {replicas: 0}`.

A parent object that the skipped fields leave empty is left out too, unless the schema requires it
(`keepEmpty`: FerretDB `service`, for example). Paths never run through a list. PostgresRestore
carries a whole Postgres spec under `targetInstance.spec`: the Postgres entries apply there too.

`clusters/fleet.yaml` keeps explicit values (`enabled: false`, `readReplicas: 0`): the chart is
what leaves them out, because `clusters/_template/instance.yaml` defaults to `true` and `1`.

## 4. Use

```bash
# One kind with its documentation example
helm template ref charts/crd-reference -f charts/crd-reference/examples/postgresBackup.yaml

# Your own object: name and spec as values
helm template ref charts/crd-reference --set postgresBackup.enabled=true \
  --set postgresBackup.name=orders-db-full --set postgresBackup.spec.sourceInstance.name=orders-db

# Check a manifest against the live CRD schemas
kubeconform -strict -schema-location 'charts/crd-reference/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' my-postgres.yaml
```

## 5. A new operator version

1. Export the 9 CRDs from a cluster that runs it into `source-crds/`
   (`kubectl get crd <name>.sql.tanzu.vmware.com -o yaml`; remove `status`, `creationTimestamp`,
   `resourceVersion`, `uid` and `generation`).
2. Read the release notes and the CRD reference of the new documentation for defaults the
   schemas do not declare, and update `defaults-overlay.yaml`.
3. `python3 tools/crd-defaults/generate.py`, then `tests/crd-reference/run.sh`,
   `tests/chart/run.sh` and `scripts/validate.sh`. The generator refuses an overlay entry whose
   path left the schema, whose field became required without a default, or whose schema default
   changed.
