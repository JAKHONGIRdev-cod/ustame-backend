// Package api — HTTP endpointlar. Yo'llar va javob formatlari Node usta-api bilan bir xil,
// shuning uchun mobil ilova o'zgarishsiz ishlaydi.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/JAKHONGIRdev-cod/ustame-backend/internal/auth"
	"github.com/JAKHONGIRdev-cod/ustame-backend/internal/config"
	"github.com/JAKHONGIRdev-cod/ustame-backend/internal/eskiz"
	"github.com/JAKHONGIRdev-cod/ustame-backend/internal/wakeup"
)

const maxBodyBytes = 5 << 20 // rasm (3 MB) base64 ko'rinishida ~4 MB

type Server struct {
	cfg   *config.Config
	db    *pgxpool.Pool
	sms   *eskiz.Client
	funcs *funcCache

	errLimit hourLimiter // POST /api/client-errors cheklovi
	smsLimit hourLimiter // POST /api/auth/send-code: bitta IP'dan soatiga
	smsAlert smsAlert    // kunlik SMS chegarasiga yaqinlashganda adminlarga xabar

	// Outbox — yozuvchi RPC'dan keyin: navbatga bildirishnoma tushgan bo'lishi mumkin.
	// Activity — har qanday RPC'dan keyin: baza hozir uyg'oq (davriy ishlar shu paytda ishlaydi).
	Outbox, Activity *wakeup.Hub
}

func New(cfg *config.Config, db *pgxpool.Pool) *Server {
	return &Server{
		cfg: cfg,
		db:  db,
		sms: &eskiz.Client{
			DB: db, Email: cfg.EskizEmail, Password: cfg.EskizPassword, From: cfg.EskizFrom,
			TestMode: cfg.EskizTestMode, HTTP: &http.Client{Timeout: 20 * time.Second},
		},
		funcs:    &funcCache{},
		smsLimit: hourLimiter{max: smsPerIPPerHour},
	}
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	})
	mux.HandleFunc("POST /api/auth/send-code", s.sendCode)
	mux.HandleFunc("POST /api/auth/verify", s.verify)
	mux.HandleFunc("POST /api/auth/telegram/start", s.telegramStart)
	mux.HandleFunc("POST /api/auth/telegram/check", s.telegramCheck)
	mux.HandleFunc("POST /api/auth/refresh", s.refreshToken)
	mux.HandleFunc("GET /api/me", s.getMe)
	mux.HandleFunc("PATCH /api/me", s.patchMe)
	mux.HandleFunc("POST /api/rpc/{fn}", s.rpc)
	mux.HandleFunc("GET /api/files", s.getFiles)
	mux.HandleFunc("POST /api/files", s.uploadFile)
	mux.HandleFunc("DELETE /api/files", s.deleteFile)
	mux.HandleFunc("POST /api/client-errors", s.clientError)
	return s.cors(recoverer(mux))
}

// --- yordamchilar ---

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, code string) {
	writeJSON(w, status, map[string]string{"error": code})
}

// readJSON so'rov tanasini o'qiydi. Bo'sh tana — xato emas (dst o'zgarmaydi).
func readJSON(w http.ResponseWriter, r *http.Request, dst any) error {
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	dec := json.NewDecoder(r.Body)
	dec.UseNumber()
	err := dec.Decode(dst)
	if errors.Is(err, io.EOF) {
		return nil
	}
	return err
}

func recoverer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if v := recover(); v != nil {
				log.Printf("panic %s %s: %v", r.Method, r.URL.Path, v)
				writeError(w, http.StatusInternalServerError, "SERVER_ERROR")
			}
		}()
		next.ServeHTTP(w, r)
	})
}

func (s *Server) cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if origin != "" && (slices.Contains(s.cfg.AllowedOrigins, "*") || slices.Contains(s.cfg.AllowedOrigins, origin)) {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Vary", "Origin")
			w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE, OPTIONS")
		}
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// --- foydalanuvchi ---

type user struct {
	ID              string     `json:"id"`
	Phone           string     `json:"phone"`
	FullName        string     `json:"full_name"`
	ActiveRole      string     `json:"active_role"`
	CreatedAt       time.Time  `json:"created_at"`
	AvatarUpdatedAt *time.Time `json:"avatar_updated_at"`
	TelegramChatID  *int64     `json:"-"`
	IsAdmin         bool       `json:"is_admin"`
	TokenVersion    int        `json:"-"`
	Blocked         bool       `json:"-"` // admin bloklagan: kira olmaydi
}

const userColumns = `id::text, phone, full_name, active_role, created_at, avatar_updated_at,
	telegram_chat_id, is_admin, token_version, blocked_at is not null`

func scanUser(row pgx.Row) (*user, error) {
	var u user
	err := row.Scan(&u.ID, &u.Phone, &u.FullName, &u.ActiveRole, &u.CreatedAt, &u.AvatarUpdatedAt,
		&u.TelegramChatID, &u.IsAdmin, &u.TokenVersion, &u.Blocked)
	if err != nil {
		return nil, err
	}
	return &u, nil
}

// publicUser — ilovadagi Me turiga mos ko'rinish (lib/user.js bilan bir xil).
func publicUser(u *user) map[string]any {
	return map[string]any{
		"id": u.ID, "phone": u.Phone, "full_name": u.FullName, "active_role": u.ActiveRole,
		"created_at": u.CreatedAt, "avatar_updated_at": u.AvatarUpdatedAt,
		"telegram_linked": u.TelegramChatID != nil, "is_admin": u.IsAdmin, "provider": nil,
	}
}

// tokenUser: Bearer tokendagi foydalanuvchi id va token_version (bazaga bormasdan, faqat imzo/muddat).
// Token bekor qilinmaganini (token_version) chaqiruvchi bazada tekshirishi shart.
func (s *Server) tokenUser(r *http.Request) (id string, tv int, ok bool) {
	token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok {
		return "", 0, false
	}
	id, tv, err := auth.ParseToken(s.cfg.JWTSecret, token)
	if err != nil {
		return "", 0, false
	}
	return id, tv, true
}

// requireUser: Bearer token -> users qatori. Token yo'q/noto'g'ri/eskirgan yoki
// token_version mos kelmasa (bekor qilingan) — nil.
func (s *Server) requireUser(ctx context.Context, r *http.Request) *user {
	id, tv, ok := s.tokenUser(r)
	if !ok {
		return nil
	}
	// id::text = $1 emas: ustunni o'zgartirsak indeks ishlamaydi va butun jadval o'qiladi
	u, err := scanUser(s.db.QueryRow(ctx, `select `+userColumns+` from users where id = $1::uuid`, id))
	if err != nil {
		if !errors.Is(err, pgx.ErrNoRows) {
			log.Printf("requireUser: %v", err)
		}
		return nil
	}
	if u.TokenVersion != tv || u.Blocked {
		return nil
	}
	return u
}
