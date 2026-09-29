#!/usr/bin/env bash
# Submit tpg-rotate-credential interactively: mandatory inputs first, then a menu of the
# optional ones, each with its type and an example. See submit-lib.sh.
#   HUB_CONTEXT=<hub kubectl context> scripts/submit/tpg-rotate-credential.sh
WF_TEMPLATE=tpg-rotate-credential
WF_TITLE="rotate a credential held in Vault"
TARGETS="none"
TARGET_LISTS=""
MANDATORY=""
MANDATORY_WITHOUT_MAP=""
# shellcheck source=scripts/submit/submit-lib.sh
source "$(dirname "$0")/submit-lib.sh"
sl_main "$@"
