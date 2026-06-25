#!/usr/bin/env bash
#
# present.sh — a PRESENTER TELEPROMPTER for the Knative talk.
#
# Run this in its OWN terminal window (separate from the tmux demo). It shows,
# one card at a time: the audience slide (inline, if your terminal is iTerm2),
# the time window from the speaker script, and exactly what to say. Press Enter
# to advance. At the two live-demo moments it tells you to flip to the DEMO
# window and start a block there.
#
#   ./scripts/present.sh             # run the teleprompter here
#   ./scripts/present.sh --launch    # open it in a NEW iTerm2/Terminal window
#
# Keys while presenting:  Enter = next · b = back · q = quit
#
# Slides are shown inline via iTerm2's imgcat. In any other terminal it falls
# back to opening the PDF once in Preview — just advance Preview alongside.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PDF="${PDF:-$PROJECT_DIR/knative-presentation.pdf}"
SLIDES_DIR="${SLIDES_DIR:-$PROJECT_DIR/.slides}"
IMG_WIDTH="${IMG_WIDTH:-48%}"          # how wide to draw the slide in the teleprompter
SCREEN_FLAGS="${SCREEN_FLAGS:---width 100% -r}"   # how the audience screen fills (imgcat)

# The teleprompter is the single control surface. It drives:
#   • the full-screen AUDIENCE window — via the STATE file it watches. STATE holds
#     a slide number (show that slide) OR "demo" (show the live demo) OR "quit".
#   • the live DEMO blocks — by injecting commands into the tmux driver pane.
STATE="${STATE:-$SLIDES_DIR/.current}"                       # slide number | "demo" | "quit"
DEMO_SESSION="${DEMO_SESSION:-knative-demo}"                 # tmux demo session name
DRIVER_PANE_FILE="${DRIVER_PANE_FILE:-$PROJECT_DIR/.demo/driver.pane}"
AUDIENCE_TTY_FILE="${AUDIENCE_TTY_FILE:-$PROJECT_DIR/.demo/audience.tty}"  # audience screen's tty

# ── --launch: open the full presenter setup, then exit ───────────────────────
# TWO windows: (1) a full-screen AUDIENCE window for the projector — it shows the
# slides, and flips to the live demo during the demo blocks; and (2) the
# TELEPROMPTER you drive. The demo tmux session runs HEADLESS in the background;
# the audience window attaches to it read-only only while showing the demo.
if [ "${1:-}" = "--launch" ]; then
  mkdir -p "$(dirname "$STATE")"; printf '1' > "$STATE" 2>/dev/null || true
  rm -f "$AUDIENCE_TTY_FILE" 2>/dev/null || true
  # bring the headless demo session up first (writes the driver-pane id)
  ( cd "$PROJECT_DIR" && ./scripts/run-demo.sh up ) >/dev/null 2>&1
  # Trailing "; exit" so each window self-closes when its process ends (teardown).
  tele="cd '$PROJECT_DIR' && ./scripts/present.sh; exit"
  screen="cd '$PROJECT_DIR' && ./scripts/present.sh --screen; exit"
  if osascript -e 'tell application "iTerm" to version' >/dev/null 2>&1; then
    open_iterm() {
      osascript >/dev/null 2>&1 <<OSA
tell application "iTerm"
  activate
  create window with default profile
  tell current session of current window to write text "$1"
end tell
OSA
    }
    # 1) full-screen AUDIENCE window (toggle iTerm2 native full screen in the same
    #    osascript so the ⌘↩ keystroke lands on THIS window while it's frontmost).
    osascript >/dev/null 2>&1 <<OSA
tell application "iTerm"
  activate
  create window with default profile
  tell current session of current window to write text "$screen"
end tell
delay 0.5
tell application "System Events" to keystroke return using command down
OSA
    # 2) TELEPROMPTER last, so it ends up focused — your control surface.
    open_iterm "$tele"
    echo "Opened two iTerm2 windows: full-screen AUDIENCE (slides + demo) + TELEPROMPTER."
    echo "If the audience window isn't full screen, click it and press ⌘↩, then drag it to the projector."
  else
    osascript >/dev/null 2>&1 <<OSA
