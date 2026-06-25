#!/usr/bin/env bash
#
# run-demo.sh — run the live-demo SEGMENT of the talk inside one tmux session.
#
# This is NOT the whole presentation — the slides cover what/why/compare/wrap.
# This drives only the hands-on part: scale-to-zero, cold start, autoscale, and
# a CloudEvent delivered to the same service. It builds a tmux session with four
# panes and a guided, self-narrating driver pane. Self-paced — advance with Enter.
#
#   ./scripts/run-demo.sh          # build the tmux session and attach
#   ./scripts/run-demo.sh auto      # HANDS-FREE: auto-advances so you can talk over it
#   ./scripts/run-demo.sh drive    # (run automatically in the driver pane)
#   ./scripts/run-demo.sh kill      # tear down the tmux session
#   ./scripts/run-demo.sh --help
#
# Auto mode advances every STEP_SECONDS (default 10). Tune the pace with:
#   STEP_SECONDS=15 ./scripts/run-demo.sh auto
# During auto mode: press Enter to skip a countdown, Ctrl-C to abort.
#
# Pane layout (2x2 tiled):
#   ┌─ T0 · port-forward ─┬─ T2 · pods ──────┐
#   │ ./scripts/demo.sh pf│ ./demo.sh pods   │
#   ├─ T3 · logs ─────────┼─ T1 · driver ────┤
#   │ ./scripts/demo.sh   │ guided steps you │
#   │   logs              │ read from        │
#   └─────────────────────┴──────────────────┘
#
# Prereqs: ./scripts/setup.sh and ./scripts/deploy.sh must have run already.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOCAL_PORT="${LOCAL_PORT:-8080}"
SESSION="${SESSION:-knative-demo}"

