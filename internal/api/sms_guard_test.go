package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/JAKHONGIRdev-cod/ustame-backend/internal/eskiz"
)

// Eskiz test rejimida kirish sahifasi SMS'ni ko'rsatmaydi
func TestAuthMethodsHidesSMSInTestMode(t *testing.T) {
	s := &Server{sms: &eskiz.Client{TestMode: true}}
	rec := httptest.NewRecorder()
	s.authMethods(rec, httptest.NewRequest(http.MethodGet, "/api/auth/methods", nil))
	if rec.Code != http.StatusOK || strings.TrimSpace(rec.Body.String()) != `{"sms":false}` {
		t.Fatalf("javob: %d %s", rec.Code, rec.Body.String())
	}
}

func TestSMSLimiterUsesOwnMax(t *testing.T) {
	l := hourLimiter{max: smsPerIPPerHour}
	now := time.Now()
	for i := 0; i < smsPerIPPerHour; i++ {
		if !l.allow("203.0.113.7", now) {
			t.Fatalf("%d-so'rov ruxsat etilishi kerak edi", i+1)
		}
	}
	if l.allow("203.0.113.7", now) {
		t.Fatal("soatlik chegaradan keyin rad etilishi kerak")
	}
	if smsPerIPPerHour == clientErrorsPerHour {
		t.Fatal("test ma'nosiz: chegaralar bir xil")
	}
}

func TestSMSAlertAtMostEverySixHours(t *testing.T) {
	var a smsAlert
	now := time.Now()
	if !a.due(now) || a.due(now.Add(time.Hour)) || !a.due(now.Add(smsAlertEvery)) {
		t.Fatal("ogohlantirish 6 soatda ko'pi bilan bir marta bo'lishi kerak")
	}
}
