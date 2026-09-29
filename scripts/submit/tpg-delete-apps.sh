#!/usr/bin/env bash
# Submit tpg-delete-apps interactively: mandatory inputs first, then a menu of the
# optional ones, each with its type and an example. See submit-lib.sh.
#   HUB_CONTEXT=<hub kubectl context> scripts/submit/tpg-delete-apps.sh
WF_TEMPLATE=tpg-delete-apps
WF_TITLE="delete Postgres instances and the operator from clusters"
TARGETS="map-or-lists"
TARGET_LISTS="clusters apps"
MANDATORY="confirm purgePvcs purgeNamespace pushMode"
MANDATORY_WITHOUT_MAP=""
# shellcheck source=scripts/submit/submit-lib.sh
source "$(dirname "$0")/submit-lib.sh"
sl_main "$@"
