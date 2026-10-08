package api

import (
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

const (
	clientErrorsPerHour = 30 // bitta IP'dan soatiga (yiqilish takrorlanib bazani to'ldirmasin)
	clientErrorsKeep    = "90 days"
)

// hourLimiter — IP bo'yicha soatlik oddiy hisoblagich (xotirada; server qayta ishga tushsa nollanadi).
type hourLimiter struct {
	mu          sync.Mutex
	hits        map[string]*hourWindow
	lastCleanup time.Time // eski xatolarni bazadan tozalash (kuniga ko'pi bilan bir marta)
}

type hourWindow struct {
	start time.Time
	n     int
}

func (l *hourLimiter) allow(key string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.hits == nil || len(l.hits) > 10000 {
		l.hits = map[string]*hourWindow{}
	}
	h := l.hits[key]
	if h == nil || now.Sub(h.start) >= time.Hour {
		h = &hourWindow{start: now}
		l.hits[key] = h
	}
	h.n++
	return h.n <= clientErrorsPerHour
}

func (l *hourLimiter) cleanupDue(now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if now.Sub(l.lastCleanup) < 24*time.Hour {
		return false
	}
	l.lastCleanup = now
	return true
}

// clientIP — Railway proksisi orqasida haqiqiy manzil X-Forwarded-For'ning birinchi qiymatida.
func clientIP(r *http.Request) string {
	if f := r.Header.Get("X-Forwarded-For"); f != "" {
		first, _, _ := strings.Cut(f, ",")
		return strings.TrimSpace(first)
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func clip(s string, n int) string {
	s = strings.TrimSpace(s)
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n])
}

// POST /api/client-errors  { platform, app_version?, message, stack?, context? }
// Ilova (telefon/sayt) ushlanmagan xatolarini yuboradi; admin "Ilova xatolari" bo'limida ko'radi.
// Token ixtiyoriy: bo'lsa, xato shu foydalanuvchiga bog'lanadi.
func (s *Server) clientError(w http.ResponseWriter, r *http.Request) {
	now := time.Now()
	if !s.errLimit.allow(clientIP(r), now) {
		writeError(w, http.StatusTooManyRequests, "RATE_LIMITED")
		return
	}
	var body struct {
		Platform   string `json:"platform"`
		AppVersion string `json:"app_version"`
		Message    string `json:"message"`
		Stack      string `json:"stack"`
		Context    string `json:"context"`
	}
	if err := readJSON(w, r, &body); err != nil || strings.TrimSpace(body.Message) == "" {
		writeError(w, http.StatusBadRequest, "INVALID_INPUT")
		return
	}
	platform := body.Platform
	if platform != "android" && platform != "ios" && platform != "web" {
		platform = "unknown"
	}
	var userID *string
	if id, _, ok := s.tokenUser(r); ok {
		userID = &id
	}

	ctx := r.Context()
	// Foydalanuvchi o'chirilgan bo'lsa ham xato yo'qolmasin: user_id faqat mavjud bo'lsa yoziladi
	if _, err := s.db.Exec(ctx, `
		insert into client_errors (user_id, platform, app_version, message, stack, context)
		values ((select id from users where id = $1::uuid), $2, nullif($3, ''), $4, nullif($5, ''), nullif($6, ''))`,
		userID, platform, clip(body.AppVersion, 40), clip(body.Message, 500), clip(body.Stack, 4000),
		clip(body.Context, 200)); err != nil {
		s.fail(w, "client-error", err)
		return
	}
	if s.errLimit.cleanupDue(now) {
		s.db.Exec(ctx, `delete from client_errors where created_at < now() - interval '`+clientErrorsKeep+`'`)
	}
	w.WriteHeader(http.StatusNoContent)
}
