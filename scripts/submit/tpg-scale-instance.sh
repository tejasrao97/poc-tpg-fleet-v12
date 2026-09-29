#!/usr/bin/env bash
# Submit tpg-scale-instance interactively: mandatory inputs first, then a menu of the
# optional ones, each with its type and an example. See submit-lib.sh.
#   HUB_CONTEXT=<hub kubectl context> scripts/submit/tpg-scale-instance.sh
# Without clusterMap a run scales instances (instances and replicas), changes only
# the cap of the clusters (maxReadReplicas), or both (Round 14).
# clusterMap example (the guided builder asks for the same keys):
#   {aks-tpg-poc-01: {maxReadReplicas: 4, instances: {orders-db: {replicas: 3}, billing-db: {replicas: 0}}},
#    aks-tpg-poc-02: {instances: {reporting-db: {replicas: 1, enableHAIfNeeded: false}}},
#    aks-tpg-poc-03: {maxReadReplicas: 2}}
WF_TEMPLATE=tpg-scale-instance
WF_TITLE="scale the read replicas of Postgres instances"
TARGETS="map-or-lists"
TARGET_LISTS="clusters"
MANDATORY="pushMode"
MANDATORY_WITHOUT_MAP=""
# shellcheck source=scripts/submit/submit-lib.sh
source "$(dirname "$0")/submit-lib.sh"
sl_hook_mandatory() {
  [[ "${SL_MAP:-0}" -eq 1 ]] && return 0
  sl_menu "What does this run change on ${WF_TEMPLATE}?" \
    "Scale instances (instances and replicas)" \
    "Only the cap of the clusters (maxReadReplicas)" \
    "Both"
  case "$SL_PICK" in
    0) sl_prompt instances mandatory; sl_prompt replicas mandatory; SL_ASKED="${SL_ASKED} instances replicas" ;;
    1) sl_prompt maxReadReplicas mandatory; SL_ASKED="${SL_ASKED} instances replicas maxReadReplicas" ;;
    2) sl_prompt instances mandatory; sl_prompt replicas mandatory; sl_prompt maxReadReplicas mandatory
       SL_ASKED="${SL_ASKED} instances replicas maxReadReplicas" ;;
  esac
}
# Without clusterMap: instances need replicas, and a run needs instances or maxReadReplicas
sl_hook_check() {
  [[ "${SL_MAP:-0}" -eq 1 ]] && return 0
  if sl_isset instances && ! sl_isset replicas; then sl_err "instances need replicas"; return 1; fi
  if sl_isset replicas && ! sl_isset instances; then sl_err "replicas needs instances"; return 1; fi
  if ! sl_isset instances && ! sl_isset maxReadReplicas; then
    sl_err "set instances and replicas, or maxReadReplicas, or both"; return 1
  fi
  return 0
}
sl_main "$@"
