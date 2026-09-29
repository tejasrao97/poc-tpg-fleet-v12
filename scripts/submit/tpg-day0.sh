#!/usr/bin/env bash
# Submit tpg-day0 interactively: mandatory inputs first, then a menu of the
# optional ones, each with its type and an example. See submit-lib.sh.
#   HUB_CONTEXT=<hub kubectl context> scripts/submit/tpg-day0.sh
WF_TEMPLATE=tpg-day0
WF_TITLE="deploy the operator and the first instances on clusters"
TARGETS="map-or-lists"
TARGET_LISTS="clusters instances"
MANDATORY="pushMode"
MANDATORY_WITHOUT_MAP="highAvailability operatorVersion postgresVersion"
# shellcheck source=scripts/submit/submit-lib.sh
source "$(dirname "$0")/submit-lib.sh"
sl_main "$@"