tell application "Terminal"
  do script "$tele"
  activate
end tell
OSA
    echo "Opened the teleprompter in Terminal. (Inline + full-screen slides need iTerm2.)"
  fi
  exit 0
fi

# ── --screen: full-screen AUDIENCE window (slides + live demo) ────────────────
# Watches the STATE file and shows whatever the teleprompter selected:
#   • a slide number → that slide, full-screen, via imgcat
#   • "demo"         → the live demo, by attaching READ-ONLY to the tmux session
#   • "quit"         → exit (window self-closes)
# Drag this window to the projector, ⌘↩ for full screen. No keys to press here.
if [ "${1:-}" = "--screen" ]; then
  command -v imgcat >/dev/null 2>&1 || { echo "Full-screen slides need iTerm2 (imgcat)."; exit 1; }
  [ -f "$SLIDES_DIR/slide01.png" ] || python3 "$SCRIPT_DIR/make_slides.py" >/dev/null 2>&1 || true
  mkdir -p "$(dirname "$AUDIENCE_TTY_FILE")"; tty > "$AUDIENCE_TTY_FILE" 2>/dev/null || true
  printf '\033[?25l'                                    # hide cursor
  trap 'printf "\033[?25h"; clear; rm -f "$AUDIENCE_TTY_FILE" 2>/dev/null; exit 0' INT TERM
  cur=""
  while true; do
    want="$(cat "$STATE" 2>/dev/null)"; [ -n "$want" ] || want=1
    case "$want" in
      quit) break ;;
      demo)
        # Show the live demo. attach -r blocks (audience sees the panes live)
        # until the teleprompter detaches this client (to switch back to slides)
        # or the session is killed. Then we fall through and re-read STATE.
        printf '\033[H\033[2J'; printf '\033[?25h'
        tmux attach-session -r -t "$DEMO_SESSION" 2>/dev/null
        printf '\033[?25l'; cur=""          # force a redraw of whatever's next
        ;;
      *)
        if [ "$want" != "$cur" ]; then
          cur="$want"
          img="$SLIDES_DIR/slide$(printf '%02d' "$cur").png"
          printf '\033[H\033[2J'
          [ -f "$img" ] && imgcat ${SCREEN_FLAGS} "$img" 2>/dev/null
        fi
        sleep 0.3
        ;;
    esac
  done
  printf '\033[?25h'; clear; rm -f "$AUDIENCE_TTY_FILE" 2>/dev/null
  exit 0
fi

# ── colors ───────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RST=$'\033[0m'; INV=$'\033[7m'
  CYAN=$'\033[36m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; MAG=$'\033[35m'; BLUE=$'\033[34m'
else
  BOLD=""; DIM=""; RST=""; INV=""; CYAN=""; GREEN=""; YELLOW=""; MAG=""; BLUE=""
fi

# ── slide display ────────────────────────────────────────────────────────────
# Prefer iTerm2 inline images (imgcat). Otherwise open the PDF once in Preview.
# Auto-detected, but an explicit IMG_MODE env (imgcat|preview|none) wins.
IMG_MODE="${IMG_MODE:-}"
if [ -z "$IMG_MODE" ]; then
  if command -v imgcat >/dev/null 2>&1 && [ "${TERM_PROGRAM:-}" = "iTerm.app" ]; then
    IMG_MODE="imgcat"
  elif command -v open >/dev/null 2>&1; then
    IMG_MODE="preview"
  else
    IMG_MODE="none"
  fi
fi

ensure_slides() {
  [ -f "$SLIDES_DIR/slide01.png" ] && return 0
  [ "$IMG_MODE" = "imgcat" ] || return 0
  echo "Rendering slides (first run)…"
  python3 "$SCRIPT_DIR/make_slides.py" >/dev/null 2>&1 || true
}

show_slide() { # $1 = slide number — renders the slide inline for the PRESENTER only
  local img; img="$SLIDES_DIR/slide$(printf '%02d' "$1").png"
  case "$IMG_MODE" in
    imgcat) [ -f "$img" ] && imgcat --width "$IMG_WIDTH" -r "$img" 2>/dev/null || true ;;
    *)      printf "%s   ▣ Slide %s — bring Preview to page %s%s\n" "$DIM" "$1" "$1" "$RST" ;;
  esac
}

