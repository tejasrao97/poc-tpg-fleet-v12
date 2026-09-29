#!/usr/bin/env bash
# Submit tpg-backup interactively: mandatory inputs first, then a menu of the
# optional ones, each with its type and an example. See submit-lib.sh.
#   HUB_CONTEXT=<hub kubectl context> scripts/submit/tpg-backup.sh
WF_TEMPLATE=tpg-backup
WF_TITLE="take backups now"
TARGETS="none"
TARGET_LISTS=""
MANDATORY=""
MANDATORY_WITHOUT_MAP=""
# shellcheck source=scripts/submit/submit-lib.sh
source "$(dirname "$0")/submit-lib.sh"
sl_main "$@"
