#!/usr/bin/env bash
# Submit tpg-helm-addons interactively: mandatory inputs first, then a menu of the
# optional ones, each with its type and an example. See submit-lib.sh.
#   HUB_CONTEXT=<hub kubectl context> scripts/submit/tpg-helm-addons.sh
WF_TEMPLATE=tpg-helm-addons
WF_TITLE="install or upgrade the Helm add-ons on clusters"
TARGETS="lists"
TARGET_LISTS="clusters"
MANDATORY=""
MANDATORY_WITHOUT_MAP=""
# shellcheck source=scripts/submit/submit-lib.sh
source "$(dirname "$0")/submit-lib.sh"
sl_main "$@"
