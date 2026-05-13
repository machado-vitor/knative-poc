#!/usr/bin/env bash
# Delete the kind cluster created by setup.sh.
set -euo pipefail
CLUSTER_NAME="${CLUSTER_NAME:-knative-poc}"
kind delete cluster --name "$CLUSTER_NAME"
echo "Cluster '$CLUSTER_NAME' removed."
