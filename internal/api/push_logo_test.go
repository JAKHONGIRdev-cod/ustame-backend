package api

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/JAKHONGIRdev-cod/ustame-backend/internal/config"
	"github.com/JAKHONGIRdev-cod/ustame-backend/internal/push"
)

// Bildirishnoma rasmi butun middleware zanjiri orqali ham ochiladi va keshlanadigan bo'lib qoladi
// (securityHeaders hamma javobga no-store qo'yadi — rasm buni o'zi almashtiradi).
func TestPushLogoRoute(t *testing.T) {
	h := New(&config.Config{}, nil).Handler()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, push.LogoPath, nil))
	if rec.Code != http.StatusOK || rec.Body.Len() == 0 {
		t.Fatalf("status %d, tana %d bayt", rec.Code, rec.Body.Len())
	}
	if ct := rec.Header().Get("Content-Type"); ct != "image/png" {
		t.Fatalf("Content-Type = %q", ct)
	}
	if cc := rec.Header().Get("Cache-Control"); cc != "public, max-age=86400" {
		t.Fatalf("Cache-Control = %q", cc)
	}
}