# audience TARGET — control what the full-screen AUDIENCE window shows.
#   audience <N>     → slide N        audience demo → the live demo
# AUD_MODE tracks the current target. When leaving demo for a slide, detach the
# audience tmux client so its read-only attach returns and it redraws the slide.
AUD_MODE="slides"
audience() {
  if [ "$1" = "demo" ]; then
    printf 'demo' > "$STATE" 2>/dev/null || true
    AUD_MODE="demo"
  else
    printf '%s' "$1" > "$STATE" 2>/dev/null || true
    if [ "$AUD_MODE" = "demo" ]; then
      local atty; atty="$(cat "$AUDIENCE_TTY_FILE" 2>/dev/null)"
      [ -n "$atty" ] && tmux detach-client -t "$atty" 2>/dev/null || true
    fi
    AUD_MODE="slides"
  fi
}

# fire_block serving|events — inject the block command into the tmux demo driver
# pane so it runs headless. Returns non-zero if the demo isn't running.
fire_block() {
  local pane; pane="$(cat "$DRIVER_PANE_FILE" 2>/dev/null)"
  [ -n "$pane" ] || return 1
  command -v tmux >/dev/null 2>&1 || return 1
  tmux has-session -t "$DEMO_SESSION" 2>/dev/null || return 1
  tmux send-keys -t "$pane" "./scripts/run-demo.sh $1" Enter 2>/dev/null
}

# ── teleprompter primitives ──────────────────────────────────────────────────
say()  { printf "%s\n" "$*"; }
line() { printf "%s\n" "${MAG}❝ $* ❞${RST}"; }          # a line to say out loud
note() { printf "%s\n" "${DIM}   $*${RST}"; }            # stage direction
cue()  { printf "\n%s%s  ▶▶ %s  %s\n" "$BOLD" "$INV" "$*" "$RST"; }   # demo banner

header() { # $1=card idx  $2=slide  $3=time  $4=title
  printf "\n%s━━ %s/%s · slide %s · %s · %s ━━%s\n\n" \
    "$BOLD$CYAN" "$1" "$TOTAL" "$2" "$3" "$4" "$RST"
}

TOTAL=10
FIRED_SERVING=0   # guards so back/forward navigation doesn't re-fire a block
FIRED_EVENTS=0

CUR_SLIDE=1   # the slide for the current card (so [d] can toggle back to it)

