// Package config muhit o'zgaruvchilarini o'qiydi. Lokal ishga tushirishda .env.local / .env
// fayllaridan ham yuklaydi (Railway'da o'zgaruvchilar to'g'ridan-to'g'ri beriladi).
package config

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
)

type Config struct {
	Port          string
	DatabaseURL   string
	JWTSecret     []byte
	OTPSecret     []byte
	EskizEmail    string
	EskizPassword string
	EskizFrom     string
	EskizTestMode bool
	// TEST_PHONES="998901112233:123456,..." — bu raqamlarga SMS ketmaydi, kod shu yerdan olinadi
	TestPhones map[string]string
	// TELEGRAM_BOT_TOKEN — bo'sh bo'lsa bildirishnomalar boti ishga tushmaydi.
	// Faqat bitta joyda (Railway) bering: ikki nusxa bir token bilan ishlasa Telegram 409 qaytaradi.
	TelegramBotToken string
	// EXPO_ACCESS_TOKEN — ixtiyoriy: faqat Expo'da "enhanced push security" yoqilsa kerak.
	ExpoAccessToken string
	// Web-sayt manzillari (CORS). "*" — hammasiga ruxsat (faqat lokal sinov uchun).
	AllowedOrigins []string
	// SMS_DAILY_LIMIT — 24 soatda yuboriladigan kod SMS'lari chegarasi (test raqamlarsiz). Bot ko'p
	// raqamga kod so'rab Eskiz balansini bo'shatmasligi uchun; yetganda faqat Telegram orqali kirish qoladi.
	SMSDailyLimit int
}

func Load() (*Config, error) {
	loadDotenv(".env.local")
	loadDotenv(".env")

	c := &Config{
		Port:          getenv("PORT", "8080"),
		DatabaseURL:   os.Getenv("DATABASE_URL"),
		JWTSecret:     []byte(os.Getenv("JWT_SECRET")),
		OTPSecret:     []byte(os.Getenv("OTP_SECRET")),
		EskizEmail:    os.Getenv("ESKIZ_EMAIL"),
		EskizPassword: os.Getenv("ESKIZ_PASSWORD"),
		EskizFrom:     getenv("ESKIZ_FROM", "4546"),
		EskizTestMode: os.Getenv("ESKIZ_TEST_MODE") == "true",
		TestPhones:    parseTestPhones(os.Getenv("TEST_PHONES")),

		TelegramBotToken: os.Getenv("TELEGRAM_BOT_TOKEN"),
		ExpoAccessToken:  os.Getenv("EXPO_ACCESS_TOKEN"),
		SMSDailyLimit:    300,
	}
	if v := os.Getenv("SMS_DAILY_LIMIT"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			c.SMSDailyLimit = n
		}
	}
	for _, o := range strings.Split(os.Getenv("ALLOWED_ORIGINS"), ",") {
		if o = strings.TrimSpace(o); o != "" {
			c.AllowedOrigins = append(c.AllowedOrigins, o)
		}
	}

	var missing []string
	for name, v := range map[string]string{
		"DATABASE_URL": c.DatabaseURL,
		"JWT_SECRET":   string(c.JWTSecret),
		"OTP_SECRET":   string(c.OTPSecret),
	} {
		if v == "" {
			missing = append(missing, name)
		}
	}
	if len(missing) > 0 {
		return nil, fmt.Errorf("muhit o'zgaruvchilari yo'q: %s", strings.Join(missing, ", "))
	}
	return c, nil
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func parseTestPhones(s string) map[string]string {
	m := map[string]string{}
	for _, item := range strings.Split(s, ",") {
		phone, code, ok := strings.Cut(strings.TrimSpace(item), ":")
		if ok && phone != "" && code != "" {
			m[phone] = code
		}
	}
	return m
}

// loadDotenv KEY=VALUE qatorlarini o'qiydi; muhitda allaqachon bor o'zgaruvchilar ustidan yozmaydi.
func loadDotenv(path string) {
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(strings.TrimPrefix(sc.Text(), "\uFEFF"))
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, val, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key = strings.TrimSpace(strings.TrimPrefix(key, "export "))
		val = strings.TrimSpace(val)
		if len(val) >= 2 && (val[0] == '"' || val[0] == '\'') && val[len(val)-1] == val[0] {
			val = val[1 : len(val)-1]
		}
		if _, exists := os.LookupEnv(key); !exists {
			os.Setenv(key, val)
		}
	}
}
