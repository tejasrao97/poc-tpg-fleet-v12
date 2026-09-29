# Operator patch files

tpg-patch stores the operator values files it receives here (Round 14, design
decisions D76 to D79): `patches/operator/<name>-<uid>.yaml`, recorded per cluster as
`clusters.<cluster>.operator.patches.values.current` (and `previous`) in
`clusters/fleet.yaml`. The current file of a cluster is copied to
`patches/operator/clusters/<cluster>.yaml`, which the `tpg-operator` Application reads
as a value file (`$fleet/patches/operator/clusters/<cluster>.yaml`); a fixed path, so
a sync at the commit of a tpg-patch pull request branch reads that branch's values.
`scripts/validate.sh` checks that each copy equals its current file. Do not add or
edit files here by hand: write the file on the machine that submits the run and pass
it as `operatorValuesPatchFilePath` (see `docs/workflow-commands.md`, tpg-patch).

An operator values file may set only `operatorImage` (the tag must be the cluster's
operator version; tpg-upgrade moves it with the version), `instanceRegistryRepo`,
`ferretDBImageRepo`, `dockerRegistrySecretName`, `certManagerClusterIssuerName`,
`certManagerNamespace`, `resources` (`limits` and `requests`, `cpu` and `memory`) and
`enableSecurityContext`. Operator manifest patches (`operatorManifestPatchFilePath`)
were removed in Round 14. `example-operator-values-ex4m3.yaml` is an example in the
stored form, referenced by `clusters/fleet.example.yaml`. Instance patch files live
in `charts/tpg-instance/patches/`.
