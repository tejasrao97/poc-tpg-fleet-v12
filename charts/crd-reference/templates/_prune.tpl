{{- /* GENERATED copy of charts/tpg-instance/templates/_prune.tpl (tools/crd-defaults/generate.py). Do not edit. */ -}}
{{- /*
tpg.prune (dict "obj" OBJECT "root" $): leave out of OBJECT.spec every field
that holds its zero default (design decision D69). OBJECT is changed in place.

The fields come from files/zero-defaults.yaml, which
tools/crd-defaults/generate.py builds from the live CRDs in
charts/crd-reference/source-crds and charts/crd-reference/defaults-overlay.yaml:
  skip           a field whose default is false, 0, [] or {} (the CRD schema
                 default, or the operator default the documentation gives);
                 left out when it holds exactly that value
  dropWhenEqual  an object left out as a whole when it equals the given value
  keepEmpty      objects the schema requires: kept even when they become empty
A field whose default is not zero (enableSSL, backupSync.enabled and
backupIntegrityValidation.enabled default to true, dedicatedWalLogVolume too)
is never in the registry, so false is always written for it. A parent object
that a skipped field leaves empty is left out too, unless it is in keepEmpty.

Why: a field left out takes the same default on the API server or in the
operator, so declaring a zero default gains nothing, and it costs a diff that
no sync settles wherever a writer drops the field: the PostgresBackupLocation
fields the CRD serializes with omitempty (Round 9), and the single-node
highAvailability block (enabled false, readReplicas 0) reported OutOfSync in
Round 12.

This file is the canonical copy; tools/crd-defaults/generate.py copies it to
charts/crd-reference/templates/_prune.tpl (--check fails when they differ).
*/ -}}
{{- define "tpg.prune" -}}
{{- $reg := .root.Files.Get "files/zero-defaults.yaml" | fromYaml -}}
{{- if not $reg.kinds }}{{ fail "files/zero-defaults.yaml is missing or empty: run tools/crd-defaults/generate.py" }}{{ end -}}
{{- $k := get $reg.kinds (toString .obj.kind) -}}
{{- if and $k (kindIs "map" .obj.spec) -}}
{{-   $keep := default list $k.keepEmpty -}}
{{-   range $e := (default list $k.dropWhenEqual) -}}
{{-     include "tpg.pruneAt" (dict "spec" $.obj.spec "path" $e.path "value" $e.equals "keep" $keep) -}}
{{-   end -}}
{{-   range $e := (default list $k.skip) -}}
{{-     include "tpg.pruneAt" (dict "spec" $.obj.spec "path" $e.path "value" $e.default "keep" $keep) -}}
{{-   end -}}
{{- end -}}
{{- end -}}

{{- /*
tpg.pruneAt (dict "spec" MAP "path" "a.b.c" "value" ZERO "keep" LIST): remove
spec.a.b.c when it equals ZERO (compared as JSON), then every parent map that
became empty, from the innermost outwards, unless its path is in keep. A path
that does not exist, or runs through a list, is left alone.
*/ -}}
{{- define "tpg.pruneAt" -}}
{{- $parts := splitList "." .path -}}
{{- $cur := .spec -}}
{{- $chain := list -}}
{{- $found := true -}}
{{- range $i, $p := $parts -}}
{{-   if $found -}}
{{-     if and (kindIs "map" $cur) (hasKey $cur $p) -}}
{{-       $chain = append $chain (dict "m" $cur "k" $p "path" (join "." (slice $parts 0 (add1 $i)))) -}}
{{-       $cur = get $cur $p -}}
{{-     else -}}
{{-       $found = false -}}
{{-     end -}}
{{-   end -}}
{{- end -}}
{{- if and $found (eq (toJson $cur) (toJson .value)) -}}
{{-   $n := len $chain -}}
{{-   $last := index $chain (sub $n 1) -}}
{{-   $_ := unset $last.m $last.k -}}
{{-   $up := true -}}
{{-   range $j := until (sub $n 1 | int) -}}
{{-     if $up -}}
{{-       $e := index $chain (sub (sub $n 2) $j) -}}
{{-       $v := get $e.m $e.k -}}
{{-       if and (kindIs "map" $v) (eq (len $v) 0) (not (has $e.path $.keep)) -}}
{{-         $_ := unset $e.m $e.k -}}
{{-       else -}}
{{-         $up = false -}}
{{-       end -}}
{{-     end -}}
{{-   end -}}
{{- end -}}
{{- end -}}
