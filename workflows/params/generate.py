#!/usr/bin/env python3
"""Generate the Workflow parameter type policy from workflows/params/types.yaml.

  python3 workflows/params/generate.py            write workflows/admission/workflow-parameters.yaml
                                                  and workflows/params/patch-schemas.json (patch_schemas.py)
  python3 workflows/params/generate.py --check    exit 1 when the committed file is out of date

The policy is a ValidatingAdmissionPolicy on Workflow CREATE in the argo
namespace, for Workflows that reference a tpg-* WorkflowTemplate. It has one
validation per template: every input passed must be declared for that template
and match its type. Inputs that are not passed take the template default, which
tests/params checks against the same types.

CEL notes:
  - Workflow arguments are read as strings (string() of the value), because the
    Argo CRDs keep spec schemaless and a value may arrive as a YAML number or
    boolean when a manifest is applied directly.
  - A parameter with valueFrom (ConfigMap reference) is left to Argo.
  - rules: combinations refused together (highAvailability=true with
    readReplicas=0, for example); only inputs that are passed are compared.
  - Regular expressions are CEL raw strings, so no backslash escaping is needed.
"""
import argparse
import os
import sys

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SRC = os.path.join(HERE, "types.yaml")
OUT = os.path.join(ROOT, "workflows", "admission", "workflow-parameters.yaml")

VALUE = "(has(p.value) ? string(p.value) : '')"


def cel_str(s):
    if "'" in s:
        raise SystemExit(f"a single quote cannot be embedded in a CEL string: {s}")
    return "'" + s + "'"


def cel_raw(s):
    if "'" in s:
        raise SystemExit(f"a single quote cannot be embedded in a CEL raw string: {s}")
    return "r'" + s + "'"


def type_check(spec, types):
    """CEL boolean over VALUE for one parameter."""
    t = spec["type"]
    if t == "enum":
        cond = VALUE + " in [" + ", ".join(cel_str(str(v)) for v in spec["values"]) + "]"
    elif t == "string":
        cond = "true"
    else:
        cond = VALUE + ".matches(" + cel_raw(types[t]["pattern"]) + ")"
        if types[t].get("excludeAll"):
            # "all" is a valid name for the pattern, but not a value of this type
            cond = "(" + cond + " && !" + VALUE + ".split(',').exists(x, x.trim() == 'all'))"
    if spec.get("allowEmpty") and cond != "true":
        cond = "(" + VALUE + " == '' || " + cond + ")"
    return cond


def describe(spec, types):
    t = spec["type"]
    if t == "enum":
        vals = [str(v) for v in spec["values"]]
        d = "one of " + ", ".join(vals)
    else:
        d = types[t]["describe"]
    if spec.get("allowEmpty") and t != "string":
        d += " (or empty)"
    return d


def template_validation(name, params, types):
    # p.name == 'a' ? <check a> : (p.name == 'b' ? <check b> : false)
    chain = "false"
    for pname in reversed(list(params)):
        chain = f"p.name == {cel_str(pname)} ? {type_check(params[pname], types)} : ({chain})"
    ok = f"has(p.valueFrom) || ({chain})"
    descs = "{" + ", ".join(f"{cel_str(p)}: {cel_str(describe(s, types))}" for p, s in params.items()) + "}"
    return {
        "expression": f"variables.template != {cel_str(name)} || variables.params.all(p, {ok})",
        "messageExpression": (
            f"'{name}: ' + variables.params.filter(p, !({ok})).map(p, "
            f"p.name in {descs} ? p.name + '=\"' + {VALUE} + '\" must be ' + {descs}[p.name] "
            f": p.name + ' is not an input of {name}').join('; ') + '. See docs/workflow-commands.md'"
        ),
        "reason": "Invalid",
    }


