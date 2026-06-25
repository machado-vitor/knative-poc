package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// startedAt is set once at boot so we can show cold-start latency in the response.
var startedAt = time.Now()

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", handle)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	srv := &http.Server{Addr: ":" + port, Handler: mux}

	// Knative sends SIGTERM when it scales the pod down (including scale-to-zero).
	// Catch it and drain in-flight requests instead of dropping connections.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	go func() {
		log.Printf("listening on :%s (revision=%s, pod=%s)", port, revision(), hostname())
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}()

	<-ctx.Done()
	stop() // stop catching signals so a second one force-quits

	log.Printf("shutdown signal received, draining in-flight requests...")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Fatalf("graceful shutdown failed: %v", err)
	}
	log.Printf("shutdown complete")
}

func handle(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	defer r.Body.Close()

	ce := cloudEventHeaders(r)
	if len(ce) > 0 {
		log.Printf("CloudEvent received type=%s source=%s id=%s body=%q",
			ce["type"], ce["source"], ce["id"], string(body))
		w.WriteHeader(http.StatusNoContent)
		return
	}

	// Optional artificial latency: GET /?sleep=<ms>. Holding the connection open
	// builds real concurrency, which is what Knative's autoscaler reacts to — handy
	// for demoing scale-up (mirrors Knative's own autoscale-go sample).
	if d := r.URL.Query().Get("sleep"); d != "" {
		if ms, err := strconv.Atoi(d); err == nil && ms > 0 {
			if ms > 10000 {
				ms = 10000 // cap at 10s so a stray value can't wedge a pod
			}
			time.Sleep(time.Duration(ms) * time.Millisecond)
		}
	}

	uptime := time.Since(startedAt).Round(time.Millisecond)
	msg := fmt.Sprintf("hello from %s (revision=%s, uptime=%s)\n",
		hostname(), revision(), uptime)
	log.Printf("HTTP %s %s -> 200", r.Method, r.URL.Path)
	w.Header().Set("Content-Type", "text/plain")
	_, _ = io.WriteString(w, msg)
}

func cloudEventHeaders(r *http.Request) map[string]string {
	out := map[string]string{}
	for k, v := range r.Header {
		lk := strings.ToLower(k)
		if strings.HasPrefix(lk, "ce-") && len(v) > 0 {
			out[strings.TrimPrefix(lk, "ce-")] = v[0]
		}
	}
	return out
}

func hostname() string {
	if h, err := os.Hostname(); err == nil {
		return h
	}
	return "unknown"
}

func revision() string {
	if r := os.Getenv("K_REVISION"); r != "" {
		return r
	}
	return "local"
}
