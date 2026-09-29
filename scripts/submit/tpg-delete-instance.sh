#!/usr/bin/env bash
# Submit tpg-delete-instance interactively: mandatory inputs first, then a menu of the
# optional ones, each with its type and an example. See submit-lib.sh.
#   HUB_CONTEXT=<hub kubectl context> scripts/submit/tpg-delete-instance.sh
WF_TEMPLATE=tpg-delete-instance
WF_TITLE="delete Postgres instances"
TARGETS="map-or-lists"
TARGET_LISTS="clusters instances"
MANDATORY="confirm"
MANDATORY_WITHOUT_MAP=""
# shellcheck source=scripts/submit/submit-lib.sh
source "$(dirname "$0")/submit-lib.sh"
sl_main "$@"
