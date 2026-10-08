package api

import (
	"net/http/httptest"
	"testing"
	"time"
)

func TestHourLimiter(t *testing.T) {
	var l hourLimiter
	now := time.Now()
	for i := 0; i < clientErrorsPerHour; i++ {
		if !l.allow("1.2.3.4", now) {
			t.Fatalf("%d-urinish ruxsat etilishi kerak edi", i+1)
		}
	}
	if l.allow("1.2.3.4", now) {
		t.Fatal("soatlik chegaradan keyin rad etilishi kerak")
	}
	if !l.allow("5.6.7.8", now) {
		t.Fatal("boshqa IP alohida hisoblanadi")
	}
	if !l.allow("1.2.3.4", now.Add(time.Hour)) {
		t.Fatal("bir soatdan keyin yana ruxsat")
	}
}

func TestCleanupDueOncePerDay(t *testing.T) {
	var l hourLimiter
	now := time.Now()
	if !l.cleanupDue(now) || l.cleanupDue(now.Add(time.Hour)) || !l.cleanupDue(now.Add(25*time.Hour)) {
		t.Fatal("tozalash kuniga bir marta bo'lishi kerak")
	}
}

func TestClipAndClientIP(t *testing.T) {
	if got := clip("  salom dunyo  ", 5); got != "salom" {
		t.Fatalf("clip = %q", got)
	}
	if got := clip("o'zbekcha ✓", 100); got != "o'zbekcha ✓" {
		t.Fatalf("clip qisqa matnni o'zgartirmasligi kerak: %q", got)
	}
	r := httptest.NewRequest("POST", "/api/client-errors", nil)
	r.Header.Set("X-Forwarded-For", "203.0.113.7, 10.0.0.1")
	if got := clientIP(r); got != "203.0.113.7" {
		t.Fatalf("clientIP = %q", got)
	}
}
