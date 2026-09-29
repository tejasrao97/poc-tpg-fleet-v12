#!/usr/bin/env python3
"""Check that a patch file fits the input it was passed to (Round 14, D77).

  patchcheck.py KIND FILE.json --schemas patch-schemas.json [--name NAME]

KIND is values (valuesPatchFilePath), postgres (postgresPatchFilePath) or
operator (operatorValuesPatchFilePath). FILE.json is the patch file as JSON (the
caller converts the YAML with yq). NAME is how the file is named in the
messages (the path the user gave). Prints one error per line and exits 1 when
there is any. Standard library only (it runs in the validate step, in the
tools image).

  values    a map of chart values: a Kubernetes manifest or an operator values
            file is refused with the input it belongs to; every key must exist
            in the chart values (workflows/params/patch-schemas.json, values.tree),
            with the closest known key suggested; a map where the chart has a
            single value (or the reverse) is refused
  postgres  apiVersion sql.tanzu.vmware.com/v1, kind Postgres, only apiVersion,
            kind and spec; spec against the closed schema of the Postgres CRD
            (unknown fields, types, enums, patterns, lengths, minimums); required
            fields are not asked for, because a patch sets only what it changes
  operator  only the keys the operator values allow-list names, each with its type
The rules that need clusters/fleet.yaml or the cluster (fields other workflows
own, sizes that would shrink, the operator image tag against the cluster's
operator version, Secrets and issuers that must exist) are checked later by
workflows/scripts/patch-lib.sh.
"""
import argparse
import difflib
import json
import re
import sys

MANIFEST_KEYS = {"apiVersion", "kind", "metadata", "spec"}
DNS_LABEL = re.compile(r"^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$")
K8S_NAME = re.compile(r"^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$")
QUANTITY = re.compile(r"^[0-9]+(\.[0-9]+)?(m|Ki|Mi|Gi|Ti|Pi|Ei|k|M|G|T|P|E)?$")
# <registry host[:port]>/<path>, no tag or digest on the last segment
REPOSITORY = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9.-]*(:[0-9]+)?(/[a-z0-9]+([._-][a-z0-9]+)*)+$")
IMAGE = re.compile(r"^(?P<repo>[a-zA-Z0-9][a-zA-Z0-9.-]*(:[0-9]+)?(/[a-z0-9]+([._-][a-z0-9]+)*)+):(?P<tag>[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})$")


def suggest(word, choices):
    m = difflib.get_close_matches(word, list(choices), n=1, cutoff=0.6)
    return f" (did you mean {m[0]}?)" if m else ""


def kind_of(v):
    if isinstance(v, dict):
        return "a map"
    if isinstance(v, list):
        return "a list"
    return "a single value"


def check_values(doc, schema, name, errors):
    if not isinstance(doc, dict):
        errors.append(f"{name}: a values patch must be a YAML map of chart values (got {kind_of(doc)})")
        return
    found = sorted(MANIFEST_KEYS & set(doc))
    if found:
        what = f"a Kubernetes manifest (kind: {doc.get('kind')})" if doc.get("kind") else "a Kubernetes manifest"
        hint = "postgresPatchFilePath" if doc.get("kind") in (None, "Postgres") else "a patch input of its own kind"
        errors.append(f"{name}: is {what}, not chart values ({', '.join(found)} at the top): "
                      f"pass it as {hint}")
        return
    op = sorted(set(schema["operator"]) & set(doc))
    if op:
        errors.append(f"{name}: holds operator chart values ({', '.join(op)}): pass it as operatorValuesPatchFilePath")
        return
    owned = set(schema["values"]["owned"])

    def walk(node, t, path):
        for k, v in node.items():
            p = f"{path}.{k}" if path else k
            if not path and k in owned:
                continue
            if not isinstance(t, dict) or k not in t:
                known = t.keys() if isinstance(t, dict) else []
                errors.append(f"{name}: {p} is not a value of the tpg-instance chart{suggest(k, known)}")
                continue
            sub = t[k]
            if sub == "*":
                if not isinstance(v, dict) and v is not None:
                    errors.append(f"{name}: {p} must be a map (got {kind_of(v)})")
                continue
            if isinstance(sub, dict):
                if v is None:
                    continue  # null removes the key (tpg.deepMerge)
                if not isinstance(v, dict):
                    errors.append(f"{name}: {p} must be a map (got {kind_of(v)})")
                    continue
                walk(v, sub, p)
            elif sub == "list":
                if v is not None and not isinstance(v, list):
                    errors.append(f"{name}: {p} must be a list (got {kind_of(v)})")
            elif isinstance(v, (dict, list)):
                errors.append(f"{name}: {p} is a single value in the chart (got {kind_of(v)})")
    walk(doc, schema["values"]["tree"], "")


