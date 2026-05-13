#!/usr/bin/env bash
# Build the Go app, load it into kind, and apply Knative manifests.
# Run this AFTER setup.sh, ideally a few minutes BEFORE the talk.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-knative-poc}"
IMAGE="${IMAGE:-dev.local/knative-poc-hello:dev}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

log() { printf "\033[1;34m[deploy]\033[0m %s\n" "$*"; }

log "Building image $IMAGE..."
docker build -t "$IMAGE" "$ROOT/app"

log "Loading image into kind cluster '$CLUSTER_NAME'..."
kind load docker-image "$IMAGE" --name "$CLUSTER_NAME"

log "Applying Knative Service..."
kubectl apply -f "$ROOT/manifests/service.yaml"

log "Applying Broker + Trigger + PingSource..."
kubectl apply -f "$ROOT/manifests/broker.yaml"
kubectl wait --for=condition=Ready --timeout=120s broker/default
kubectl apply -f "$ROOT/manifests/trigger.yaml"
kubectl apply -f "$ROOT/manifests/pingsource.yaml"

log "Waiting for the Knative Service to be Ready..."
kubectl wait --for=condition=Ready --timeout=180s ksvc/hello

URL=$(kubectl get ksvc hello -o jsonpath='{.status.url}')
log "Service URL: $URL"
log "Try it: curl $URL"
