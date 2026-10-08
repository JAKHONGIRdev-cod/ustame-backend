package api

import (
	"crypto/rand"
	"errors"
	"fmt"
	"log"
	"math/big"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/JAKHONGIRdev-cod/ustame-backend/internal/auth"
)

var sixDigits = regexp.MustCompile(`^\d{6}$`)

// str — JSON qiymatini satrga aylantiradi (Node'dagi String(x) kabi; null -> "").
func str(v any) string {
	if v == nil {
		return ""
	}
	return fmt.Sprint(v)
}

func randomCode() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(900000))
	if err != nil {
		return "", err
	}
	return fmt.Sprint(100000 + n.Int64()), nil
}

// POST /api/auth/send-code  { phone }
func (s *Server) sendCode(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Phone any `json:"phone"`
	}
	readJSON(w, r, &body)
	phone, err := auth.NormalizePhone(str(body.Phone))
	if err != nil {
		writeError(w, http.StatusBadRequest, "Telefon raqam noto'g'ri")
		return
	}
	ctx := r.Context()

	var last time.Time
	err = s.db.QueryRow(ctx, `select created_at from otp_codes where phone = $1 order by created_at desc limit 1`, phone).Scan(&last)
	if err == nil && time.Since(last) < time.Minute {
		writeError(w, http.StatusTooManyRequests, "1 daqiqadan keyin qayta urinib ko'ring")
		return
	}
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		s.fail(w, "send-code", err)
		return
	}

	var count int
	if err := s.db.QueryRow(ctx, `
		select count(*)::int from otp_codes
		where phone = $1 and created_at > now() - interval '1 hour'`, phone).Scan(&count); err != nil {
		s.fail(w, "send-code", err)
		return
	}
	if count >= 5 {
		writeError(w, http.StatusTooManyRequests, "Juda ko'p urinish. Keyinroq urinib ko'ring")
		return
	}

	code, isTest := s.cfg.TestPhones[phone]
	if !isTest {
		if code, err = randomCode(); err != nil {
			s.fail(w, "send-code", err)
			return
		}
	}

	if _, err := s.db.Exec(ctx, `
		insert into otp_codes (phone, code_hash, expires_at)
		values ($1, $2, now() + interval '5 minutes')`, phone, auth.HashCode(s.cfg.OTPSecret, phone, code)); err != nil {
		s.fail(w, "send-code", err)
		return
	}

	if !isTest {
		if err := s.sms.SendOTP(ctx, phone, code); err != nil {
			log.Printf("send-code SMS: %v", err)
			writeError(w, http.StatusBadGateway, "SMS yuborib bo'lmadi")
			return
		}
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// POST /api/auth/verify  { phone, code } -> { token, user }
func (s *Server) verify(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Phone any `json:"phone"`
		Code  any `json:"code"`
	}
	readJSON(w, r, &body)
	phone, err := auth.NormalizePhone(str(body.Phone))
	if err != nil {
		writeError(w, http.StatusBadRequest, "Telefon raqam noto'g'ri")
		return
	}
	code := strings.TrimSpace(str(body.Code))
	if !sixDigits.MatchString(code) {
		writeError(w, http.StatusBadRequest, "Kod 6 xonali bo'lishi kerak")
		return
	}
	ctx := r.Context()

	var otpID int64
	var codeHash string
	var attempts int
	err = s.db.QueryRow(ctx, `
		select id, code_hash, attempts from otp_codes
		where phone = $1 and used = false and expires_at > now()
		order by created_at desc limit 1`, phone).Scan(&otpID, &codeHash, &attempts)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusBadRequest, "Kod eskirgan. Yangi kod so'rang")
		return
	}
	if err != nil {
		s.fail(w, "verify", err)
		return
	}
	if attempts >= 5 {
		writeError(w, http.StatusTooManyRequests, "Juda ko'p xato. Yangi kod so'rang")
		return
	}
	if !auth.SafeEqual(codeHash, auth.HashCode(s.cfg.OTPSecret, phone, code)) {
		s.db.Exec(ctx, `update otp_codes set attempts = attempts + 1 where id = $1`, otpID)
		writeError(w, http.StatusBadRequest, "Kod noto'g'ri")
		return
	}
	if _, err := s.db.Exec(ctx, `update otp_codes set used = true where id = $1`, otpID); err != nil {
		s.fail(w, "verify", err)
		return
	}

	u, err := scanUser(s.db.QueryRow(ctx, `
		insert into users (phone) values ($1)
		on conflict (phone) do update set phone = excluded.phone
		returning `+userColumns, phone))
	if err != nil {
		s.fail(w, "verify", err)
		return
	}
	if u.Blocked {
		writeError(w, http.StatusForbidden, "ACCOUNT_BLOCKED")
		return
	}
	token, err := auth.SignToken(s.cfg.JWTSecret, u.ID, u.TokenVersion)
	if err != nil {
		s.fail(w, "verify", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"token": token, "user": publicUser(u)})
}

func (s *Server) fail(w http.ResponseWriter, where string, err error) {
	log.Printf("%s: %v", where, err)
	writeError(w, http.StatusInternalServerError, "SERVER_ERROR")
}
