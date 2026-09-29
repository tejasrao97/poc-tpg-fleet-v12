#!/usr/bin/env python3
"""Zero-default registry, reference templates and JSON schemas of the 9 Tanzu Postgres CRDs
(design decisions D69 and D73).

  python3 tools/crd-defaults/generate.py           write the generated files
  python3 tools/crd-defaults/generate.py --check   exit 1 when a generated file is out of date

Inputs (charts/crd-reference):
  source-crds/*.yaml       the live CRDs of operator 4.5.0 (kubectl get crd -o yaml)
  defaults-overlay.yaml    operator defaults the schemas do not declare (4.5 docs)

Outputs:
  charts/tpg-instance/files/zero-defaults.yaml   the registry tpg.prune reads (design decision D69)
  charts/crd-reference/files/zero-defaults.yaml  the same registry for the reference chart
  charts/crd-reference/templates/_prune.tpl      copy of charts/tpg-instance/templates/_prune.tpl
  charts/crd-reference/templates/<kind>.yaml     one reference template per kind, with the table of
                                                 its fields (type, default, required, skipped when)
  charts/crd-reference/schemas/<group>/<kind>_v1.json
                                                 JSON schemas for kubeconform -strict (objects
                                                 closed; a required field with a schema
                                                 default is not required, because the API
                                                 server fills it before it validates)

The registry lists, per kind, the spec fields that are left out of a rendered
object when they hold their zero default (false, 0, [] or {}):
  - every field whose schema default is zero (a required field with a schema
    default is included: the API server fills the default before validation);
  - the overlay "skip" entries (no schema default, zero default in the docs).
A field that is required without a schema default is never skipped alone; the
overlay "dropWhenEqual" entries leave its whole object out instead. Paths never
run through a list. Fields whose default is not zero are never listed.
"""
import argparse
import copy
import json
import os
import sys

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
REF = os.path.join(ROOT, "charts", "crd-reference")
INST = os.path.join(ROOT, "charts", "tpg-instance")

KINDS = [  # kind, values key of the reference chart
    ("Postgres", "postgres"),
    ("PostgresBackupLocation", "postgresBackupLocation"),
    ("PostgresBackup", "postgresBackup"),
    ("PostgresBackupSchedule", "postgresBackupSchedule"),
    ("PostgresRestore", "postgresRestore"),
    ("PostgresMigration", "postgresMigration"),
    ("PostgresVersion", "postgresVersion"),
    ("PostgresVersionUpgrade", "postgresVersionUpgrade"),
    ("PostgresFerretDocumentDB", "postgresFerretDocumentDB"),
]
# Objects the field tables do not expand (Kubernetes core types, or the embedded
# Postgres spec of PostgresRestore, which postgres.yaml documents)
OPAQUE = {
    "Postgres": {"dataPodConfig.affinity", "resources.data", "resources.metrics", "seccompProfile"},
    "PostgresRestore": {"targetInstance.spec"},
}


def is_zero(v):
    if isinstance(v, bool):
        return v is False
    if isinstance(v, (int, float)):
        return v == 0
    return v == [] or v == {}


def load_crds():
    crds = {}
    for f in sorted(os.listdir(os.path.join(REF, "source-crds"))):
        if not f.endswith(".yaml"):
            continue
        with open(os.path.join(REF, "source-crds", f)) as fh:
            c = yaml.safe_load(fh)
        crds[c["spec"]["names"]["kind"]] = (f, c)
    missing = [k for k, _ in KINDS if k not in crds]
    if missing:
        raise SystemExit(f"source-crds: missing CRDs for {', '.join(missing)}")
    return crds


def version_schema(crd):
    v = [x for x in crd["spec"]["versions"] if x.get("storage")] or crd["spec"]["versions"]
    return v[0]


def walk(schema, prefix="", required=False, in_list=False):
    """Yield (path, schema, required, in_list) for every property below schema (spec-relative paths)."""
    req = set(schema.get("required", []))
    for name, sub in (schema.get("properties") or {}).items():
        path = f"{prefix}.{name}" if prefix else name
        yield path, sub, name in req, in_list
        if sub.get("type") == "object" or "properties" in sub:
            yield from walk(sub, path, name in req, in_list)
        if sub.get("type") == "array" and isinstance(sub.get("items"), dict):
            yield from walk(sub["items"], path + "[]", False, True)


def node_at(spec_schema, path):
    cur = spec_schema
    parent = None
    for p in path.split("."):
        props = cur.get("properties") or {}
        if p not in props:
            return None, None
        parent, cur = cur, props[p]
    return cur, parent


