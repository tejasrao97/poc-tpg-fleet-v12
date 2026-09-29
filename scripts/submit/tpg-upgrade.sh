#!/usr/bin/env bash
# Submit tpg-upgrade interactively: mandatory inputs first, then a menu of the
# optional ones, each with its type and an example. See submit-lib.sh.
#   HUB_CONTEXT=<hub kubectl context> scripts/submit/tpg-upgrade.sh
WF_TEMPLATE=tpg-upgrade
WF_TITLE="upgrade the operator or Postgres"
TARGETS="map-or-lists"
TARGET_LISTS="clusters"
MANDATORY="pushMode"
MANDATORY_WITHOUT_MAP="component targetVersion"
# shellcheck source=scripts/submit/submit-lib.sh
source "$(dirname "$0")/submit-lib.sh"
# component=postgres without clusterMap also needs the instances (or all)
sl_hook_mandatory() {
  if [[ "${SL_MAP:-0}" -eq 0 && "$(sl_val component)" == "postgres" ]]; then
    sl_prompt instances mandatory; SL_ASKED="${SL_ASKED} instances"
  fi
}
sl_main "$@"
