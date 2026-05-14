#!/usr/bin/env bash
# End-to-end smoke test. Assumes setup.sh + deploy.sh have run.
#
# Verifies:
#   1. Knative Service responds with a "hello from <pod>" body via the Kourier
#      port-forward + Host header.
#   2. A CloudEvent posted to the Broker is delivered to the hello service
#      (looks for the corresponding log line in the user-container).
#
# Exit 0 if both pass, non-zero on first failure.

set -euo pipefail

LOCAL_PORT="${LOCAL_PORT:-18080}"   # use a non-standard port so we don't collide with a demo port-forward
TIMEOUT_PF="${TIMEOUT_PF:-15}"
LOG_WAIT_SECONDS="${LOG_WAIT_SECONDS:-15}"

red()   { printf "\033[1;31m%s\033[0m\n" "$*"; }
green() { printf "\033[1;32m%s\033[0m\n" "$*"; }
log()   { printf "\033[1;34m[smoke]\033[0m %s\n" "$*"; }
fail()  { red   "[FAIL] $*"; exit 1; }

cleanup() {
  if [[ -n "${PF_PID:-}" ]] && kill -0 "$PF_PID" 2>/dev/null; then
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# --- preflight --------------------------------------------------------------
command -v kubectl >/dev/null || fail "kubectl not on PATH"
kubectl get ksvc hello >/dev/null 2>&1 || fail "Knative Service 'hello' not found. Run ./scripts/deploy.sh first."

URL=$(kubectl get ksvc hello -o jsonpath='{.status.url}')
HOST=${URL#http://}
log "Service URL: $URL"

# --- 1. HTTP path ----------------------------------------------------------
log "Starting Kourier port-forward on :$LOCAL_PORT ..."
kubectl port-forward -n kourier-system svc/kourier "${LOCAL_PORT}:80" >/tmp/smoke-pf.log 2>&1 &
PF_PID=$!

# Wait for the port-forward to actually accept connections.
deadline=$(( $(date +%s) + TIMEOUT_PF ))
until curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${LOCAL_PORT}/" 2>/dev/null | grep -qE '^(2|3|4|5)'; do
  [ "$(date +%s)" -ge "$deadline" ] && fail "port-forward never came up (see /tmp/smoke-pf.log)"
  sleep 1
done

log "Hitting the service..."
RESP=$(curl -s -H "Host: $HOST" "http://127.0.0.1:${LOCAL_PORT}/")
echo "  response: $RESP"
case "$RESP" in
  "hello from "*) green "[PASS] HTTP path returned expected greeting" ;;
  *)              fail "HTTP path: unexpected body $RESP" ;;
esac

# --- 2. Eventing path ------------------------------------------------------
log "Capturing baseline of CloudEvent log lines..."
BASELINE=$(kubectl logs -l serving.knative.dev/service=hello -c user-container --tail=200 2>/dev/null | grep -c "CloudEvent received" || true)
EVENT_ID="smoke-$(date +%s)-$RANDOM"
log "Posting CloudEvent (id=$EVENT_ID) to the broker..."

BROKER_URL=$(kubectl get broker default -o jsonpath='{.status.address.url}')
kubectl run "smoke-curl-$$" --rm -i --restart=Never --image=curlimages/curl --quiet --command -- \
  curl -s -X POST "$BROKER_URL" \
    -H "Ce-Id: $EVENT_ID" \
    -H "Ce-Specversion: 1.0" \
    -H "Ce-Type: dev.knative.sources.ping" \
    -H "Ce-Source: /smoke" \
    -H "Content-Type: application/json" \
    -d '{"msg":"smoke"}' >/dev/null

log "Waiting up to ${LOG_WAIT_SECONDS}s for the event to land in the service logs..."
deadline=$(( $(date +%s) + LOG_WAIT_SECONDS ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if kubectl logs -l serving.knative.dev/service=hello -c user-container --tail=200 2>/dev/null | grep -q "id=$EVENT_ID"; then
    green "[PASS] CloudEvent with id=$EVENT_ID delivered to the hello service"
    exit 0
  fi
  sleep 1
done

# Diagnostics on failure.
red "[FAIL] CloudEvent never arrived. Diagnostics:"
echo "--- baseline count of CloudEvent log lines: $BASELINE"
echo "--- current pods ---"
kubectl get pods -l serving.knative.dev/service=hello
echo "--- recent hello logs ---"
kubectl logs -l serving.knative.dev/service=hello -c user-container --tail=30 2>/dev/null || true
echo "--- broker status ---"
kubectl get broker default -o wide
echo "--- trigger status ---"
kubectl get trigger hello-on-ping -o wide
exit 1
