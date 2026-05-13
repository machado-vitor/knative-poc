package main

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

// startedAt is set once at boot so we can show cold-start latency in the response.
var startedAt = time.Now()

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	http.HandleFunc("/", handle)
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	log.Printf("listening on :%s (revision=%s, pod=%s)", port, revision(), hostname())
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatal(err)
	}
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
