{{- define "tpg.required" -}}
{{- if not .Values.instance.name }}{{ fail "instance.name is required" }}{{ end -}}
{{- if not .Values.instance.postgresVersion }}{{ fail "instance.postgresVersion is required" }}{{ end -}}
{{- if not .Values.backup.container }}{{ fail "backup.container is required" }}{{ end -}}
{{- if hasKey .Values.instance "serviceType" }}{{ fail "instance.serviceType is replaced by instance.exposure (clusterIP, internalLoadBalancer or loadBalancer)" }}{{ end -}}
{{- end -}}

{{- /*
tpg.exposure (dict "exposure" E "subnet" S "ranges" LIST "extra" MAP): the Service
type and annotations of one exposure (design decision D64):
  clusterIP             ClusterIP, no annotations
  internalLoadBalancer  LoadBalancer + azure-load-balancer-internal: "true"
                        (+ azure-load-balancer-internal-subnet when a subnet is set)
  loadBalancer          LoadBalancer on the public frontend of the cluster
Both load balancer kinds get azure-allowed-ip-ranges from allowedSourceRanges.
extra (serviceAnnotations) is added last. An empty map or list is never rendered:
the CRD drops it and Argo CD would report a difference forever (F7).
Returns YAML {type: ..., annotations: {...}}.
*/ -}}
{{- define "tpg.exposure" -}}
{{- $e := default "clusterIP" .exposure -}}
{{- if not (has $e (list "clusterIP" "internalLoadBalancer" "loadBalancer")) }}{{ fail (printf "exposure %q must be clusterIP, internalLoadBalancer or loadBalancer" $e) }}{{ end -}}
{{- $a := dict -}}
{{- if eq $e "internalLoadBalancer" -}}
{{-   $_ := set $a "service.beta.kubernetes.io/azure-load-balancer-internal" "true" -}}
{{-   with .subnet }}{{ $_ := set $a "service.beta.kubernetes.io/azure-load-balancer-internal-subnet" . }}{{ end -}}
{{- end -}}
{{- if and (ne $e "clusterIP") .ranges -}}
{{-   $_ := set $a "service.beta.kubernetes.io/azure-allowed-ip-ranges" (join "," .ranges) -}}
{{- end -}}
{{- range $k, $v := (default dict .extra) }}{{ $_ := set $a $k (toString $v) }}{{ end -}}
{{- toYaml (dict "type" (ternary "ClusterIP" "LoadBalancer" (eq $e "clusterIP")) "annotations" $a) -}}
{{- end -}}

{{- /*
tpg.services: the Service fields of the Postgres spec. readOnlyServiceType is
written only when the read-only Service is not ClusterIP (the CRD default), so
the specs of existing instances do not change.
*/ -}}
{{- define "tpg.services" -}}
{{- $i := .Values.instance -}}
{{- $rw := include "tpg.exposure" (dict "exposure" $i.exposure "subnet" $i.internalLoadBalancerSubnet "ranges" $i.allowedSourceRanges "extra" $i.serviceAnnotations) | fromYaml -}}
{{- $ro := include "tpg.exposure" (dict "exposure" $i.readOnlyExposure "subnet" $i.internalLoadBalancerSubnet "ranges" $i.allowedSourceRanges "extra" $i.readOnlyServiceAnnotations) | fromYaml -}}
serviceType: {{ $rw.type }}
{{- with $rw.annotations }}
serviceAnnotations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- if ne $ro.type "ClusterIP" }}
readOnlyServiceType: {{ $ro.type }}
{{- end }}
{{- with $ro.annotations }}
readOnlyServiceAnnotations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{- /*
tpg.deepMerge (dict "dst" MAP "src" MAP): merge src into dst, in place.
Maps are merged key by key; any other value in src replaces the one in dst,
including false, 0 and "" (unlike mergeOverwrite, which skips empty values);
a list replaces the whole list; a key set to null in src is removed from dst.
*/ -}}
{{- define "tpg.deepMerge" -}}
{{- $dst := .dst -}}
{{- range $k, $v := .src -}}
{{-   if kindIs "invalid" $v -}}
{{-     $_ := unset $dst $k -}}
{{-   else if and (kindIs "map" $v) (kindIs "map" (get $dst $k)) -}}
{{-     $_ := include "tpg.deepMerge" (dict "dst" (get $dst $k) "src" $v) -}}
{{-   else -}}
{{-     $_ := set $dst $k $v -}}
{{-   end -}}
{{- end -}}
{{- end -}}

