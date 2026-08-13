#!/usr/bin/env bash
#
# verify-chaos-resilience.sh
#
# Runs a continuous availability check against the haproxy-chaos-demo
# Service while a Litmus pod-delete ChaosEngine executes against it,
# then asserts the Service stayed up throughout. This is the actual
# "unit test" proving resilience -- not just watching pods recover.
#
# Usage:
#   ./verify-chaos-resilience.sh <route-url> <chaosengine-name> <namespace>
#
# Example:
#   ./verify-chaos-resilience.sh \
#     <route-url> \
#     haproxy-pod-delete chaos-demo

set -euo pipefail

ROUTE_URL="${1:?Usage: $0 <route-url> <chaosengine-name> <namespace>}"
ENGINE_NAME="${2:?Missing chaosengine name}"
NAMESPACE="${3:?Missing namespace}"

FAIL_THRESHOLD_PCT=100   # require zero failed requests to pass
POLL_INTERVAL=1          # seconds between requests
MAX_WAIT_SECONDS=180      # give up watching the experiment after this long

total_requests=0
failed_requests=0
results_log=$(mktemp)

echo "=== Chaos resilience verification ==="
echo "Target:      $ROUTE_URL"
echo "ChaosEngine: $ENGINE_NAME (namespace: $NAMESPACE)"
echo "Started:     $(date -Iseconds)"
echo

cleanup() {
  rm -f "$results_log"
}
trap cleanup EXIT

check_once() {
  local ts code
  ts=$(date +%s)
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "$ROUTE_URL" || echo "000")
  echo "${ts},${code}" >> "$results_log"
  total_requests=$((total_requests + 1))
  if [[ "$code" != "200" ]]; then
    failed_requests=$((failed_requests + 1))
    echo "  [$(date +%T)] FAIL — HTTP ${code}"
  fi
}

engine_phase() {
  oc get chaosresult -n "$NAMESPACE" \
    -l "chaosUID=$(oc get chaosengine "$ENGINE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.engineStatus}' 2>/dev/null)" \
    -o jsonpath='{.items[0].status.experimentStatus.phase}' 2>/dev/null || echo "Unknown"
}

echo "Polling every ${POLL_INTERVAL}s. Waiting for ChaosResult to report Completed..."
echo

waited=0
while true; do
  check_once

  phase=$(oc get chaosresult -n "$NAMESPACE" -o jsonpath='{.items[0].status.experimentStatus.phase}' 2>/dev/null || echo "")

  if [[ "$phase" == "Completed" ]]; then
    echo
    echo "ChaosResult reports phase=Completed — running 10 more checks post-recovery, then stopping."
    for _ in $(seq 1 10); do
      sleep "$POLL_INTERVAL"
      check_once
    done
    break
  fi

  waited=$((waited + POLL_INTERVAL))
  if (( waited >= MAX_WAIT_SECONDS )); then
    echo
    echo "WARNING: exceeded ${MAX_WAIT_SECONDS}s without seeing Completed phase — stopping poll loop."
    break
  fi

  sleep "$POLL_INTERVAL"
done

echo
echo "=== Results ==="
echo "Total requests:  $total_requests"
echo "Failed requests: $failed_requests"

success_pct="100"
if (( total_requests > 0 )); then
  success_pct=$(awk -v t="$total_requests" -v f="$failed_requests" 'BEGIN { printf "%.2f", ((t - f) / t) * 100 }')
fi
echo "Success rate:    ${success_pct}%"

verdict=$(oc get chaosresult -n "$NAMESPACE" -o jsonpath='{.items[0].status.experimentStatus.verdict}' 2>/dev/null || echo "Unknown")
echo "Litmus verdict:  $verdict"
echo

pass=true
if (( failed_requests > 0 )); then
  pass=false
fi
if [[ "$verdict" != "Pass" ]]; then
  pass=false
fi

if [[ "$pass" == "true" ]]; then
  echo "RESULT: PASS — Service remained available throughout the chaos window, Litmus verdict Pass."
  exit 0
else
  echo "RESULT: FAIL — Service had ${failed_requests} failed request(s), or Litmus verdict was '${verdict}'."
  echo "Raw log: $results_log (not deleted due to failure)"
  trap - EXIT
  exit 1
fi
