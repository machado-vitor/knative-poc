#!/usr/bin/env bash
# Create a kind cluster and install Knative Serving + Eventing.
# Run this BEFORE the presentation. ~3-5 minutes the first time.

set -euo pipefail

KNATIVE_VERSION="${KNATIVE_VERSION:-v1.16.0}"
CLUSTER_NAME="${CLUSTER_NAME:-knative-poc}"

log() { printf "\033[1;34m[setup]\033[0m %s\n" "$*"; }
die() { printf "\033[1;31m[setup]\033[0m %s\n" "$*" >&2; exit 1; }

# --- 1. Prerequisites -------------------------------------------------------
ensure_brew() {
  command -v brew >/dev/null 2>&1 || die "Homebrew not found. Install from https://brew.sh first."
}

ensure_tool() {
  local cmd="$1" pkg="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "Installing $pkg via brew..."
    brew install "$pkg"
  fi
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker Desktop via brew (cask)..."
    brew install --cask docker
    die "Docker Desktop installed. Open it once, wait for the whale icon, then re-run this script."
  fi
  if ! docker info >/dev/null 2>&1; then
    die "Docker daemon not running. Start Docker Desktop and re-run."
  fi
}

ensure_brew
ensure_docker
ensure_tool kind kind
ensure_tool kubectl kubectl

# --- 2. kind cluster --------------------------------------------------------
if kind get clusters | grep -qx "$CLUSTER_NAME"; then
  log "kind cluster '$CLUSTER_NAME' already exists, reusing."
else
  log "Creating kind cluster '$CLUSTER_NAME'..."
  kind create cluster --name "$CLUSTER_NAME" --wait 120s
fi

kubectl cluster-info --context "kind-$CLUSTER_NAME" >/dev/null

# --- 3. Knative Serving -----------------------------------------------------
log "Installing Knative Serving CRDs ($KNATIVE_VERSION)..."
kubectl apply -f "https://github.com/knative/serving/releases/download/knative-${KNATIVE_VERSION}/serving-crds.yaml"

log "Installing Knative Serving core..."
kubectl apply -f "https://github.com/knative/serving/releases/download/knative-${KNATIVE_VERSION}/serving-core.yaml"

log "Installing Kourier networking layer..."
kubectl apply -f "https://github.com/knative/net-kourier/releases/download/knative-${KNATIVE_VERSION}/kourier.yaml"

log "Wiring Knative to use Kourier..."
kubectl patch configmap/config-network \
  --namespace knative-serving \
  --type merge \
  --patch '{"data":{"ingress-class":"kourier.ingress.networking.knative.dev"}}'

log "Setting config-domain to 127.0.0.1.sslip.io (kind has no LB EXTERNAL-IP, so the auto default-domain job would hang)..."
kubectl patch configmap config-domain -n knative-serving \
  --type merge \
  --patch '{"data":{"127.0.0.1.sslip.io":""}}'

# --- 4. Knative Eventing ----------------------------------------------------
log "Installing Knative Eventing CRDs..."
kubectl apply -f "https://github.com/knative/eventing/releases/download/knative-${KNATIVE_VERSION}/eventing-crds.yaml"

log "Installing Knative Eventing core..."
kubectl apply -f "https://github.com/knative/eventing/releases/download/knative-${KNATIVE_VERSION}/eventing-core.yaml"

log "Installing in-memory channel + MT broker (good enough for the demo)..."
kubectl apply -f "https://github.com/knative/eventing/releases/download/knative-${KNATIVE_VERSION}/in-memory-channel.yaml"
kubectl apply -f "https://github.com/knative/eventing/releases/download/knative-${KNATIVE_VERSION}/mt-channel-broker.yaml"

# --- 5. Wait for control planes --------------------------------------------
log "Waiting for Serving + Eventing to be Ready..."
kubectl wait --for=condition=Available --timeout=300s deployment --all -n knative-serving
kubectl wait --for=condition=Available --timeout=300s deployment --all -n knative-eventing
kubectl wait --for=condition=Available --timeout=300s deployment --all -n kourier-system

log "Done. Next: ./scripts/deploy.sh"
