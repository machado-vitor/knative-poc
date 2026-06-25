# Knative PoC — convenience wrapper around the scripts in ./scripts and the Go app.
# Run `make` or `make help` to see available targets.

CLUSTER_NAME ?= knative-poc
IMAGE        ?= dev.local/knative-poc-hello:dev
GO_IMAGE     ?= golang:1.22-alpine

.DEFAULT_GOAL := help

## help: Show this help.
.PHONY: help
help:
	@echo "Knative PoC — make targets:"
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## /  /'

## setup: Create the kind cluster and install Knative (scripts/setup.sh).
.PHONY: setup
setup:
	./scripts/setup.sh

## deploy: Build the image, load it into kind, and apply the manifests (scripts/deploy.sh).
.PHONY: deploy
deploy:
	./scripts/deploy.sh

## test: Run Go unit tests in Docker (no local Go toolchain required).
.PHONY: test
test:
	docker run --rm -v "$(CURDIR)/app":/src -w /src $(GO_IMAGE) go test ./...

## smoke: Run the end-to-end smoke test (assumes `make deploy` has run).
.PHONY: smoke
smoke:
	./scripts/smoke.sh

## build: Build the app container image locally.
.PHONY: build
build:
	docker build -t $(IMAGE) app

## pf: Port-forward Kourier on 127.0.0.1:8080 (leave running in its own terminal).
.PHONY: pf
pf:
	./scripts/demo.sh pf

## logs: Tail logs of the hello service.
.PHONY: logs
logs:
	./scripts/demo.sh logs

## pods: Watch the hello service pods scale up/down.
.PHONY: pods
pods:
	./scripts/demo.sh pods

## cold: Single request showing cold-start latency, then a warm request.
.PHONY: cold
cold:
	./scripts/demo.sh cold

## load: Send 30s of concurrent traffic to trigger autoscaling.
.PHONY: load
load:
	./scripts/demo.sh load

## send-event: Manually publish a CloudEvent to the broker.
.PHONY: send-event
send-event:
	./scripts/demo.sh send-event

## demo: Launch the live-demo segment in a 4-pane tmux session (scripts/run-demo.sh).
.PHONY: demo
demo:
	./scripts/run-demo.sh

## demo-kill: Tear down the demo tmux session.
.PHONY: demo-kill
demo-kill:
	./scripts/run-demo.sh kill

## present: Open the FULL presenter setup — full-screen slides + teleprompter (controls everything).
.PHONY: present
present:
	./scripts/present.sh --launch

## slides-screen: Open just the full-screen AUDIENCE slide window (follows the teleprompter).
.PHONY: slides-screen
slides-screen:
	./scripts/present.sh --screen

## slides: Build the 16:10 slides directly as images (Chrome) + the HTML deck.
.PHONY: slides
slides:
	python3 scripts/make_slides.py

## deck: Build + open the slides as an HTML deck in Chrome (← → navigate · f fullscreen).
.PHONY: deck
deck:
	python3 scripts/make_slides.py html && open -a "Google Chrome" slides.html

## teardown: Delete the kind cluster (scripts/teardown.sh).
.PHONY: teardown
teardown:
	./scripts/teardown.sh
