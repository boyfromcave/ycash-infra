#!/usr/bin/env bash
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
#
# Fails unless the release came up: `kubectl rollout status` (ROLLOUT_TIMEOUT each, default 10m) for
# every Deployment and StatefulSet of the release, then no pod in the namespace waiting in
# CrashLoopBackOff, Error or an image-pull failure, and none Failed. On a failure it prints the
# offending pods with their last log lines (current and previous container). `helm --wait` alone let
# `make kind-up` print "up." over a crash-looping web pod.
# Usage: scripts/kind-check-release.sh CLUSTER NAMESPACE RELEASE   (kind-up.sh and kind-reset-chain.sh call it)
set -euo pipefail
CLUSTER=${1:-ycash}; NS=${2:-ycash}; RELEASE=${3:-ycash}; CTX="kind-$CLUSTER"
TIMEOUT=${ROLLOUT_TIMEOUT:-10m}
TAIL=${LOG_TAIL:-30}
k() { kubectl --context "$CTX" -n "$NS" "$@"; }

# pod name and one word per container (init and app): its waiting or terminated reason, else "ok"
pod_states() {
  k get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{range .status.initContainerStatuses[*]}{" "}{.name}={.state.waiting.reason}{.state.terminated.reason}{end}{range .status.containerStatuses[*]}{" "}{.name}={.state.waiting.reason}{.state.terminated.reason}{end}{"\n"}{end}'
}
BAD='=(CrashLoopBackOff|Error|ImagePullBackOff|ErrImagePull|CreateContainerConfigError|CreateContainerError|InvalidImageName|OOMKilled)( |$)| Failed( |$)'

report() {  # the pods in a bad state, with their logs
  local line pod
  pod_states | grep -E "$BAD" | while read -r line; do
    pod=${line%% *}
    echo "-- $line" >&2
    k logs "$pod" --all-containers --tail="$TAIL" 2>&1 | sed 's/^/   /' >&2 || true
    echo "   (previous container)" >&2
    k logs "$pod" --all-containers --previous --tail="$TAIL" 2>&1 | sed 's/^/   /' >&2 || true
  done
}

fail=0
for w in $(k get deployment,statefulset -l app.kubernetes.io/instance="$RELEASE" -o name); do
  if ! k rollout status "$w" --timeout="$TIMEOUT"; then
    echo "check-release: $w did not come up within $TIMEOUT (ROLLOUT_TIMEOUT=)" >&2; fail=1
  fi
done
if pod_states | grep -qE "$BAD"; then
  echo "check-release: pods in namespace $NS are failing:" >&2; fail=1
fi
if [ "$fail" = 1 ]; then
  report
  echo "check-release: the release $RELEASE did not come up (kubectl --context $CTX -n $NS get pods)" >&2
  exit 1
fi
echo "check-release: every Deployment and StatefulSet of $RELEASE is rolled out, no pod is failing"
