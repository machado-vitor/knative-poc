package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestHandle_PlainHTTP_ReturnsGreeting(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rr := httptest.NewRecorder()

	handle(rr, req)

	if got := rr.Code; got != http.StatusOK {
		t.Fatalf("status = %d, want %d", got, http.StatusOK)
	}
	body, _ := io.ReadAll(rr.Body)
	if !strings.HasPrefix(string(body), "hello from ") {
		t.Errorf("body = %q, want prefix %q", string(body), "hello from ")
	}
	if ct := rr.Header().Get("Content-Type"); ct != "text/plain" {
		t.Errorf("Content-Type = %q, want %q", ct, "text/plain")
	}
}

func TestHandle_CloudEvent_Returns204AndEmptyBody(t *testing.T) {
	req := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(`{"msg":"hi"}`))
	req.Header.Set("Ce-Id", "abc-123")
	req.Header.Set("Ce-Specversion", "1.0")
	req.Header.Set("Ce-Type", "dev.knative.sources.ping")
	req.Header.Set("Ce-Source", "/test/source")
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()

	handle(rr, req)

	if got := rr.Code; got != http.StatusNoContent {
		t.Fatalf("status = %d, want %d", got, http.StatusNoContent)
	}
	if body, _ := io.ReadAll(rr.Body); len(body) != 0 {
		t.Errorf("body = %q, want empty for CloudEvent response", string(body))
	}
}

func TestHandle_SleepParam_AddsLatencyAndStillGreets(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/?sleep=120", nil)
	rr := httptest.NewRecorder()

	start := time.Now()
	handle(rr, req)
	elapsed := time.Since(start)

	if elapsed < 100*time.Millisecond {
		t.Errorf("elapsed = %s, want >= ~120ms (sleep param ignored?)", elapsed)
	}
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rr.Code, http.StatusOK)
	}
	if body, _ := io.ReadAll(rr.Body); !strings.HasPrefix(string(body), "hello from ") {
		t.Errorf("body = %q, want greeting", string(body))
	}
}

func TestHandle_InvalidSleepParam_DoesNotBlock(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/?sleep=abc", nil)
	rr := httptest.NewRecorder()

	start := time.Now()
	handle(rr, req)

	if elapsed := time.Since(start); elapsed > 50*time.Millisecond {
		t.Errorf("elapsed = %s, want fast for a non-numeric sleep value", elapsed)
	}
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rr.Code, http.StatusOK)
	}
}

func TestHandle_PlainHTTP_IgnoresUnrelatedHeaders(t *testing.T) {
	// Headers that don't start with Ce- should NOT trigger the CloudEvent path.
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("X-Trace-Id", "not-a-cloudevent")
	rr := httptest.NewRecorder()

	handle(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rr.Code, http.StatusOK)
	}
}

func TestCloudEventHeaders_LowercasesAndStripsPrefix(t *testing.T) {
	req := httptest.NewRequest(http.MethodPost, "/", nil)
	req.Header.Set("Ce-Id", "id-1")
	req.Header.Set("Ce-Type", "demo.type")
	req.Header.Set("X-Other", "ignored")

	got := cloudEventHeaders(req)

	if got["id"] != "id-1" {
		t.Errorf("ce.id = %q, want %q", got["id"], "id-1")
	}
	if got["type"] != "demo.type" {
		t.Errorf("ce.type = %q, want %q", got["type"], "demo.type")
	}
	if _, present := got["x-other"]; present {
		t.Errorf("non-Ce header leaked into CloudEvent map: %+v", got)
	}
}