def type_ok(v, t):
    return {"object": isinstance(v, dict), "array": isinstance(v, list),
            "string": isinstance(v, str),
            "integer": isinstance(v, int) and not isinstance(v, bool),
            "number": isinstance(v, (int, float)) and not isinstance(v, bool),
            "boolean": isinstance(v, bool), "null": v is None}.get(t, True)


def check_schema(v, s, path, name, errors):
    """The subset of JSON schema the generated CRD schemas use; required is not checked."""
    if "oneOf" in s:
        ok = [alt for alt in s["oneOf"] if not _errs(v, alt, path)]
        if not ok:
            errors.append(f"{name}: {path} has {kind_of(v)} '{v}' of the wrong type"
                          f" ({' or '.join(a.get('type', '?') for a in s['oneOf'])} expected)")
        return
    t = s.get("type")
    if isinstance(t, list):
        if not any(type_ok(v, x) for x in t):
            errors.append(f"{name}: {path} must be {' or '.join(t)} (got {kind_of(v)})")
            return
    elif t and not type_ok(v, t):
        errors.append(f"{name}: {path} must be {'an ' if t[0] in 'aeiou' else 'a '}{t} (got {json.dumps(v)[:60]})")
        return
    if "enum" in s and v not in s["enum"]:
        errors.append(f"{name}: {path} '{v}' must be one of {', '.join(map(str, s['enum']))}")
    if isinstance(v, str):
        if "pattern" in s and not re.search(s["pattern"], v):
            errors.append(f"{name}: {path} '{v}' does not match {s['pattern']}")
        if "maxLength" in s and len(v) > s["maxLength"]:
            errors.append(f"{name}: {path} is longer than {s['maxLength']} characters")
    if isinstance(v, (int, float)) and not isinstance(v, bool) and "minimum" in s and v < s["minimum"]:
        errors.append(f"{name}: {path} {v} is below the minimum {s['minimum']}")
    if isinstance(v, dict):
        props = s.get("properties", {})
        extra = s.get("additionalProperties", True)
        for k, sub in v.items():
            p = f"{path}.{k}"
            if k in props:
                check_schema(sub, props[k], p, name, errors)
            elif extra is False:
                errors.append(f"{name}: {p} is not a field of the Postgres resource{suggest(k, props)}")
            elif isinstance(extra, dict):
                check_schema(sub, extra, p, name, errors)
    if isinstance(v, list) and isinstance(s.get("items"), dict):
        for n, item in enumerate(v):
            check_schema(item, s["items"], f"{path}[{n}]", name, errors)


def _errs(v, s, path):
    e = []
    check_schema(v, s, path, "", e)
    return e


def check_postgres(doc, schema, name, errors):
    if not isinstance(doc, dict):
        errors.append(f"{name}: a Postgres patch must be a YAML map (got {kind_of(doc)})")
        return
    pg = schema["postgres"]
    if "kind" not in doc and "spec" not in doc:
        vals = sorted(set(doc) & set(schema["values"]["tree"]))
        if vals:
            errors.append(f"{name}: holds chart values ({', '.join(vals)}), not a Postgres manifest: "
                          f"pass it as valuesPatchFilePath")
            return
        if set(schema["operator"]) & set(doc):
            errors.append(f"{name}: holds operator chart values: pass it as operatorValuesPatchFilePath")
            return
    if doc.get("kind") != pg["kind"]:
        errors.append(f"{name}: kind must be {pg['kind']} (got {doc.get('kind', 'none')})")
    if doc.get("apiVersion") != pg["apiVersion"]:
        errors.append(f"{name}: apiVersion must be {pg['apiVersion']} (got {doc.get('apiVersion', 'none')})")
    extra = sorted(set(doc) - {"apiVersion", "kind", "spec"})
    if extra:
        errors.append(f"{name}: only apiVersion, kind and spec can be patched (found {', '.join(extra)})")
    spec = doc.get("spec")
    if spec is None:
        errors.append(f"{name}: spec is missing: nothing to patch")
    else:
        check_schema(spec, pg["spec"], "spec", name, errors)


