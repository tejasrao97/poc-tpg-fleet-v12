#!/usr/bin/env bash
# Submit tpg-patch interactively: mandatory inputs first, then a menu of the
# optional ones, each with its type and an example. See submit-lib.sh.
#   HUB_CONTEXT=<hub kubectl context> scripts/submit/tpg-patch.sh
# Run it from the directory that holds the patch files: their paths are relative
# to it, and their contents are read here and sent in patchFiles (Round 14).
WF_TEMPLATE=tpg-patch
WF_TITLE="patch operators and instances with files from this machine"
TARGETS="map-or-lists"
TARGET_LISTS="clusters"
MANDATORY="pushMode"
MANDATORY_WITHOUT_MAP=""
# shellcheck source=scripts/submit/submit-lib.sh
source "$(dirname "$0")/submit-lib.sh"
# patchFiles is filled from the files, never typed
sl_hook_mandatory() { SL_ASKED="${SL_ASKED} patchFiles"; }
# Without clusterMap at least one patch file input is needed; instance files also need instances
sl_hook_check() {
  if [[ "${SL_MAP:-0}" -eq 0 ]]; then
    local f any=0
    for f in postgresPatchFilePath valuesPatchFilePath operatorValuesPatchFilePath; do
      sl_isset "$f" && any=1
    done
    if [[ "$any" -eq 0 ]]; then sl_err "choose at least one patch file input (postgresPatchFilePath, valuesPatchFilePath or operatorValuesPatchFilePath)"; return 1; fi
    if { sl_isset postgresPatchFilePath || sl_isset valuesPatchFilePath; } && ! sl_isset instances; then
      sl_err "instance patch files need the instances input"; return 1
    fi
  fi
  sl_pack_patch_files
}
sl_main "$@"
