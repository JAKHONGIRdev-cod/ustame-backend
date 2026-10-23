package api

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"net/http"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/JAKHONGIRdev-cod/ustame-backend/internal/auth"
)

// Telegram orqali kirish (bot va jadval: internal/telegram, sql/01-telegram-login.sql).
const (
	telegramLoginTTLSeconds = 600 // havola 10 daqiqa amal qiladi
	telegramStartsPerMinute = 300 // butun server bo'yicha cheklov (suiiste'moldan himoya)
)

func randomBytes(n int) ([]byte, error) {
	b := make([]byte, n)
	_, err := rand.Read(b)
	return b, err
}

func hashSecret(secret string) string {
	sum := sha256.Sum256([]byte(secret))
	return hex.EncodeToString(sum[:])
}

// POST /api/auth/telegram/start -> { url, secret, expires_in }
// url — botni ochadi; secret — faqat ilovada qoladi va check'da ishlatiladi.
func (s *Server) telegramStart(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	var bot *string
	err := s.db.QueryRow(ctx, `select telegram_bot_username from app_secrets where id = 1`).Scan(&bot)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		s.fail(w, "telegram-start", err)
		return
	}
	if bot == nil || *bot == "" {
		writeError(w, http.StatusServiceUnavailable, "TELEGRAM_NOT_CONFIGURED")
		return
	}

	var recent int
	if err := s.db.QueryRow(ctx, `
		select count(*)::int from telegram_logins where created_at > now() - interval '1 minute'`).Scan(&recent); err != nil {
		s.fail(w, "telegram-start", err)
		return
	}
	if recent >= telegramStartsPerMinute {
		writeError(w, http.StatusTooManyRequests, "Juda ko'p urinish. Keyinroq urinib ko'ring")
		return
	}

	codeBytes, err := randomBytes(16)
	if err != nil {
		s.fail(w, "telegram-start", err)
		return
	}
	secretBytes, err := randomBytes(32)
	if err != nil {
		s.fail(w, "telegram-start", err)
		return
	}
	code := hex.EncodeToString(codeBytes)
	secret := base64.RawURLEncoding.EncodeToString(secretBytes)

	if _, err := s.db.Exec(ctx, `
		insert into telegram_logins (start_code, secret_hash, expires_at)
		values ($1, $2, now() + make_interval(secs => $3))`, code, hashSecret(secret), telegramLoginTTLSeconds); err != nil {
		s.fail(w, "telegram-start", err)
		return
	}
	// Eski yozuvlarni tozalaymiz (indeks bor, arzon)
	s.db.Exec(ctx, `delete from telegram_logins where created_at < now() - interval '1 day'`)

	writeJSON(w, http.StatusOK, map[string]any{
		"url":        "https://t.me/" + *bot + "?start=login_" + code,
		"secret":     secret,
		"expires_in": telegramLoginTTLSeconds,
	})
}

// POST /api/auth/telegram/check { secret } -> { status: "pending" } yoki { status: "ok", token, user }.
// Muddati o'tgan, ishlatilgan yoki noma'lum secret — 400 LOGIN_EXPIRED.
func (s *Server) telegramCheck(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Secret any `json:"secret"`
	}
	readJSON(w, r, &body)
	secret := strings.TrimSpace(str(body.Secret))
	if secret == "" || len(secret) > 100 {
		writeError(w, http.StatusBadRequest, "LOGIN_EXPIRED")
		return
	}
	ctx := r.Context()

	tx, err := s.db.Begin(ctx)
	if err != nil {
		s.fail(w, "telegram-check", err)
		return
	}
	defer tx.Rollback(ctx)

	var (
		id                          int64
		phone                       *string
		chatID                      *int64
		used, expired, claimExpired bool
	)
	// Raqam muddat ichida tasdiqlangan bo'lsa, ilova tokenni yana 5 daqiqa ichida olishi mumkin
	err = tx.QueryRow(ctx, `
		select id, phone, chat_id, used_at is not null,
		       expires_at <= now(), expires_at + interval '5 minutes' <= now()
		from telegram_logins where secret_hash = $1
		for update`, hashSecret(secret)).Scan(&id, &phone, &chatID, &used, &expired, &claimExpired)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusBadRequest, "LOGIN_EXPIRED")
		return
	}
	if err != nil {
		s.fail(w, "telegram-check", err)
		return
	}
	switch {
	case used, phone == nil && expired, phone != nil && claimExpired:
		writeError(w, http.StatusBadRequest, "LOGIN_EXPIRED")
		return
	case phone == nil:
		writeJSON(w, http.StatusOK, map[string]string{"status": "pending"})
		return
	}

	if _, err := tx.Exec(ctx, `update telegram_logins set used_at = now() where id = $1`, id); err != nil {
		s.fail(w, "telegram-check", err)
		return
	}
	u, err := scanUser(tx.QueryRow(ctx, `
		insert into users (phone) values ($1)
		on conflict (phone) do update set phone = excluded.phone
		returning `+userColumns, *phone))
	if err != nil {
		s.fail(w, "telegram-check", err)
		return
	}
	if u.Blocked {
		// Kirish havolasi ishlatilgan deb belgilanadi, lekin token berilmaydi va Telegram ulanmaydi
		if err := tx.Commit(ctx); err != nil {
			s.fail(w, "telegram-check", err)
			return
		}
		writeError(w, http.StatusForbidden, "ACCOUNT_BLOCKED")
		return
	}
	// Bildirishnomalar ham shu Telegram'ga keladi (telegram_chat_id unikal: boshqa profildan uziladi)
	if chatID != nil {
		if _, err := tx.Exec(ctx, `update users set telegram_chat_id = null where telegram_chat_id = $1 and id::text <> $2`,
			*chatID, u.ID); err != nil {
			s.fail(w, "telegram-check", err)
			return
		}
		if _, err := tx.Exec(ctx, `update users set telegram_chat_id = $1 where id = $2::uuid`, *chatID, u.ID); err != nil {
			s.fail(w, "telegram-check", err)
			return
		}
		// Raqami shu chat'dan tasdiqlandi: keyingi kirishlarda bot raqamni qayta so'ramaydi (internal/telegram)
		if _, err := tx.Exec(ctx, `
			update users set telegram_login_chat_id = case when id = $2::uuid then $1::bigint end
			where id = $2::uuid or telegram_login_chat_id = $1::bigint`, *chatID, u.ID); err != nil {
			s.fail(w, "telegram-check", err)
			return
		}
		u.TelegramChatID = chatID
	}
	if err := tx.Commit(ctx); err != nil {
		s.fail(w, "telegram-check", err)
		return
	}

	token, err := auth.SignToken(s.cfg.JWTSecret, u.ID, u.TokenVersion)
	if err != nil {
		s.fail(w, "telegram-check", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "token": token, "user": publicUser(u)})
}
