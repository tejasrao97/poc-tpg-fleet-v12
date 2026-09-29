#!/usr/bin/env bash
# Submit tpg-network-policy interactively: mandatory inputs first, then a menu of the
# optional ones, each with its type and an example. See submit-lib.sh.
#   HUB_CONTEXT=<hub kubectl context> scripts/submit/tpg-network-policy.sh
WF_TEMPLATE=tpg-network-policy
WF_TITLE="apply, update or remove the network policy of Postgres instances"
TARGETS="map-or-lists"
TARGET_LISTS="clusters instances"
MANDATORY="mode pushMode"
MANDATORY_WITHOUT_MAP=""
# shellcheck source=scripts/submit/submit-lib.sh
source "$(dirname "$0")/submit-lib.sh"
sl_main "$@"