def check_operator(doc, schema, name, errors):
    if not isinstance(doc, dict):
        errors.append(f"{name}: an operator values patch must be a YAML map (got {kind_of(doc)})")
        return
    allowed = schema["operator"]
    if MANIFEST_KEYS & set(doc):
        errors.append(f"{name}: is a Kubernetes manifest; operator manifest patches were removed in Round 14: "
                      f"set one of {', '.join(sorted(allowed))} in an operator values file")
        return
    vals = sorted(set(doc) & set(schema["values"]["tree"]))
    if vals:
        errors.append(f"{name}: holds tpg-instance chart values ({', '.join(vals)}): pass it as valuesPatchFilePath")
        return
    for k, v in doc.items():
        if k not in allowed:
            errors.append(f"{name}: {k} cannot be patched; an operator values patch may set only "
                          f"{', '.join(sorted(allowed))}{suggest(k, allowed)}")
            continue
        t = allowed[k]["type"]
        empty_ok = allowed[k].get("allowEmpty", False)
        if t == "boolean":
            if not isinstance(v, bool):
                errors.append(f"{name}: {k} must be true or false (got {json.dumps(v)})")
        elif t == "resources":
            if v is None or v == {}:
                continue
            if not isinstance(v, dict):
                errors.append(f"{name}: resources must be a map of limits and requests (got {kind_of(v)})")
                continue
            for part, res in v.items():
                if part not in ("limits", "requests"):
                    errors.append(f"{name}: resources.{part} cannot be set (only limits and requests){suggest(part, ['limits', 'requests'])}")
                    continue
                if not isinstance(res, dict):
                    errors.append(f"{name}: resources.{part} must be a map of cpu and memory")
                    continue
                for r, q in res.items():
                    if r not in ("cpu", "memory"):
                        errors.append(f"{name}: resources.{part}.{r} cannot be set (only cpu and memory){suggest(r, ['cpu', 'memory'])}")
                    elif not QUANTITY.match(str(q)):
                        errors.append(f"{name}: resources.{part}.{r} '{q}' is not a Kubernetes quantity such as 500m or 300Mi")
        elif not isinstance(v, str):
            errors.append(f"{name}: {k} must be a string (got {kind_of(v)})")
        elif v == "":
            if not empty_ok:
                errors.append(f"{name}: {k} cannot be empty")
        elif t == "image":
            if not IMAGE.match(v):
                errors.append(f"{name}: operatorImage '{v}' must be <registry>/<path>:<tag> (a tag, not a digest)")
        elif t == "repository":
            if not REPOSITORY.match(v):
                errors.append(f"{name}: {k} '{v}' must be an image repository without a tag, such as "
                              f"myregistry.azurecr.io/postgres-instance")
        elif t == "k8sName":
            if not K8S_NAME.match(v):
                errors.append(f"{name}: {k} '{v}' is not a Kubernetes object name")
        elif t == "dnsLabel":
            if not DNS_LABEL.match(v):
                errors.append(f"{name}: {k} '{v}' is not a namespace name (a DNS label)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("kind", choices=["values", "postgres", "operator"])
    ap.add_argument("file")
    ap.add_argument("--schemas", required=True)
    ap.add_argument("--name")
    a = ap.parse_args()
    with open(a.schemas) as f:
        schema = json.load(f)
    name = a.name or a.file
    try:
        with open(a.file) as f:
            doc = json.load(f)
    except ValueError as e:
        print(f"{name}: not valid YAML: {e}")
        return 1
    errors = []
    {"values": check_values, "postgres": check_postgres, "operator": check_operator}[a.kind](doc, schema, name, errors)
    for e in errors:
        print(e)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
