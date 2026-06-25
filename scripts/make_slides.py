#!/usr/bin/env python3
"""
make_slides.py — build the presentation slides DIRECTLY as 16:10 images.

No PDF involved: each slide is authored in HTML/CSS and screenshotted with
headless Google Chrome at 1920x1200 (16:10), 2x → 3840x2400 PNGs in ./.slides.

    python3 scripts/make_slides.py            # render all slides
    python3 scripts/make_slides.py 3          # render only slide 3
"""
import os, sys, subprocess, tempfile, shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.environ.get("SLIDES_DIR", os.path.join(ROOT, ".slides"))
CHROME = os.environ.get("CHROME",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
W, H = 1920, 1200  # 16:10

# ── theme ────────────────────────────────────────────────────────────────────
CSS = """
*{margin:0;padding:0;box-sizing:border-box}
html,body{width:1920px;height:1200px;overflow:hidden}
body{
  background:radial-gradient(1400px 900px at 78% -8%, #15323a 0%, #0d1117 55%);
  color:#e6edf3;
  font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;
  -webkit-font-smoothing:antialiased;
}
.slide{width:1920px;height:1200px;padding:96px 120px;display:flex;flex-direction:column;position:relative}
.eyebrow{font-size:30px;font-weight:700;letter-spacing:.32em;text-transform:uppercase;color:#2dd4bf;margin-bottom:20px}
h1{font-size:78px;line-height:1.05;font-weight:800;letter-spacing:-.02em}
h1 .sub{display:block;font-size:34px;font-weight:500;color:#aeb8c2;margin-top:22px;letter-spacing:0}
.rule{width:120px;height:6px;background:#2dd4bf;border-radius:3px;margin:28px 0 0}
.body{display:flex;gap:64px;margin-top:54px;flex:1;min-height:0}
.col{flex:1;display:flex;flex-direction:column}
ul{list-style:none;display:flex;flex-direction:column;gap:26px}
li{font-size:34px;line-height:1.34;color:#d6dee7;padding-left:46px;position:relative}
li::before{content:"›";position:absolute;left:0;top:-2px;color:#2dd4bf;font-weight:800;font-size:38px}
li b,.hl{color:#fff;font-weight:700}
.teal{color:#2dd4bf;font-weight:700}
.muted{color:#8b949e}
pre{background:#0a0e14;border:1px solid #21303a;border-radius:18px;padding:40px 44px;
    font-family:"SF Mono",Menlo,Consolas,monospace;font-size:30px;line-height:1.5;color:#cdd9e5;
    box-shadow:0 24px 60px -24px rgba(0,0,0,.7)}
pre .c{color:#6b7785}      /* comment */
pre .k{color:#2dd4bf}      /* key */
pre .s{color:#8ddb8d}      /* string/value */
pre .p{color:#e3b341}      /* numbers */
.foot{position:absolute;left:120px;right:120px;bottom:54px;display:flex;justify-content:space-between;
      font-size:26px;color:#6b7785;letter-spacing:.04em}
.foot .pg{color:#2dd4bf;font-weight:700}

/* title slide */
.title{justify-content:center;align-items:flex-start}
.title h1{font-size:170px;line-height:.95}
.title .lead{font-size:40px;color:#c4cdd6;margin-top:34px;max-width:1300px;line-height:1.35}
.title .tag{margin-top:30px;font-size:30px;color:#2dd4bf;font-weight:600;letter-spacing:.04em}

/* two components / pros-cons cards */
.cards{display:flex;gap:40px;margin-top:48px;flex:1}
.card{flex:1;background:#11181f;border:1px solid #21303a;border-radius:20px;padding:40px 44px;display:flex;flex-direction:column;justify-content:center}
.card h3{font-size:36px;margin-bottom:8px;display:flex;align-items:center;gap:16px}
.card h3 .num{display:inline-flex;width:52px;height:52px;border-radius:50%;background:#16323a;color:#2dd4bf;
   align-items:center;justify-content:center;font-size:30px;font-weight:800;border:2px solid #2dd4bf}
.card p{font-size:31px;line-height:1.4;color:#c4cdd6;margin-top:14px}

/* pros/cons */
.pc{font-size:33px;line-height:1.3;padding-left:52px;position:relative;margin-bottom:22px;color:#d6dee7}
.pc.pro::before{content:"✓";position:absolute;left:0;color:#46c167;font-weight:800}
.pc.con::before{content:"✕";position:absolute;left:0;color:#e5688b;font-weight:800}
.card.pros{border-color:#23423a;justify-content:flex-start}.card.cons{border-color:#43232f;justify-content:flex-start}
.card .ttl{font-size:30px;letter-spacing:.2em;text-transform:uppercase;font-weight:700;margin-bottom:30px}
.card.pros .ttl{color:#46c167}.card.cons .ttl{color:#e5688b}

/* eventing diagram */
.flow{display:flex;align-items:stretch;gap:0;margin:40px 0 10px}
.node{flex:1;background:#11181f;border:1px solid #2a3b46;border-radius:18px;padding:30px 26px;text-align:center;display:flex;flex-direction:column;justify-content:center}
.node .n{font-size:34px;font-weight:800;color:#fff}
.node .d{font-size:24px;color:#8b949e;margin-top:10px;line-height:1.3}
.node.accent{border-color:#2dd4bf;background:#102127}
.arrow{display:flex;flex-direction:column;align-items:center;justify-content:center;padding:0 22px;color:#2dd4bf;min-width:120px}
.arrow .lbl{font-size:22px;color:#8b949e;margin-bottom:8px;text-align:center;line-height:1.2}
.arrow .ar{font-size:52px;line-height:1;color:#2dd4bf}

/* table */
table{width:100%;border-collapse:collapse;margin-top:30px;font-size:29px}
th,td{text-align:left;padding:20px 22px;border-bottom:1px solid #21303a}
th{font-size:24px;letter-spacing:.12em;text-transform:uppercase;color:#8b949e;font-weight:700}
td{color:#d6dee7}
tr.me td{background:#102127}
td.k{color:#fff;font-weight:700}
.yes{color:#46c167;font-weight:700}.no{color:#e5688b;font-weight:700}.mid{color:#e3b341;font-weight:700}
.note{margin-top:26px;font-size:30px;color:#aeb8c2;line-height:1.4}
.note b{color:#2dd4bf}
"""

# shell() returns ONE slide's inner markup (the .slide div). page_wrap() turns
# inner markup into a full standalone HTML document (one slide → screenshot, or
# all slides → a navigable deck you open directly in Chrome).
def shell(body, page=None, total=8, klass=""):
    foot = ""
    if page:
        foot = (f'<div class="foot"><span>knative-poc · Serving + Eventing</span>'
                f'<span class="pg">{page} / {total}</span></div>')
    return f"<div class='slide {klass}'>{body}{foot}</div>"

def page_wrap(inner, deck=False):
    head = f"<!doctype html><html><head><meta charset='utf-8'><title>Knative · slides</title><style>{CSS}{DECK_CSS if deck else ''}</style></head>"
    if not deck:
        return f"{head}<body>{inner}</body></html>"
    return f"{head}<body><div class='stage'>{inner}</div>{DECK_JS}</body></html>"

# extra CSS + JS only used by the standalone Chrome deck (slides.html):
DECK_CSS = """
body{background:#05080c;display:flex;align-items:center;justify-content:center;height:100vh}
.stage{transform-origin:center center}
.stage .slide{display:none}
.stage .slide.on{display:flex}
"""
DECK_JS = """
<script>
const stage=document.querySelector('.stage'),slides=[...document.querySelectorAll('.slide')];
let i=0;
function fit(){const s=Math.min(innerWidth/1920,innerHeight/1200);stage.style.transform='scale('+s+')';}
function show(n){i=Math.max(0,Math.min(slides.length-1,n));slides.forEach((s,k)=>s.classList.toggle('on',k===i));}
addEventListener('resize',fit);
addEventListener('keydown',e=>{
  if(['ArrowRight','ArrowDown',' ','PageDown','Enter'].includes(e.key)){show(i+1);e.preventDefault();}
  else if(['ArrowLeft','ArrowUp','PageUp','Backspace'].includes(e.key)){show(i-1);e.preventDefault();}
  else if(e.key==='Home'){show(0);}else if(e.key==='End'){show(slides.length-1);}
  else if(e.key>='1'&&e.key<='9'){show(+e.key-1);}
  else if(e.key==='f'||e.key==='F'){document.fullscreenElement?document.exitFullscreen():document.documentElement.requestFullscreen();}
});
addEventListener('click',()=>show(i+1));
fit();show(0);
</script>
"""

# ── slides ───────────────────────────────────────────────────────────────────
def s1():
    body = """
    <div class="eyebrow">Serverless on Kubernetes</div>
    <h1>Knative</h1>
    <div class="lead">Scale-to-zero HTTP services &amp; event-driven workloads —<br>a live PoC on a local <span class="teal">kind</span> cluster.</div>
    """
    return shell(body, klass="title")

def s2():
    body = """
    <div class="eyebrow">The Idea</div>
    <h1>What is Knative?<span class="sub">An open-source Kubernetes add-on — from Google, now a graduated CNCF project — that brings a serverless developer experience to any cluster. Runs your normal containers: no proprietary runtime, no lock-in.</span></h1>
    <div class="cards">
      <div class="card"><h3><span class="num">1</span> Serving</h3>
        <p>Request-driven autoscaling, including <b>scale-to-zero</b>, for HTTP workloads. One YAML replaces Deployment + Service + Ingress + HPA.</p></div>
      <div class="card"><h3><span class="num">2</span> Eventing</h3>
        <p>A pub/sub layer — <b>Brokers, Triggers, Sources</b> — all speaking the CloudEvents standard. Loosely-coupled, event-driven apps.</p></div>
    </div>
    """
    return shell(body, page=2)

def s3():
    body = """
    <div class="eyebrow">How it works · Part 1</div>
    <h1>Serving — one object, zero idle cost</h1>
    <div class="rule"></div>
    <div class="body">
      <div class="col"><ul>
        <li>Apply a single <b>Knative Service</b>. Knative generates the Deployment, Pod, K8s Service, ingress route &amp; autoscaler for you.</li>
        <li>The <b>Autoscaler (KPA)</b> watches <b>concurrent requests</b>, not CPU — scales <span class="teal">0 → N</span> and back to <span class="teal">0</span>.</li>
        <li><b>No traffic ⇒ no pods ⇒ no cost.</b> The first request triggers a <b>cold start</b>.</li>
        <li>Each deploy is an immutable <b>Revision</b> → instant rollback &amp; traffic splitting.</li>
      </ul></div>
      <div class="col"><pre><span class="c"># manifests/service.yaml</span>
<span class="k">kind</span>: Service        <span class="c"># serving.knative.dev</span>
<span class="k">metadata</span>:
  <span class="k">name</span>: <span class="s">hello</span>
<span class="k">spec</span>:
  <span class="k">template</span>:
    <span class="k">metadata</span>:
      <span class="k">annotations</span>:
        <span class="k">min-scale</span>: <span class="s">"0"</span>   <span class="c"># scale to zero</span>
        <span class="k">max-scale</span>: <span class="s">"5"</span>
        <span class="k">target</span>:    <span class="s">"10"</span>  <span class="c"># req/pod</span>
    <span class="k">spec</span>:
      <span class="k">containers</span>:
        - <span class="k">image</span>: <span class="s">knative-poc-hello:dev</span></pre></div>
    </div>
    """
    return shell(body, page=3)

def s4():
    body = """
    <div class="eyebrow">How it works · Part 2</div>
    <h1>Eventing — pub/sub with CloudEvents</h1>
    <div class="rule"></div>
    <div class="flow">
      <div class="node"><div class="n">PingSource</div><div class="d">cron · every 1 min</div></div>
      <div class="arrow"><div class="lbl">CloudEvent</div><div class="ar">→</div></div>
      <div class="node accent"><div class="n">Broker</div><div class="d">in-memory pub/sub hub</div></div>
      <div class="arrow"><div class="lbl">Trigger<br>filter: type=ping</div><div class="ar">→</div></div>
      <div class="node"><div class="n">hello Service</div><div class="d">scales 0..5</div></div>
    </div>
    <div class="body" style="margin-top:34px"><div class="col"><ul>
      <li><b>Source</b> produces events (timer, Kafka, GitHub, S3…). Here a PingSource fires on a cron schedule.</li>
      <li><b>Broker</b> is the central hub that receives and buffers events.</li>
      <li><b>Trigger</b> is a subscription with a filter — "route <span class="teal">type=ping</span> to the hello service."</li>
      <li><b>Loose coupling:</b> the source has no idea who consumes its events — any HTTP service is automatically an event sink.</li>
    </ul></div></div>
    """
    return shell(body, page=4)

def s5():
    body = """
    <div class="eyebrow">Live Demo · What's in this repo</div>
    <h1>The PoC we'll run</h1>
    <div class="rule"></div>
    <div class="body">
      <div class="col"><ul>
        <li>A tiny <b>Go HTTP server</b> — replies "hello from &lt;pod&gt;", and logs any CloudEvent it receives. Same binary serves both roles.</li>
        <li>Runs on a local <b>kind</b> cluster — <span class="teal">setup.sh</span> + <span class="teal">deploy.sh</span> install Knative &amp; deploy it.</li>
        <li>Handles <b>SIGTERM</b> for graceful drain on scale-down.</li>
        <li class="muted" style="color:#2dd4bf"><b>Punchline:</b> the same scale-to-zero workload is also an event consumer — zero code changes.</li>
      </ul></div>
      <div class="col"><pre><span class="c"># 1 · Serving: cold start → autoscale</span>
demo.sh <span class="k">cold</span>   <span class="c"># wakes a pod 0→1</span>
demo.sh <span class="k">load</span>   <span class="c"># 30s traffic → 2–5 pods</span>
<span class="c">#   …idle ~10s → back to 0</span>

<span class="c"># 2 · Eventing: fire an event</span>
demo.sh <span class="k">send-event</span>
<span class="c"># log: "CloudEvent received</span>
<span class="c">#       type=dev.knative.sources.ping"</span>
<span class="c"># a pod spins up just to handle it</span></pre></div>
    </div>
    """
    return shell(body, page=5)

def s6():
    body = """
    <div class="eyebrow">Trade-offs</div>
    <h1>Pros &amp; Cons</h1>
    <div class="cards">
      <div class="card pros"><div class="ttl">Pros</div>
        <div class="pc pro"><b>Scale-to-zero</b> — pay/run nothing when idle.</div>
        <div class="pc pro"><b>Less boilerplate</b> — one YAML vs. 4–5 K8s objects.</div>
        <div class="pc pro"><b>No lock-in</b> — plain containers, any K8s, any cloud.</div>
        <div class="pc pro"><b>CloudEvents-native</b> eventing, pluggable sources.</div>
        <div class="pc pro">Built-in <b>revisions, rollbacks, traffic splitting</b>.</div>
      </div>
      <div class="card cons"><div class="ttl">Cons</div>
        <div class="pc con"><b>Cold starts</b> — first request after idle has latency.</div>
        <div class="pc con">You still run <b>Kubernetes</b> — not zero-ops like a managed FaaS.</div>
        <div class="pc con"><b>Operational complexity</b> — extra control plane &amp; networking layer.</div>
        <div class="pc con">Mostly <b>HTTP/event-driven</b> — not for long-lived or batch jobs.</div>
        <div class="pc con">Learning curve on top of K8s.</div>
      </div>
    </div>
    """
    return shell(body, page=6)

def s7():
    rows = [
        ("Knative", ("Yes","yes"), "Any Kubernetes", ("None","yes"), "Portable serverless + eventing on K8s", True),
        ("Plain K8s + HPA", ("No (min 1 pod)","no"), "Any Kubernetes", ("None","yes"), "Steady-state services", False),
        ("KEDA", ("Yes (event-based)","yes"), "Any Kubernetes", ("None","yes"), "Event/queue-driven autoscaling", False),
        ("AWS Lambda", ("Yes","yes"), "AWS only", ("High","no"), "Pure FaaS, no cluster to run", False),
        ("Google Cloud Run", ("Yes","yes"), "GCP (Knative API)", ("Medium","mid"), "Managed serverless, Knative API", False),
        ("OpenFaaS", ("Yes","yes"), "Any Kubernetes", ("Low","mid"), "Function-first simplicity", False),
    ]
    trs = ""
    for name,(stz,sc),runs,(lock,lc),best,me in rows:
        trs += (f'<tr class="{"me" if me else ""}"><td class="k">{name}</td>'
                f'<td class="{sc}">{stz}</td><td>{runs}</td>'
                f'<td class="{lc}">{lock}</td><td>{best}</td></tr>')
    body = f"""
    <div class="eyebrow">Landscape</div>
    <h1>How it compares</h1>
    <table>
      <tr><th>Technology</th><th>Scale-to-zero</th><th>Runs on</th><th>Lock-in</th><th>Best for</th></tr>
      {trs}
    </table>
    <div class="note"><b>Knative = the open standard.</b> Google Cloud Run implements the Knative Serving API — write once, run it managed or self-hosted.</div>
    """
    return shell(body, page=7)

def s8():
    body = """
    <div class="eyebrow">Takeaways</div>
    <h1>Wrap-up<span class="sub">Thank you — questions?</span></h1>
    <div class="rule"></div>
    <div class="body"><div class="col" style="justify-content:center"><ul>
      <li><b>Serving</b> shrinks an HTTP service's deployment surface to a single YAML, with scale-to-zero for free.</li>
      <li><b>Eventing</b> gives simple, composable, CloudEvents-native pub/sub — any HTTP service becomes an event sink.</li>
      <li><b>Portable serverless:</b> the productivity of Lambda/Cloud Run without the cloud lock-in.</li>
      <li>Trade cold-start latency &amp; some ops overhead for <b>cost savings and developer velocity</b>.</li>
    </ul></div></div>
    """
    return shell(body, page=8)

SLIDES = [s1, s2, s3, s4, s5, s6, s7, s8]

def render_png(n, inner, tmp):
    htmlp = os.path.join(tmp, f"slide{n:02d}.html")
    out = os.path.join(OUT, f"slide{n:02d}.png")
    with open(htmlp, "w") as f:
        f.write(page_wrap(inner))
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    "--force-device-scale-factor=2", f"--window-size={W},{H}",
                    f"--screenshot={out}", htmlp],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"  slide{n:02d}.png")

def build_deck():
    inner = "".join(fn() for fn in SLIDES)
    path = os.path.join(ROOT, "slides.html")
    with open(path, "w") as f:
        f.write(page_wrap(inner, deck=True))
    print(f"  slides.html  (open in Chrome: ← → / Space navigate · f fullscreen · 1-8 jump)")
    return path

def main():
    os.makedirs(OUT, exist_ok=True)
    arg = sys.argv[1] if len(sys.argv) > 1 else "all"
    if arg in ("html", "deck"):                 # only the standalone Chrome deck
        build_deck(); return
    if not os.path.exists(CHROME):
        sys.exit(f"Google Chrome not found at {CHROME} (set CHROME=...)")
    only = int(arg) if arg.isdigit() else None
    tmp = tempfile.mkdtemp(prefix="knative-slides-")
    try:
        for i, fn in enumerate(SLIDES, 1):
            if only and i != only:
                continue
            render_png(i, fn(), tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if not only:
        build_deck()                            # always refresh the Chrome deck too
    print(f"slides → {OUT} (16:10, {W*2}x{H*2})  ·  Chrome deck → slides.html")

if __name__ == "__main__":
    main()
