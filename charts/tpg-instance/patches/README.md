# Instance patch files

tpg-patch patches running Postgres instances, and tpg-create-instance shapes new
instances from their first render, with files the workflows store in this folder
(Round 14, design decisions D76 to D79). You write the file on the machine that
submits the run and pass its relative path; its contents travel in the input
`patchFiles` (`scripts/submit/tpg-patch.sh` and `tpg-create-instance.sh` fill it,
`scripts/submit/pack-patch-files.sh` prints it). The workflow stores it here as
`<name>-<uid>.yaml`, with a unique 5-character UID, because the chart reads it
itself (`.Files.Get`) and so it must live inside the chart. Do not add or edit
files here by hand.

The instance entry in `clusters/fleet.yaml` records one current file per kind and
the one before it, relative to `charts/tpg-instance/`:

```yaml
clusters:
  aks-tpg-poc-01:
    instances:
      orders-db:
        patches:
          postgres:
            current: patches/orders-memory-q7m2d.yaml            # postgresPatchFilePath
          values:
            current: patches/orders-backup-k3x9q.yaml            # valuesPatchFilePath
            previous: {path: patches/orders-retention-a81zd.yaml, commit: 4f2c1e9a...}
```

| Kind of file | Input and clusterMap key | Content | Applied |
|---|---|---|---|
| Postgres patch | `postgresPatchFilePath` | `apiVersion: sql.tanzu.vmware.com/v1`, `kind: Postgres` and a `spec` fragment; every field is checked against the Postgres CRD | merged into the rendered Postgres `spec` |
| Values patch | `valuesPatchFilePath` | a fragment of the chart values; every key must exist in `values.yaml` or `clusters/_template/` | merged into the values before the chart renders |

Only the current file is applied: maps merge key by key, any other value
(including `false`, `0` and `""`) replaces the rendered one, a list replaces the
whole list, and `null` removes a key. The `tpg-instances` ApplicationSet passes
`clusters/fleet.yaml` as a value file, so a sync at the commit of a tpg-patch pull
request branch applies that branch's current file before the merge.

tpg-patch refuses a file of the wrong kind (a Postgres manifest passed as values,
and the reverse), unknown keys and fields, fields that another workflow owns,
fields that cannot change on a running instance, and fields the `tpg-instances`
ApplicationSet ignores (`backup.additionalParameters`, `backup.enableSSL`,
`backup.forcePathStyle`); see `docs/workflow-commands.md`, tpg-patch. The Service
fields of the Postgres spec (`serviceType`, `serviceAnnotations`,
`readOnlyServiceType`, `readOnlyServiceAnnotations`) come from the exposure values,
so a Postgres patch may not set them: change the exposure with a values patch, for
example `instance: {exposure: internalLoadBalancer}`. tpg-create-instance applies
its own creation rules (sizes and the storage class may be set there); see
`docs/workflow-commands.md`, tpg-create-instance.

`example-postgres-resources-ex4m1.yaml` and `example-values-backup-ex4m2.yaml` are
examples in the stored form, referenced by `clusters/fleet.example.yaml`. Operator
values files live in `patches/operator/` at the repository root.