render_card() { # $1 = card index (1..TOTAL)
  clear
  # Map card → (slide shown inline to presenter, what the projector shows).
  # Demo cards put the projector on the LIVE DEMO; everything else on the slide.
  # The live demo is split into TWO parts, each after its concept slide:
  #   Serving → the-PoC → DEMO Part 1 → Eventing → DEMO Part 2 → trade-offs…
  local slide aud
  case "$1" in
    1)  slide=1; aud=1 ;;
    2)  slide=2; aud=2 ;;
    3)  slide=3; aud=3 ;;        # Serving — how
    4)  slide=5; aud=5 ;;        # The PoC we'll run (frames both parts)
    5)  slide=3; aud=demo ;;     # DEMO Part 1 — serving (ref: Serving slide)
    6)  slide=4; aud=4 ;;        # Eventing — how
    7)  slide=4; aud=demo ;;     # DEMO Part 2 — events (ref: Eventing slide)
    8)  slide=6; aud=6 ;;
    9)  slide=7; aud=7 ;;
    10) slide=8; aud=8 ;;
  esac
  CUR_SLIDE="$slide"
  show_slide "$slide"     # presenter's inline reference
  audience "$aud"         # projector: this slide, or flip to the live demo

  case "$1" in
  1)
    header 1 1 "0:00" "Title"
    note "Let the title sit for a beat, then:"
    line "Serverless on Kubernetes — Knative. A scale-to-zero HTTP service and event-driven workloads, as a live PoC on a local kind cluster."
    ;;
  2)
    header 2 2 "0:00–0:35" "What is Knative?"
    line "Knative is an open-source add-on that turns any Kubernetes cluster into a serverless platform. It has two parts."
    line "Serving gives request-driven autoscaling — including scale-to-zero — for HTTP workloads. Eventing gives a pub/sub layer — brokers, triggers and sources — all speaking the CloudEvents standard."
    line "It started at Google, it's now a graduated CNCF project, and it runs your normal containers — no proprietary runtime. Let me show you both, live."
    ;;
  3)
    header 3 3 "0:35–1:05" "Serving — one object, zero idle cost"
    note "Point at the YAML on the right."
    line "With Serving you apply one object — a Knative Service. From this single YAML, Knative creates the Deployment, the pod, the Kubernetes Service, the ingress route and the autoscaler."
    line "The key annotations: min-scale 0 means scale to zero when idle; max-scale 5; target 10 — it autoscales on concurrent requests per pod, not CPU. No traffic means no pods, which means no cost. The trade-off: the first request after idle pays a cold start."
    ;;
  4)
    header 4 5 "1:05–1:25" "The PoC we'll run"
    line "Here's what we'll run: one tiny Go HTTP server. It replies 'hello from pod', and it logs any CloudEvent it receives — the same binary serves both roles."
    line "It runs on a local kind cluster, and it handles SIGTERM for a graceful drain when it scales down."
    line "We'll see it in two parts — first Serving: a cold start and autoscaling. Then Eventing: a CloudEvent reaching the same service. Watch for the punchline — same workload, zero code changes."
    ;;
  5)
    header 5 3 "1:25–2:10" "Live demo · Part 1 — cold start + autoscale"
    if [ "$FIRED_SERVING" = 0 ] && fire_block serving; then
      FIRED_SERVING=1
      cue "PROJECTOR is on the LIVE DEMO — Part 1, cold start + autoscale. Just narrate over it:"
    else
      cue "DEMO Part 1 — run  ./scripts/run-demo.sh serving ; [d] flips the projector to it:"
    fi
    line "Part one, Serving. I send one request — with zero replicas Knative boots a pod first; that's the cold start. The request waits, then is served. The second is instant."
    line "Now a burst of concurrent requests. Concurrency builds and Knative adds pods up to max-scale 5 — no HPA, no manual scaling."
    line "That's min-scale 0, max-scale 5 and target 10 doing their job. It scaled up under load, and once idle it falls straight back to zero."
    ;;
  6)
    header 6 4 "2:10–2:40" "Eventing — pub/sub with CloudEvents"
    line "On to part two: Eventing. The Broker is a pub/sub hub. The PingSource emits a CloudEvent on a cron schedule. The Trigger is a subscription with a filter: send events of type ping to the hello service."
    line "This is loose coupling — the source has no idea who consumes its events. You can add or remove subscribers without touching the producer."
    ;;
  7)
    header 7 4 "2:40–3:10" "Live demo · Part 2 — a CloudEvent arrives"
    if [ "$FIRED_EVENTS" = 0 ] && fire_block events; then
      FIRED_EVENTS=1
      cue "PROJECTOR is on the LIVE DEMO — Part 2, one CloudEvent to the broker. Just narrate:"
    else
      cue "DEMO Part 2 — run  ./scripts/run-demo.sh events ; [d] flips the projector to it:"
    fi
    line "Part two. I post one CloudEvent to the broker. There it is in the logs — CloudEvent received, type dev.knative.sources.ping. And in the pod watch, a pod spun up just to handle it, then scales back down."
    line "And there's the punchline: the exact same scale-to-zero workload is now also an event consumer — zero code changes. One Go binary; it just inspects the CloudEvent headers."
    ;;
  8)
    header 8 6 "3:10–3:25" "Trade-offs — Pros & Cons"
    line "Quick trade-offs. You get scale-to-zero, far less boilerplate — one YAML versus four or five K8s objects — no cloud lock-in, and built-in revisions and traffic splitting."
    line "The costs: cold starts on the first request after idle, and you still operate Kubernetes plus an extra control plane — it's not zero-ops like Lambda."
    ;;
  9)
    header 9 7 "3:25–3:40" "Landscape — how it compares"
    line "Compared to alternatives: plain Kubernetes with HPA never scales to zero; KEDA does event-based scaling but not HTTP serving; Lambda gives you FaaS but locks you to AWS."
    line "Knative is the open standard — in fact Google Cloud Run implements the Knative Serving API, so you can write once and run it managed or self-hosted."
    ;;
  10)
    header 10 8 "3:40–4:00" "Wrap-up"
    line "Two takeaways. One: Knative reduces an HTTP service to a single YAML, with scale-to-zero out of the box."
    line "Two: the Eventing primitives — Broker, Trigger, Source — are simple, composable and CloudEvents-native, so any HTTP service is automatically an event sink. Portable serverless, without the lock-in."
    line "Thank you — happy to take questions."
    ;;
  esac
}

