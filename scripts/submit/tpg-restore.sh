#!/usr/bin/env bash
# Submit tpg-restore interactively: mandatory inputs first, then a menu of the
# optional ones, each with its type and an example. See submit-lib.sh.
#   HUB_CONTEXT=<hub kubectl context> scripts/submit/tpg-restore.sh
WF_TEMPLATE=tpg-restore
WF_TITLE="restore a Postgres instance"
TARGETS="none"
TARGET_LISTS=""
MANDATORY="sourceCluster instance mode"
MANDATORY_WITHOUT_MAP=""
# shellcheck source=scripts/submit/submit-lib.sh
source "$(dirname "$0")/submit-lib.sh"
# The recovery point depends on the mode
sl_hook_mandatory() {
  case "$(sl_val mode)" in
    time) sl_prompt targetTime mandatory; SL_ASKED="${SL_ASKED} targetTime" ;;
    backup) sl_prompt backupName mandatory; sl_prompt targetInstance mandatory; sl_prompt confirm mandatory
            SL_ASKED="${SL_ASKED} backupName targetInstance confirm" ;;
    lsn) sl_prompt lsn mandatory; SL_ASKED="${SL_ASKED} lsn" ;;
    xid) sl_prompt xid mandatory; SL_ASKED="${SL_ASKED} xid" ;;
  esac
}
sl_main "$@"