def rule_validation(name, rule, params):
    """One combination rule of a template: refused when every named input is passed and matches."""
    conds = []
    for pname, rx in rule["when"].items():
        if pname not in params:
            raise SystemExit(f"rules.{name}: {pname} is not an input of {name}")
        conds.append(f"variables.params.exists(p, p.name == {cel_str(pname)} && {VALUE}.matches({cel_raw('^(' + str(rx) + ')$')}))")
    return {
        "expression": f"variables.template != {cel_str(name)} || !(" + " && ".join(conds) + ")",
        "message": f"{name}: {rule['message']}. See docs/workflow-commands.md",
        "reason": "Invalid",
    }


def build():
    with open(SRC) as f:
        src = yaml.safe_load(f)
    types, templates = src["types"], src["templates"]
    rules = src.get("rules") or {}
    for tname, params in templates.items():
        for pname, spec in params.items():
            if spec["type"] not in types:
                raise SystemExit(f"{tname}.{pname}: unknown type {spec['type']}")
            if spec["type"] == "enum" and not spec.get("values"):
                raise SystemExit(f"{tname}.{pname}: enum without values")
    policy = {
        "apiVersion": "admissionregistration.k8s.io/v1",
        "kind": "ValidatingAdmissionPolicy",
        "metadata": {"name": "tpg-workflow-parameters"},
        "spec": {
            "failurePolicy": "Fail",
            "matchConstraints": {
                "namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "argo"}},
                "resourceRules": [{
                    "apiGroups": ["argoproj.io"],
                    "apiVersions": ["*"],
                    "operations": ["CREATE"],
                    "resources": ["workflows"],
                }],
            },
            "matchConditions": [{
                "name": "tpg-workflow-template",
                "expression": "has(object.spec) && has(object.spec.workflowTemplateRef) && "
                              "has(object.spec.workflowTemplateRef.name) && "
                              "string(object.spec.workflowTemplateRef.name).startsWith('tpg-')",
            }],
            "variables": [
                {"name": "template", "expression": "string(object.spec.workflowTemplateRef.name)"},
                {"name": "params", "expression": "has(object.spec.arguments) && "
                                                 "has(object.spec.arguments.parameters) ? "
                                                 "object.spec.arguments.parameters : []"},
            ],
            "validations": [template_validation(n, p, types) for n, p in templates.items()]
                           + [rule_validation(n, r, templates[n]) for n in rules for r in rules[n]] + [{
                "expression": "variables.template in [" + ", ".join(cel_str(n) for n in templates) + "]",
                "messageExpression": "'WorkflowTemplate ' + variables.template + "
                                     "' has no parameter types in workflows/params/types.yaml'",
                "reason": "Invalid",
            }],
        },
    }
    binding = {
        "apiVersion": "admissionregistration.k8s.io/v1",
        "kind": "ValidatingAdmissionPolicyBinding",
        "metadata": {"name": "tpg-workflow-parameters"},
        "spec": {"policyName": "tpg-workflow-parameters", "validationActions": ["Deny"]},
    }
    header = (
        "# GENERATED by workflows/params/generate.py from workflows/params/types.yaml.\n"
        "# Do not edit: change types.yaml and run the generator.\n"
        "#\n"
        "# Rejects a Workflow of a tpg WorkflowTemplate whose inputs do not match their\n"
        "# declared types, before the Workflow exists (argo submit, the Argo UI, the API\n"
        "# and CronWorkflows alike). Kubernetes 1.30 or later (AKS 1.30+).\n"
    )
    body = yaml.safe_dump_all([policy, binding], sort_keys=False, width=100000, default_flow_style=False)
    return header + "---\n" + body


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import patch_schemas  # noqa: E402  (Round 14: what a patch file may contain)
    outputs = [(OUT, build()), (patch_schemas.OUT, patch_schemas.build())]
    if a.check:
        stale = []
        for path, text in outputs:
            try:
                with open(path) as f:
                    same = f.read() == text
            except FileNotFoundError:
                same = False
            if not same:
                stale.append(os.path.relpath(path, ROOT))
        if stale:
            print(f"{', '.join(stale)} out of date: run workflows/params/generate.py", file=sys.stderr)
            return 1
        return 0
    for path, text in outputs:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
