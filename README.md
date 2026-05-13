# Knative PoC — 5-minute live demo

A self-contained proof-of-concept that demonstrates both **Knative Serving**
(scale-to-zero HTTP service) and **Knative Eventing** (broker + trigger + source)
on a local `kind` cluster, using a tiny Go HTTP server as the workload.

```
knative-poc/
├── app/                 # Go HTTP service (responds to plain HTTP + CloudEvents)
├── manifests/           # Knative Service, Broker, Trigger, PingSource
├── scripts/
│   ├── setup.sh         # Install tools, create kind cluster, install Knative
│   ├── deploy.sh        # Build image, load into kind, apply manifests
│   ├── demo.sh          # Helpers used during the talk
│   └── teardown.sh      # Delete the kind cluster
└── README.md
```

## Architecture

```
                       ┌────────────────────────────┐
   curl ──HTTP──►      │     Knative Service        │
                       │  hello (scales 0..5)       │
                       └────────────▲───────────────┘
                                    │
                            Trigger │ filter: type=dev.knative.sources.ping
                                    │
                       ┌────────────┴───────────────┐
   PingSource ──CE──►  │   Broker (in-memory)       │
   (every 1 min)       └────────────────────────────┘
```

## Pre-talk checklist (do this once, ~5 minutes)

```sh
./scripts/setup.sh    # installs kind/kubectl/docker if missing, creates cluster, installs Knative
./scripts/deploy.sh   # builds Go app, loads into kind, applies manifests
```

In a **separate terminal**, start the Kourier port-forward and leave it running
for the entire talk — kind has no external LoadBalancer IP, so this is how
HTTP traffic from your laptop reaches the Knative gateway:

```sh
./scripts/demo.sh pf  # forwards 127.0.0.1:8080 -> kourier:80 (Ctrl-C to stop)
```

Sanity check from yet another terminal:

```sh
./scripts/demo.sh url      # http://hello.default.127.0.0.1.sslip.io
./scripts/demo.sh cold     # should print "hello from <pod-name> ..."
```

Then confirm scale-to-zero before the talk (give it ~1 minute of idle):

```sh
kubectl get pods -l serving.knative.dev/service=hello
# Eventually: No resources found.
```

## 5-minute talk script

Open **four terminals** before you start:

- **T0** — `./scripts/demo.sh pf`    (Kourier port-forward — leave running)
- **T1** — slide-driver / kubectl apply / `demo.sh cold` / `demo.sh load`
- **T2** — `./scripts/demo.sh pods`  (live pod watch)
- **T3** — `./scripts/demo.sh logs`  (live service logs)

### 0:00 — 0:30 | What is Knative? (1 slide)

> "Knative is a Kubernetes add-on with two parts. **Serving** gives you
> request-driven autoscaling — including scale-to-zero — for HTTP workloads.
> **Eventing** gives you a pub/sub layer with brokers, triggers, and sources,
> all speaking the CloudEvents spec. I'll show both in four minutes."

### 0:30 — 1:30 | Serving: the YAML

In T1, show `manifests/service.yaml`. Highlight:

- `kind: Service` from `serving.knative.dev` — *not* a core K8s Service.
- Autoscaling annotations: `min-scale: 0`, `target: 10` concurrent requests.
- No Deployment, ReplicaSet, HPA, Service, Ingress — Knative creates all of
  those for you from this single object.

```sh
kubectl get ksvc hello
kubectl get pods -l serving.knative.dev/service=hello   # likely empty: scale-to-zero
```

### 1:30 — 2:30 | Serving: cold start + autoscale

```sh
./scripts/demo.sh cold     # first request wakes a pod; second is instant
```

Point at T2: a pod just appeared. Then:

```sh
./scripts/demo.sh load     # 30s of concurrent traffic
```

Point at T2: replicas climb to 2–5, then drop back to 0 within ~30s of idle.
That's `min-scale: 0` + `max-scale: 5` + `target: 10` doing its job — no
HPA configuration, no Deployment, no manual scaling.

### 2:30 — 3:30 | Eventing: the wiring

Show `manifests/broker.yaml`, `pingsource.yaml`, `trigger.yaml`. Narrate:

> "The Broker is a pub/sub hub. The PingSource emits a CloudEvent on a cron
> schedule. The Trigger is a subscription with a filter: 'send events of type
> `dev.knative.sources.ping` to the hello Service.' Loose coupling — the
> source has no idea who consumes its events."

```sh
kubectl get broker,trigger,pingsource
```

### 3:30 — 4:30 | Eventing: events flowing

Point at T3 (logs). Then either wait for the cron tick **or**:

```sh
./scripts/demo.sh send-event
```

A line like this appears in T3:

```
CloudEvent received type=dev.knative.sources.ping source=/apis/v1/... id=...
```

And in T2 a pod spun up just to handle the event, then will scale back down.
*This is the punchline*: the same scale-to-zero workload is now also an
event consumer, with zero code changes.

### 4:30 — 5:00 | Wrap-up

> "Two takeaways:
> 1. Knative reduces the deployment surface for HTTP services to a single YAML,
>    and gives you scale-to-zero out of the box.
> 2. The Eventing primitives — Broker, Trigger, Source — are simple, composable,
>    and CloudEvents-native, so any HTTP service is automatically an event sink."

## Tear down

```sh
./scripts/teardown.sh
```

## Notes & gotchas

- **Local image registry**: the image is tagged `dev.local/knative-poc-hello:dev`.
  Knative's controller normally resolves tag→digest from a registry; the
  `dev.local/` prefix is on Knative's built-in `registries-skipping-tag-resolving`
  allowlist (alongside `kind.local` and `ko.local`), so the digest check is
  skipped. `kind load docker-image` puts the image directly into the kind node.
- **No external LoadBalancer**: kind doesn't provide one, so we don't use
  Knative's `serving-default-domain` auto-config job (it hangs waiting for an
  EXTERNAL-IP that never arrives). Instead `setup.sh` patches `config-domain`
  to `127.0.0.1.sslip.io` directly, and we port-forward Kourier for HTTP traffic.
- **Knative version** is pinned via `KNATIVE_VERSION` in `setup.sh`
  (default `v1.16.0`). Bump it as needed.
