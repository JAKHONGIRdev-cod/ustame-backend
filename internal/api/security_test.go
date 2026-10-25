package api

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestClientIPPrefersRealIP(t *testing.T) {
	cases := []struct {
		name, realIP, forwarded, remote, want string
	}{
		{"X-Real-IP ustun", "203.0.113.7", "203.0.113.7, 100.64.0.2", "10.0.0.1:5000", "203.0.113.7"},
		{"faqat X-Forwarded-For", "", "203.0.113.8, 100.64.0.2", "10.0.0.1:5000", "203.0.113.8"},
		{"sarlavhasiz", "", "", "198.51.100.4:443", "198.51.100.4"},
	}
	for _, c := range cases {
		r := httptest.NewRequest(http.MethodPost, "/api/auth/verify", nil)
		r.RemoteAddr = c.remote
		if c.realIP != "" {
			r.Header.Set("X-Real-Ip", c.realIP)
		}
		if c.forwarded != "" {
			r.Header.Set("X-Forwarded-For", c.forwarded)
		}
		if got := clientIP(r); got != c.want {
			t.Errorf("%s: clientIP = %q, kutilgan %q", c.name, got, c.want)
		}
	}
}

func TestSecurityHeaders(t *testing.T) {
	h := securityHeaders(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/files" {
			w.Header().Set("Cache-Control", "public, max-age=86400")
		}
		w.WriteHeader(http.StatusOK)
	}))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/api/rpc/get_me", nil))
	for k, want := range map[string]string{
		"X-Content-Type-Options": "nosniff",
		"X-Frame-Options":        "DENY",
		"Cache-Control":          "no-store",
		"Referrer-Policy":        "no-referrer",
	} {
		if got := rec.Header().Get(k); got != want {
			t.Errorf("%s = %q, kutilgan %q", k, got, want)
		}
	}
	if rec.Header().Get("Content-Security-Policy") == "" || rec.Header().Get("Strict-Transport-Security") == "" {
		t.Error("CSP va HSTS bo'lishi kerak")
	}

	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/files", nil))
	if got := rec.Header().Get("Cache-Control"); got != "public, max-age=86400" {
		t.Errorf("fayllar o'z keshini qo'ya olishi kerak, Cache-Control = %q", got)
	}
}

func TestVerifyLimiterPerIP(t *testing.T) {
	l := hourLimiter{max: verifyPerIPPerHour}
	now := time.Now()
	for i := 0; i < verifyPerIPPerHour; i++ {
		if !l.allow("203.0.113.7", now) {
			t.Fatalf("%d-urinish o'tishi kerak edi", i+1)
		}
	}
	if l.allow("203.0.113.7", now) {
		t.Fatal("chegaradan keyin to'xtatilishi kerak")
	}
	if !l.allow("203.0.113.8", now) {
		t.Fatal("boshqa IP'ga ta'sir qilmasligi kerak")
	}
}