def build_registry(crds, overlay):
    reg = {}
    for kind, _ in KINDS:
        spec = version_schema(crds[kind][1])["schema"]["openAPIV3Schema"]["properties"]["spec"]
        skip, keep = {}, set()
        for path, sub, required, in_list in walk(spec):
            if in_list:
                continue
            if "default" in sub and is_zero(sub["default"]):
                skip[path] = {"path": path, "default": sub["default"], "source": "schema"}
            if required and (sub.get("type") == "object" or "properties" in sub):
                keep.add(path)
        ov = (overlay.get("kinds") or {}).get(kind, {})
        entries = [(kind, "", e) for e in ov.get("skip", [])]
        drops = [(kind, "", e) for e in ov.get("dropWhenEqual", [])]
        for at, other in (ov.get("embeds") or {}).items():
            oo = (overlay.get("kinds") or {}).get(other, {})
            entries += [(other, at + ".", e) for e in oo.get("skip", [])]
            drops += [(other, at + ".", e) for e in oo.get("dropWhenEqual", [])]
        for src_kind, pre, e in entries:
            path = pre + e["path"]
            node, parent = node_at(spec, path)
            if node is None:
                raise SystemExit(f"defaults-overlay.yaml: {src_kind} {e['path']}: not in the {kind} schema")
            if not is_zero(e["default"]):
                raise SystemExit(f"defaults-overlay.yaml: {kind} {path}: default must be false, 0, [] or {{}}")
            name = path.split(".")[-1]
            if name in (parent.get("required") or []) and "default" not in node:
                raise SystemExit(f"defaults-overlay.yaml: {kind} {path} is required without a schema default: "
                                 f"use dropWhenEqual on its object")
            if "default" in node and node["default"] != e["default"]:
                raise SystemExit(f"defaults-overlay.yaml: {kind} {path}: the schema default is {node['default']!r}")
            skip[path] = {"path": path, "default": e["default"], "source": e.get("source", "docs")}
        drop_list = []
        for src_kind, pre, e in drops:
            path = pre + e["path"]
            if node_at(spec, path)[0] is None:
                raise SystemExit(f"defaults-overlay.yaml: {src_kind} {e['path']}: not in the {kind} schema")
            drop_list.append({"path": path, "equals": e["equals"], "source": e.get("source", "docs")})
        entry = {"skip": [skip[p] for p in sorted(skip)]}
        if drop_list:
            entry["dropWhenEqual"] = sorted(drop_list, key=lambda d: d["path"])
        if keep:
            entry["keepEmpty"] = sorted(keep)
        reg[kind] = entry
    return reg


class _NoAliases(yaml.SafeDumper):
    """Write repeated values in full: the registry is read by people too."""

    def ignore_aliases(self, data):
        return True


def registry_text(reg):
    header = (
        "# GENERATED by tools/crd-defaults/generate.py from charts/crd-reference/source-crds\n"
        "# and charts/crd-reference/defaults-overlay.yaml. Do not edit.\n"
        "#\n"
        "# Spec fields left out of a rendered object when they hold their zero default\n"
        "# (templates/_prune.tpl, design decision D69). source: schema (the CRD default)\n"
        "# or the documentation page the overlay names.\n"
    )
    return header + yaml.dump({"kinds": reg}, Dumper=_NoAliases, sort_keys=False, width=200, default_flow_style=False)


def show(v):
    if v is None:
        return "-"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, str):
        return '""' if v == "" else v
    return json.dumps(v, separators=(",", ":"))


def field_rows(kind, spec, reg):
    skipped = {e["path"]: e for e in reg.get("skip", [])}
    dropped = {e["path"]: e for e in reg.get("dropWhenEqual", [])}
    opaque = OPAQUE.get(kind, set())
    rows = []

    def rec(schema, prefix):
        req = set(schema.get("required", []))
        for name, sub in sorted((schema.get("properties") or {}).items()):
            path = f"{prefix}.{name}" if prefix else name
            t = sub.get("type", "")
            if sub.get("x-kubernetes-int-or-string"):
                t = "int-or-string"
            if t == "array":
                it = (sub.get("items") or {}).get("type", "")
                t = f"array of {it}" if it else "array"
            skip = ""
            if path in skipped:
                skip = show(skipped[path]["default"]) + (" (docs)" if skipped[path]["source"] != "schema" else "")
            elif path in dropped:
                skip = "object dropped when " + show(dropped[path]["equals"])
            rows.append((path, t or "object", show(sub.get("default")), "yes" if name in req else "no", skip))
            if path in opaque:
                continue
            if sub.get("type") == "object" or "properties" in sub:
                rec(sub, path)

    rec(spec, "")
    return rows


