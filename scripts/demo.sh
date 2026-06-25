#!/usr/bin/env bash
# Helper functions used during the talk. Source this file or copy-paste pieces.
#
# All curl-based subcommands route through a kubectl port-forward to the Kourier
# gateway, using the Knative-assigned Host header. Run ./scripts/demo.sh pf in a
# side terminal first (it stays in the foreground until you Ctrl-C it).
#
# Usage:
#   ./scripts/demo.sh url           -> print the service URL
#   ./scripts/demo.sh pf            -> port-forward Kourier (run in its own terminal)
#   ./scripts/demo.sh pods          -> watch pods scale up/down
#   ./scripts/demo.sh cold          -> single curl, shows cold-start latency
#   ./scripts/demo.sh load          -> 30s of concurrent traffic to trigger autoscaling
#   ./scripts/demo.sh logs          -> tail logs of the hello service
#   ./scripts/demo.sh send-event    -> manually emit a CloudEvent to the broker

set -euo pipefail

LOCAL_PORT="${LOCAL_PORT:-8080}"

url() { kubectl get ksvc hello -o jsonpath='{.status.url}'; }
host() { url | sed 's|http://||'; }

# Curl helper: hits the local Kourier port-forward with the right Host header.
ksvc_curl() {
  curl -s -H "Host: $(host)" "http://127.0.0.1:${LOCAL_PORT}$1"
}

cmd="${1:-help}"

case "$cmd" in
  url)
    url; echo
    ;;

  pf)
    echo "Port-forwarding Kourier on 127.0.0.1:${LOCAL_PORT}. Leave this running."
    exec kubectl port-forward -n kourier-system svc/kourier "${LOCAL_PORT}:80"
    ;;

  pods)
    # Side terminal during the talk: a live, auto-refreshing snapshot of the
    # current replica count. Unlike `kubectl get -w` (which appends every state
    # transition until the pane is an unreadable wall of Terminating/Completed),
    # this clears each tick and shows only what's alive right now, with a bar.
    # NOTE: the loop runs with `set +e` — under the script's `set -euo pipefail`,
    # commands that legitimately return non-zero (grep with no match, a false
    # `[ ]` test) would otherwise kill the whole loop the moment pods hit zero.
    set +e
    if [ -t 1 ]; then
      C=$'\033[36m'; G=$'\033[32m'; Y=$'\033[33m'; D=$'\033[2m'; B=$'\033[1m'; R=$'\033[0m'
    else C=""; G=""; Y=""; D=""; B=""; R=""; fi
    trap 'printf "\033[?25h"; exit 0' INT TERM   # restore cursor on Ctrl-C
    printf '\033[?25l'                           # hide cursor (less flicker)
    while true; do
      pods="$(kubectl get pods -l serving.knative.dev/service=hello --no-headers 2>/dev/null)"
      # "alive" = anything not Terminating/Completed (Running, Pending, ContainerCreating…)
      alive="$(printf '%s\n' "$pods" | awk 'NF && $3!="Terminating" && $3!="Completed"')"
      # count with awk (always exits 0; grep -c returns 1 on zero matches)
      n="$(printf '%s\n' "$alive" | awk 'NF{c++} END{print c+0}')"
      term="$(printf '%s\n' "$pods" | awk 'NF && ($3=="Terminating"||$3=="Completed"){c++} END{print c+0}')"
      bar="$(printf '%*s' "$n" '' | tr ' ' '#')"
      printf '\033[H\033[2J'                      # home + clear
      printf '%s%s hello · live replicas %s\n\n' "$B" "$C" "$R"
      if [ "$n" -ge 1 ]; then col="$G"; else col="$Y"; fi
      printf '   %sREPLICAS: %d%s  %s%s%s   %s(max-scale 5)%s\n\n' "$B$col" "$n" "$R" "$col" "$bar" "$R" "$D" "$R"
      if [ -n "$alive" ]; then
        { printf 'POD\tREADY\tSTATUS\tAGE\n'
          printf '%s\n' "$alive" | awk '{print $1"\t"$2"\t"$3"\t"$5}'; } | column -t -s "$(printf '\t')"
      else
        printf '   %s(scaled to zero — nothing running, nothing costing money)%s\n' "$D" "$R"
      fi
      if [ "${term:-0}" -gt 0 ]; then
        printf '\n   %s+%d draining (Terminating/Completed)%s\n' "$D" "$term" "$R"
      fi
      sleep 1
    done
    ;;

  cold)
    echo "First request (likely cold start if pods were scaled to zero):"
    time ksvc_curl /
    echo
    echo "Second request (warm):"
    time ksvc_curl /
    ;;

  load)
    echo "Sending 30s of concurrent traffic to $(url) ..."
    end=$(( $(date +%s) + 30 ))
    while [ "$(date +%s)" -lt "$end" ]; do
      for _ in 1 2 3 4 5 6 7 8 9 10; do ksvc_curl / >/dev/null & done
      wait
    done
    echo "Done. Watch 'kubectl get pods' — Knative should now scale back down."
    ;;

  logs)
    # Stream stdout of every replica of the hello service.
    kubectl logs -l serving.knative.dev/service=hello -c user-container -f --tail=20 --max-log-requests=10
    ;;

  send-event)
    # Manually publish a CloudEvent to the broker so we don't have to wait for the cron PingSource.
    BROKER_URL=$(kubectl get broker default -o jsonpath='{.status.address.url}')
    echo "Posting CloudEvent to $BROKER_URL (from inside the cluster) ..."
    kubectl run curl-once --rm -i --restart=Never --image=curlimages/curl --quiet -- \
      curl -s -X POST "$BROKER_URL" \
        -H "Ce-Id: demo-$(date +%s)" \
        -H "Ce-Specversion: 1.0" \
        -H "Ce-Type: dev.knative.sources.ping" \
        -H "Ce-Source: /demo/manual" \
        -H "Content-Type: application/json" \
        -d '{"message":"hand-rolled event"}'
    echo "Sent. Check ./scripts/demo.sh logs to see it arrive."
    ;;

  help|*)
    sed -n '2,18p' "$0"
    ;;
esac