{{- /*
tpg.patchRef (dict "root" $ "kind" "values"|"postgres"): the current patch file of
the instance for that kind, a path relative to this chart, or "" (Round 14, D78).
tpg-patch and tpg-create-instance record it in clusters/fleet.yaml:
  clusters.<cluster>.instances.<instance>.patches.values     chart values fragment
  clusters.<cluster>.instances.<instance>.patches.postgres   partial Postgres manifest
each as {current: patches/<name>-<uid>.yaml, previous: {path, commit}}; only
current is applied. The tpg-instances ApplicationSet passes clusters/fleet.yaml as
a value file, so the entry is read from Git at the commit being synced (a pull
request branch before the merge), not from the copy the ApplicationSet made of
the fleet branch; without that file (a render by hand) .Values.patches is used.
A Round 11 list with one file counts as current; a longer list fails the render.
*/ -}}
{{- define "tpg.patchRef" -}}
{{- $v := .root.Values -}}
{{- $node := "" -}}
{{- if hasKey $v "clusters" -}}
{{- /* dig on the nested map: .Values itself is chartutil.Values, which dig cannot read */ -}}
{{-   $node = dig (toString $v.cluster.name) "instances" (toString $v.instance.name) "patches" .kind "" (default dict $v.clusters) -}}
{{- else -}}
{{-   $node = get (default dict $v.patches) .kind -}}
{{- end -}}
{{- if kindIs "slice" $node -}}
{{-   if gt (len $node) 1 }}{{ fail (printf "patches.%s of %s lists %d files: Round 14 applies one current file; merge them into one and apply it with tpg-patch (tpg-fleet README, Upgrading to Round 14)" .kind (toString $v.instance.name) (len $node)) }}{{ end -}}
{{-   if $node }}{{ first $node }}{{ end -}}
{{- else if kindIs "map" $node -}}
{{-   default "" $node.current -}}
{{- else if kindIs "string" $node -}}
{{-   $node -}}
{{- end -}}
{{- end -}}

{{- /*
tpg.patchFile (dict "root" $ "file" PATH "what" LABEL): a patch file of this chart
parsed as YAML (a map). Patch files live in charts/tpg-instance/patches/.
Returns YAML; fails the render when the file is missing or not a YAML map.
*/ -}}
{{- define "tpg.patchFile" -}}
{{- $raw := .root.Files.Get .file -}}
{{- if not $raw }}{{ fail (printf "%s patch file %s not found in the chart (charts/tpg-instance/%s)" .what .file .file) }}{{ end -}}
{{- $p := fromYaml $raw -}}
{{- if hasKey $p "Error" }}{{ fail (printf "%s patch file %s is not a YAML map: %s" .what .file $p.Error) }}{{ end -}}
{{- toYaml $p -}}
{{- end -}}

{{- /*
tpg.ctx: a context like the root one - .Values and .Release - whose values have
the instance's current values patch file (tpg.patchRef values) merged in, then
valuesOverride (written by tpg-restore only). clusters (clusters/fleet.yaml as a
value file) is left out of it. Templates render from it:
  {{- with (include "tpg.ctx" . | fromYaml) }} ... {{- end }}
*/ -}}
{{- define "tpg.ctx" -}}
{{- $v := omit (deepCopy .Values) "clusters" -}}
{{- $f := include "tpg.patchRef" (dict "root" $ "kind" "values") -}}
{{- if $f -}}
{{-   $_ := include "tpg.deepMerge" (dict "dst" $v "src" (include "tpg.patchFile" (dict "root" $ "file" $f "what" "values") | fromYaml)) -}}
{{- end -}}
{{- $_ := include "tpg.deepMerge" (dict "dst" $v "src" (default dict .Values.valuesOverride)) -}}
{{- toYaml (dict "Values" $v "Release" (dict "Namespace" .Release.Namespace "Name" .Release.Name)) -}}
{{- end -}}
