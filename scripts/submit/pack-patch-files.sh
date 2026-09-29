#!/usr/bin/env bash
# pack-patch-files.sh [-o PARAMETER_FILE] FILE...
# The patchFiles input of tpg-patch and tpg-create-instance (Round 14):
# {"<path as given>": "<base64 of the file>"}. The workflow runs on the hub and
# cannot read files of this machine, so the contents travel in the Workflow; pass
# each path exactly as in the path inputs (postgresPatchFilePath,
# valuesPatchFilePath, operatorValuesPatchFilePath, or the clusterMap keys of the
# same names), relative to the current directory.
#   Without -o the JSON is printed, for -p on the command line:
#     argo submit -n argo --from workflowtemplate/tpg-patch -p clusters=aks-tpg-poc-01 \
#       -p instances=orders-db -p valuesPatchFilePath=./orders-backup.yaml \
#       -p patchFiles="$(~/src/tpg-fleet/scripts/submit/pack-patch-files.sh ./orders-backup.yaml)" \
#       -p pushMode=pr --watch
#   Linux limits one command-line argument to 128 KiB, which base64 reaches with
#   about 90 KiB of files. With -o the line patchFiles: '...' is written to (or
#   replaced in) a parameter file instead, which has no such limit:
#     ~/src/tpg-fleet/scripts/submit/pack-patch-files.sh -o patch.yaml ./orders-backup.yaml
#     argo submit -n argo --from workflowtemplate/tpg-patch --parameter-file patch.yaml ...
# The interactive scripts (scripts/submit/tpg-patch.sh, tpg-create-instance.sh) fill it for you.
set -euo pipefail
MAX=262144
out_file=""
if [[ "${1:-}" == "-o" ]]; then out_file="${2:-}"; shift 2 || true; [[ -n "$out_file" ]] || { echo "-o needs a file name" >&2; exit 2; }; fi
[[ $# -gt 0 ]] || { echo "usage: $0 [-o PARAMETER_FILE] FILE..." >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
for f in "$@"; do
  [[ -f "$f" ]] || { echo "${f}: no such file" >&2; exit 1; }
  [[ "$f" != /* && "/$f/" != */../* ]] || { echo "${f}: give a relative path below the current directory (no leading /, no ..)" >&2; exit 1; }
  case "$f" in *.yaml|*.yml) ;; *) echo "${f}: a patch file ends in .yaml or .yml" >&2; exit 1 ;; esac
  size="$(wc -c < "$f" | tr -d ' ')"
  (( size <= MAX )) || { echo "${f}: ${size} bytes; a patch file may have at most ${MAX}" >&2; exit 1; }
done
# the contents go through pipes, never through a command-line argument
# shellcheck disable=SC2094  # "$f" is only read ("--arg p" is its name)
json="$(for f in "$@"; do base64 < "$f" | tr -d '\n' | jq -Rc --arg p "$f" '{($p): .}'; done | jq -sc 'add')"
if [[ -z "$out_file" ]]; then
  printf '%s\n' "$json"
  exit 0
fi
tmp="${out_file}.tmp.$$"
{ [[ ! -f "$out_file" ]] || grep -v '^patchFiles:' "$out_file" || true
  printf "patchFiles: '%s'\n" "$json"; } > "$tmp"
mv "$tmp" "$out_file"
echo "patchFiles written to ${out_file} ($(printf '%s' "$json" | wc -c | tr -d ' ') bytes); submit with --parameter-file ${out_file}" >&2