# ── colors ───────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RST=$'\033[0m'
  CYAN=$'\033[36m'; BLUE=$'\033[34m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; MAG=$'\033[35m'
else
  BOLD=""; DIM=""; RST=""; CYAN=""; BLUE=""; GREEN=""; YELLOW=""; MAG=""
fi

say()  { printf "%s\n" "$*"; }
hr()   { printf "%s\n" "${DIM}────────────────────────────────────────────────────────────────────────${RST}"; }
step() { printf "\n%s\n" "${BOLD}${CYAN}▶ $*${RST}"; hr; }
quote(){ printf "%s\n" "${MAG}❝ $* ❞${RST}"; }   # the line to say out loud
run()  { printf "%s\n" "${DIM}\$ $*${RST}"; eval "$*"; }

# ── timing model ─────────────────────────────────────────────────────────────
# The live demo is delivered as TWO triggered, hands-free blocks that each fit a
# reserved window from the speaker script (scripts/run-demo.sh → SPEAKER SCRIPT):
#   • serving block — cold start + autoscale — reserved 1:45–2:45  (≈60s)
#   • events  block — CloudEvent delivery    — reserved 3:45–4:30  (≈45s)
# You press Enter to START each block when you reach it in the talk; the block
# then runs ON ITS OWN, paced to fill the window, so you just narrate over it.
# Tune the budgets if your slot differs:
#   SERVING_SECONDS=70 EVENTS_SECONDS=40 ./scripts/run-demo.sh
SERVING_SECONDS="${SERVING_SECONDS:-45}"
EVENTS_SECONDS="${EVENTS_SECONDS:-30}"

now() { date +%s; }

# wait_trigger MSG — block here until the presenter hits Enter to START a block.
wait_trigger(){
  printf "\n%s" "${YELLOW}${BOLD}   ▶▶ press Enter to START: $* ${RST}"
  read -r _ </dev/tty
  printf "\n"
}

# countdown SECS MSG — visible, hands-free wait used inside a block (no input).
countdown(){
  local secs="$1"; shift; local s
  for s in $(seq "$secs" -1 1); do
    printf "\r%s   ⏳ %s — %2ds%s " "${DIM}" "$*" "$s" "${RST}"
    sleep 1
  done
  printf "\r%-72s\r" ""
}

# hold_until START TARGET MSG — pad the tail of a block so it lands exactly on
# its reserved duration: sleep out however many seconds remain until TARGET.
hold_until(){
  local start="$1" target="$2"; shift 2
  local elapsed remaining
  elapsed=$(( $(now) - start ))
  remaining=$(( target - elapsed ))
  [ "$remaining" -gt 0 ] && countdown "$remaining" "$*"
}

LOADGEN_POD="knative-loadgen"
LOADGEN_IMAGE="${LOADGEN_IMAGE:-williamyeh/hey}"

# TCP-only readiness probe: confirms the port-forward listener is up WITHOUT
# sending an HTTP request (so the cold-start demo stays genuinely cold).
pf_ready() { (exec 3<>"/dev/tcp/127.0.0.1/${LOCAL_PORT}") 2>/dev/null && exec 3>&- 2>/dev/null; }

wait_for_pf() {
  printf "%s" "Waiting for the Kourier port-forward (T0) to come up"
  for _ in $(seq 1 40); do
    if pf_ready; then printf " %s\n" "${GREEN}ready ✓${RST}"; return 0; fi
    printf "."; sleep 1
  done
  printf "\n%s\n" "${YELLOW}Port-forward not detected on :${LOCAL_PORT}. Check the T0 pane (top-left).${RST}"
  pause
}

# Count non-terminating pods of the hello service.
running_pods() { kubectl get pods -l serving.knative.dev/service=hello --no-headers 2>/dev/null | awk '$3!="Terminating"{c++} END{print c+0}'; }

# Wait until the service scales to zero (cap ~75s), showing a live count.
wait_zero() {
  local n
  for _ in $(seq 1 38); do
    n="$(running_pods)"
    printf "\r   running pods: %s   (waiting for scale-to-zero)        " "$n"
    [ "$n" = "0" ] && { printf "\r   running pods: 0   %s\n" "${GREEN}✓ scaled to zero${RST}            "; return 0; }
    sleep 2
  done
  printf "\n   %s\n" "${YELLOW}Not at zero yet — recent traffic is still draining. Continuing.${RST}"
}

# Generate load FROM INSIDE the cluster against the internal service URL.
# Going through `kubectl port-forward` serializes traffic, so concurrency never
# builds and the service won't scale. An in-cluster `hey` pod hits ?sleep=250 so
# each request holds the connection — concurrency builds and Knative scales out.
start_loadgen() { # dur_seconds concurrency
  kubectl delete pod "$LOADGEN_POD" --ignore-not-found >/dev/null 2>&1 || true
  kubectl run "$LOADGEN_POD" --image="$LOADGEN_IMAGE" --restart=Never -- \
    -z "${1}s" -c "$2" "http://hello.default.svc.cluster.local/?sleep=250" >/dev/null 2>&1 || true
}
stop_loadgen() { kubectl delete pod "$LOADGEN_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }

# ── preflight checks ─────────────────────────────────────────────────────────
preflight() {
  command -v tmux    >/dev/null 2>&1 || { echo "tmux not found — install it (brew install tmux)."; exit 1; }
  command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found — run ./scripts/setup.sh first."; exit 1; }
  if ! docker info >/dev/null 2>&1; then
    echo "${YELLOW}Docker isn't running.${RST} Start Docker Desktop, then:"
    echo "  ./scripts/setup.sh    # (re)create the kind cluster + install Knative"
    echo "  ./scripts/deploy.sh"
    exit 1
  fi
  if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "${YELLOW}Kubernetes API unreachable${RST} (context: $(kubectl config current-context 2>/dev/null))."
    echo "Recreate the cluster:  ./scripts/setup.sh && ./scripts/deploy.sh"
    exit 1
  fi
  if ! kubectl get ksvc hello >/dev/null 2>&1; then
    echo "${YELLOW}Knative service 'hello' not found.${RST} Deploy it first:"
    echo "  ./scripts/setup.sh    # once per machine"
    echo "  ./scripts/deploy.sh"
    exit 1
  fi
}

# ── build the tmux session ───────────────────────────────────────────────────
build_session() {
  # Start fresh: an existing session would leave a stale port-forward on :8080.
  tmux has-session -t "$SESSION" 2>/dev/null && tmux kill-session -t "$SESSION"

  local cd="cd '$PROJECT_DIR'"
  # First pane (T0); capture each pane id as we split so send-keys targets are exact.
  # A roomy default size keeps the headless panes readable until the audience
  # screen attaches (read-only) and resizes them to fill the projector.
  tmux new-session -d -s "$SESSION" -n demo -x "${DEMO_COLS:-203}" -y "${DEMO_ROWS:-52}"
  local p_t0 p_t2 p_t3 p_t1
  p_t0="$(tmux display-message -p -t "$SESSION:demo" -F '#{pane_id}')"
  p_t2="$(tmux split-window -h -t "$p_t0" -P -F '#{pane_id}')"
  p_t3="$(tmux split-window -v -t "$p_t0" -P -F '#{pane_id}')"
  p_t1="$(tmux split-window -v -t "$p_t2" -P -F '#{pane_id}')"
  tmux select-layout -t "$SESSION:demo" tiled

  # Pane titles on the border.
  tmux set-option   -t "$SESSION" pane-border-status top   >/dev/null
  tmux set-option   -t "$SESSION" pane-border-format ' #{pane_title} ' >/dev/null
  tmux select-pane  -t "$p_t0" -T "T0 · port-forward (leave running)"
  tmux select-pane  -t "$p_t2" -T "T2 · pods (scale up/down)"
  tmux select-pane  -t "$p_t3" -T "T3 · service logs"
  tmux select-pane  -t "$p_t1" -T "T1 · driver  ← teleprompter-controlled"

  # Record the driver pane id so the teleprompter (present.sh) can inject the
  # block commands into it (./scripts/run-demo.sh serving|events).
  mkdir -p "$PROJECT_DIR/.demo"
  printf '%s' "$p_t1" > "$PROJECT_DIR/.demo/driver.pane"

  # Launch each pane's command.
  tmux send-keys -t "$p_t0" "$cd && clear && ./scripts/demo.sh pf"   Enter
  tmux send-keys -t "$p_t2" "$cd && clear && ./scripts/demo.sh pods" Enter
  # T3 logs: wait for a pod first (service may be scaled to zero) then follow,
  # so the pane doesn't fall back to a bare shell when there's nothing to tail.
  tmux send-keys -t "$p_t3" "$cd && clear && until kubectl get pods -l serving.knative.dev/service=hello --no-headers 2>/dev/null | grep -q Running; do printf '\\r⏳ waiting for a hello pod…'; sleep 1; done; echo; ./scripts/demo.sh logs" Enter
  tmux send-keys -t "$p_t1" "$cd && clear && ${DRIVER_CMD:-./scripts/run-demo.sh standby}" Enter

  tmux select-pane -t "$p_t1"   # focus the driver
}

attach_session() {
  if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "$SESSION"
  elif [ -t 1 ]; then
    tmux attach-session -t "$SESSION"
  else
    say "${GREEN}Session '${SESSION}' created (detached).${RST}"
    say "Attach with:  ${BOLD}tmux attach -t ${SESSION}${RST}"
    say "Tear down:    ${DIM}./scripts/run-demo.sh kill${RST}"
  fi
}

# ── BLOCK ① · serving: cold start + autoscale, paced to SERVING_SECONDS ───────
# Hands-free. Reserved window in the speaker script: 1:45–2:45 (≈60s).
block_serving() {
  local start; start="$(now)"
  step "① SERVING · cold start → autoscale   ${DIM}(reserved ≈ ${SERVING_SECONDS}s)${RST}"
  wait_for_pf

  # By 1:45 in the talk the service has been idle through slides 1–3, so it
  # should already be scaled to zero — no need to wait it down here.
  quote "With no traffic, Knative runs ZERO pods — by now it has idled all the way down."
  local z; z="$(running_pods)"
  if [ "${z:-0}" = "0" ]; then
    run "kubectl get pods -l serving.knative.dev/service=hello"
    say "${GREEN}👉 No pods. Nothing running, nothing costing money.${RST}"
  else
    say "${DIM}   (${z} still draining — fine; the cold start below still shows a brand-new pod)${RST}"
  fi

  quote "I send ONE request. With zero replicas, Knative must boot a pod first — the cold start."
  run "./scripts/demo.sh cold"
  say "${YELLOW}👉 Watch T2: a pod just appeared, AGE in seconds — born to serve that request.${RST}"

  # Fill the remainder of the window with load, leaving a short tail for the
  # "settles back to zero" beat so the block lands on SERVING_SECONDS.
  local tail=16 elapsed load_dur
  elapsed=$(( $(now) - start ))
  load_dur=$(( SERVING_SECONDS - elapsed - tail ))
  [ "$load_dur" -lt 15 ] && load_dur=15
  quote "Now load: 50 concurrent requests. Concurrency builds and Knative scales out to max-scale 5 — no HPA."
  start_loadgen "$load_dur" 50
  local n bar end; end=$(( $(now) + load_dur ))
  while [ "$(now)" -lt "$end" ]; do
    n="$(running_pods)"; bar=""
    [ "${n:-0}" -gt 0 ] 2>/dev/null && bar="$(printf '%*s' "$n" '' | tr ' ' '#')"
    printf "\r   replicas: %s  %-8s   ${DIM}(autoscaling under load)${RST}   " "${n:-0}" "$bar"
    sleep 2
  done
  printf "\n"
  stop_loadgen
  say "${YELLOW}👉 Replicas climbed toward 5 under load. Now idle — watch them settle back to zero:${RST}"

  # Watch the live drain back to zero (fast now: ~10s), then hold at zero so the
  # block still lands on SERVING_SECONDS.
  local send=$(( start + SERVING_SECONDS ))
  while [ "$(now)" -lt "$send" ]; do
    n="$(running_pods)"; bar=""
    [ "${n:-0}" -gt 0 ] 2>/dev/null && bar="$(printf '%*s' "$n" '' | tr ' ' '#')"
    printf "\r   replicas: %s  %-8s   ${DIM}(draining back to zero)${RST}   " "${n:-0}" "$bar"
    [ "${n:-0}" = "0" ] && { printf "\r   replicas: 0   ${GREEN}✓ scaled to zero — nothing running, nothing costing money${RST}        \n"; break; }
    sleep 1
  done
  hold_until "$start" "$SERVING_SECONDS" "at zero — the cost of an idle service is nothing"
  say "${GREEN}${BOLD}✓ Serving block complete — cold start · autoscale · back to zero.${RST}"
}

# ── BLOCK ② · eventing: a CloudEvent reaches the service, paced to EVENTS_SECONDS
# Hands-free. Reserved window in the speaker script: 3:45–4:30 (≈45s).
block_events() {
  local start; start="$(now)"
  step "② EVENTING · a CloudEvent reaches the SAME service   ${DIM}(reserved ≈ ${EVENTS_SECONDS}s)${RST}"
  quote "Reconnect the trigger and post one CloudEvent to the broker."
  run "kubectl apply -f manifests/trigger.yaml"
  run "./scripts/demo.sh send-event"
  printf "%s" "   Waiting for delivery"
  local line=""
  for _ in $(seq 1 25); do
    line="$(kubectl logs -l serving.knative.dev/service=hello -c user-container --tail=80 2>/dev/null | grep 'CloudEvent received' | tail -1)"
    [ -n "$line" ] && break
    printf "."; sleep 1
  done
  printf "\n"
  if [ -n "$line" ]; then
    say "${GREEN}Delivered →${RST} ${line}"
  else
    say "${YELLOW}(watch T3 — the 'CloudEvent received' line lands within a few seconds)${RST}"
  fi
  quote "Same Go service, now consuming a CloudEvent — zero code changes; it just reads the headers."
  quote "That's the point: any HTTP service is automatically an event sink."

  hold_until "$start" "$EVENTS_SECONDS" "eventing window — event consumed, scaling back down"
  say "${GREEN}${BOLD}✓ Events block complete — CloudEvent delivered.${RST}"
}

# ── orchestrator (runs in the T1 driver pane): two triggered, hands-free blocks
drive() {
  clear
  # If the user aborts mid-demo, restore the event trigger and clean up the loadgen.
  trap 'kubectl apply -f "$PROJECT_DIR/manifests/trigger.yaml" >/dev/null 2>&1; kubectl delete pod knative-loadgen --ignore-not-found --wait=false >/dev/null 2>&1; true' EXIT

  printf "%s\n" "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════════════╗${RST}"
  printf "%s\n" "${BOLD}${BLUE}║   KNATIVE · LIVE-DEMO SEGMENT  (one part of the talk — slides do the rest) ║${RST}"
  printf "%s\n" "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════════════╝${RST}"
  say ""
  say "Delivered as ${BOLD}two triggered, hands-free blocks${RST}. Press Enter to START each when you"
  say "reach it in the talk; the block then runs ${BOLD}on its own${RST} — you just narrate over it."
  say ""
  say "   ${BOLD}①${RST} SERVING  cold start + autoscale   ${DIM}reserved ≈ ${SERVING_SECONDS}s · talk 1:45–2:45${RST}"
  say "   ${BOLD}②${RST} EVENTS   a CloudEvent arrives      ${DIM}reserved ≈ ${EVENTS_SECONDS}s · talk 3:45–4:30${RST}"
  say ""
  say "Other panes:  ${CYAN}T2${RST} pod count (top-right)   ${CYAN}T3${RST} service logs (bottom-left)"
  say "${DIM}tmux: Ctrl-b ↑/↓/←/→ move · Ctrl-b z zoom a pane · Ctrl-b d detach${RST}"

  # Detach the 1-min event heartbeat NOW so the service can idle to zero while
  # you talk through slides 1–3; the events block restores it.
  kubectl delete trigger hello-on-ping --ignore-not-found >/dev/null 2>&1 || true
  say ""
  say "${DIM}(heartbeat trigger detached so the service idles to zero; the events block restores it)${RST}"

  wait_trigger "① SERVING block   — at ~1:45, on the cold-start slide"
  block_serving

  say ""
  say "${CYAN}↪ Now narrate the Eventing slide (2:45–3:45). Start block ② when you reach the events slide.${RST}"
  wait_trigger "② EVENTS block    — at ~3:45, on the events slide"
  block_events

  step "Demo complete — back to the slides"
  say "${GREEN}${BOLD}✓ Shown: scale-to-zero · cold start · autoscale · CloudEvents delivery.${RST}"
  say "Return to the deck for pros/cons, the comparison, and your wrap-up."
  say "${DIM}detach: Ctrl-b d   ·   kill session: ./scripts/run-demo.sh kill${RST}"
}

# ── entry point ──────────────────────────────────────────────────────────────
case "${1:-}" in
  drive)
    drive
    ;;
  up)
    # Build the demo session HEADLESS (no attach) — the teleprompter injects into
    # the driver pane and the audience screen attaches read-only when it needs to
    # show the live demo. Driver goes to standby (heartbeat trigger detached).
    preflight
    build_session
    echo "Demo session '$SESSION' is up (headless). Driver pane: $(cat "$PROJECT_DIR/.demo/driver.pane" 2>/dev/null)."
    ;;
  serving)
    # Run just the serving block hands-free (standalone, or injected by the
    # teleprompter into the driver pane).
    block_serving
    ;;
  events)
    # Run just the events block hands-free (standalone, or injected by the
    # teleprompter into the driver pane).
    block_events
    ;;
  standby)
    # Driver pane, teleprompter-controlled mode: detach the heartbeat trigger so
    # the service idles to zero, print a banner, then return to the shell so the
    # teleprompter can inject `serving`/`events` here at the right moments.
    kubectl delete trigger hello-on-ping --ignore-not-found >/dev/null 2>&1 || true
    if [ -t 1 ]; then C=$'\033[36m'; G=$'\033[32m'; D=$'\033[2m'; B=$'\033[1m'; R=$'\033[0m'; else C=""; G=""; D=""; B=""; R=""; fi
    printf '%s%s  DRIVER · standby — controlled by the teleprompter%s\n\n' "$B" "$C" "$R"
    printf '  The teleprompter starts each live block in this pane automatically:\n'
    printf '     %s① serving%s  cold start + autoscale   (~%ss)\n' "$B" "$R" "${SERVING_SECONDS}"
    printf '     %s② events%s   a CloudEvent arrives      (~%ss)\n\n' "$B" "$R" "${EVENTS_SECONDS}"
    printf '  %sHeartbeat trigger detached so the service idles to zero before the cold start.%s\n' "$D" "$R"
    printf '  %sManual fallback (if not using the teleprompter): run  ./scripts/run-demo.sh serving  then  events%s\n\n' "$D" "$R"
    printf '  %s✓ ready — waiting for the teleprompter%s\n' "$G" "$R"
    ;;
  kill|stop)
    tmux kill-session -t "$SESSION" 2>/dev/null && echo "Killed tmux session '$SESSION'." || echo "No session '$SESSION'."
    kubectl apply -f "$PROJECT_DIR/manifests/trigger.yaml" >/dev/null 2>&1 && echo "Restored heartbeat trigger." || true
    rm -f "$PROJECT_DIR/.demo/driver.pane" 2>/dev/null || true
    ;;
  -h|--help|help)
    sed -n '2,38p' "$0"
    ;;
  "")
    preflight
    build_session
    attach_session
    ;;
  *)
    echo "Unknown argument: $1"; echo "Try: ./scripts/run-demo.sh --help"; exit 1
    ;;
esac
