// Package auth: telefon raqami, OTP kod xeshi va JWT. Formatlar Node usta-api bilan bir xil,
// shuning uchun eski tokenlar va bazadagi kod xeshlari ishlashda davom etadi.
package auth

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"regexp"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const tokenTTL = 30 * 24 * time.Hour

var nonDigit = regexp.MustCompile(`\D`)

// NormalizePhone: "90 123 45 67", "+998901234567" -> "998901234567"
func NormalizePhone(input string) (string, error) {
	d := nonDigit.ReplaceAllString(input, "")
	switch {
	case len(d) == 9:
		return "998" + d, nil
	case len(d) == 12 && strings.HasPrefix(d, "998"):
		return d, nil
	}
	return "", errors.New("invalid phone")
}

// HashCode — HMAC-SHA256(OTP_SECRET, "phone:code"), hex.
func HashCode(secret []byte, phone, code string) string {
	m := hmac.New(sha256.New, secret)
	m.Write([]byte(phone + ":" + code))
	return hex.EncodeToString(m.Sum(nil))
}

func SafeEqual(a, b string) bool {
	return hmac.Equal([]byte(a), []byte(b))
}

type claims struct {
	TV int `json:"tv"`
	jwt.RegisteredClaims
}

// SignToken — HS256, sub = user id, tv = users.token_version, 30 kun.
func SignToken(secret []byte, userID string, tokenVersion int) (string, error) {
	now := time.Now()
	return jwt.NewWithClaims(jwt.SigningMethodHS256, claims{
		TV: tokenVersion,
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   userID,
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(tokenTTL)),
		},
	}).SignedString(secret)
}

// ParseToken tokenni tekshiradi va (user id, token_version) qaytaradi.
func ParseToken(secret []byte, token string) (string, int, error) {
	var c claims
	_, err := jwt.ParseWithClaims(token, &c, func(*jwt.Token) (any, error) { return secret, nil },
		jwt.WithValidMethods([]string{"HS256"}), jwt.WithExpirationRequired())
	if err != nil {
		return "", 0, err
	}
	if c.Subject == "" {
		return "", 0, errors.New("no sub")
	}
	return c.Subject, c.TV, nil
}