# ── main loop ────────────────────────────────────────────────────────────────
ensure_slides
[ "$IMG_MODE" = "preview" ] && open "$PDF" >/dev/null 2>&1 || true

# teardown — when the talk is done, kill everything: stop the audience slides
# window, kill the demo tmux session (which restores the heartbeat trigger and
# removes the pane file). Windows launched via --launch self-close (they run with
# a trailing "; exit"). Set KEEP=1 to skip teardown (e.g. while rehearsing).
teardown() {
  [ -n "${KEEP:-}" ] && return 0
  printf 'quit' > "$STATE" 2>/dev/null || true       # tell the --screen window to exit
  # if the audience window is showing the live demo (blocked on attach), detach
  # it so it reads "quit" and closes.
  local atty; atty="$(cat "$AUDIENCE_TTY_FILE" 2>/dev/null)"
  [ -n "$atty" ] && tmux detach-client -t "$atty" 2>/dev/null || true
  "$SCRIPT_DIR/run-demo.sh" kill >/dev/null 2>&1 || true
}

# Render only when the card changes; a [d] press toggles the projector without
# re-rendering (which would otherwise snap the projector back to the card default).
i=1; last=0
while [ "$i" -ge 1 ] && [ "$i" -le "$TOTAL" ]; do
  [ "$i" != "$last" ] && { render_card "$i"; last="$i"; }
  printf "\n%s   ↵ Enter next  ·  b back  ·  d projector⇄demo  ·  q quit%s " "$DIM" "$RST"
  IFS= read -r k </dev/tty || break
  case "$k" in
    q|Q) break ;;
    d|D) if [ "$AUD_MODE" = "demo" ]; then
           audience "$CUR_SLIDE"; printf "%s   → projector: SLIDE %s%s\n" "$DIM" "$CUR_SLIDE" "$RST"
         else
           audience demo;          printf "%s   → projector: LIVE DEMO%s\n" "$DIM" "$RST"
         fi ;;
    b|B) [ "$i" -gt 1 ] && i=$((i - 1)) ;;
    *)   i=$((i + 1)) ;;
  esac
done

clear
printf "%s✓ Talk complete — tearing everything down…%s\n" "$GREEN$BOLD" "$RST"
teardown
printf "%s  demo session killed · heartbeat trigger restored · audience window closed.%s\n" "$DIM" "$RST"
