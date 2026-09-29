#!/usr/bin/env bash
# Submit tpg-create-instance interactively: mandatory inputs first, then a menu of the
# optional ones, each with its type and an example. See submit-lib.sh.
#   HUB_CONTEXT=<hub kubectl context> scripts/submit/tpg-create-instance.sh
# Patch files (postgresPatchFilePath, valuesPatchFilePath) are files of this
# machine, relative to the current directory; their contents are sent in
# patchFiles (Round 14).
WF_TEMPLATE=tpg-create-instance
WF_TITLE="add Postgres instances to clusters that run the operator"
TARGETS="map-or-lists"
TARGET_LISTS="clusters instances"
MANDATORY="pushMode"
MANDATORY_WITHOUT_MAP="highAvailability postgresVersion"
# shellcheck source=scripts/submit/submit-lib.sh
source "$(dirname "$0")/submit-lib.sh"
sl_hook_mandatory() { SL_ASKED="${SL_ASKED} patchFiles"; }
sl_hook_check() { sl_pack_patch_files; }
sl_main "$@"