def reference_template(kind, key, fname, crd, reg):
    ver = version_schema(crd)
    spec = ver["schema"]["openAPIV3Schema"]["properties"]["spec"]
    group = crd["spec"]["group"]
    scope = crd["spec"]["scope"]
    rows = field_rows(kind, spec, reg)
    w = [max(len(r[i]) for r in rows + [("Field (spec.)", "Type", "Default", "Required", "Skipped when")]) for i in range(5)]
    head = ("Field (spec.)", "Type", "Default", "Required", "Skipped when")
    lines = ["  ".join(c.ljust(w[i]) for i, c in enumerate(head)).rstrip()]
    lines += ["  ".join(c.ljust(w[i]) for i, c in enumerate(r)).rstrip() for r in rows]
    opaque = sorted(OPAQUE.get(kind, set()))
    note = ""
    if opaque:
        note = ("Not expanded: " + ", ".join(opaque) +
                (" (the Postgres spec: see postgres.yaml; its skip entries apply under that path too)"
                 if kind == "PostgresRestore" else " (Kubernetes core types)") + ".\n")
    ns_line = "" if scope == "Namespaced" else "Cluster-scoped: no namespace.\n"
    table = "\n".join(lines)
    return f"""{{{{- /*
{kind} ({group}/{ver['name']}, {scope}): reference template.
GENERATED by tools/crd-defaults/generate.py from source-crds/{fname} and
defaults-overlay.yaml. Do not edit.

Rendered only when {key}.enabled is true (values.yaml): {key}.name,
{key}.labels, {key}.annotations and {key}.spec are written as given, then
tpg.prune leaves out every field whose "Skipped when" value it holds (a parent
left empty goes too, unless the schema requires it).
{ns_line}{note}
{table}
*/ -}}}}
{{{{- with .Values.{key} }}}}
{{{{- if .enabled }}}}
{{{{- $obj := dict "apiVersion" "{group}/{ver['name']}" "kind" "{kind}" "metadata" (dict "name" (required "{key}.name is required" .name)) "spec" (deepCopy (default dict .spec)) }}}}
{{{{- with .labels }}}}{{{{ $_ := set $obj.metadata "labels" . }}}}{{{{ end }}}}
{{{{- with .annotations }}}}{{{{ $_ := set $obj.metadata "annotations" . }}}}{{{{ end }}}}
{{{{- $_ := include "tpg.prune" (dict "obj" $obj "root" $) }}}}
---
{{{{ toYaml $obj }}}}
{{{{- end }}}}
{{{{- end }}}}
"""


def json_schema(s):
    """openAPIV3Schema -> JSON schema for kubeconform -strict (objects with properties are closed)."""
    s = copy.deepcopy(s)

    def fix(n):
        if isinstance(n, list):
            for x in n:
                fix(x)
            return
        if not isinstance(n, dict):
            return
        if n.pop("x-kubernetes-int-or-string", False):
            n.pop("anyOf", None)
            n.pop("pattern", None)
            n["oneOf"] = [{"type": "string"}, {"type": "integer"}]
        if n.pop("nullable", False) and "type" in n:
            n["type"] = [n["type"], "null"]
        if n.get("type") == "object" and "properties" in n and "additionalProperties" not in n \
                and not n.get("x-kubernetes-preserve-unknown-fields"):
            n["additionalProperties"] = False
        # the API server fills a schema default before it validates, so a
        # required field with a default may be left out of a manifest
        if isinstance(n.get("required"), list) and isinstance(n.get("properties"), dict):
            req = [r for r in n["required"] if "default" not in n["properties"].get(r, {})]
            if req:
                n["required"] = req
            else:
                n.pop("required")
        for k in list(n):
            if k.startswith("x-kubernetes-"):
                n.pop(k)
        for v in n.values():
            fix(v)

    fix(s)
    return s


def outputs(crds, overlay):
    reg = build_registry(crds, overlay)
    out = {}
    text = registry_text(reg)
    out[os.path.join(INST, "files", "zero-defaults.yaml")] = text
    out[os.path.join(REF, "files", "zero-defaults.yaml")] = text
    with open(os.path.join(INST, "templates", "_prune.tpl")) as f:
        prune = f.read()
    out[os.path.join(REF, "templates", "_prune.tpl")] = (
        "{{- /* GENERATED copy of charts/tpg-instance/templates/_prune.tpl (tools/crd-defaults/generate.py). Do not edit. */ -}}\n"
        + prune)
    for kind, key in KINDS:
        fname, crd = crds[kind]
        out[os.path.join(REF, "templates", key + ".yaml")] = reference_template(kind, key, fname, crd, reg[kind])
        ver = version_schema(crd)
        js = json_schema(ver["schema"]["openAPIV3Schema"])
        out[os.path.join(REF, "schemas", crd["spec"]["group"], f"{kind.lower()}_{ver['name']}.json")] = \
            json.dumps(js, indent=1, sort_keys=True) + "\n"
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    with open(os.path.join(REF, "defaults-overlay.yaml")) as f:
        overlay = yaml.safe_load(f) or {}
    files = outputs(load_crds(), overlay)
    stale = []
    for path, text in files.items():
        cur = None
        if os.path.exists(path):
            with open(path) as f:
                cur = f.read()
        if cur == text:
            continue
        if a.check:
            stale.append(os.path.relpath(path, ROOT))
            continue
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)
    if stale:
        print("out of date (run tools/crd-defaults/generate.py): " + ", ".join(stale), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
