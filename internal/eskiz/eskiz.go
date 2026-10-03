// Package eskiz — Eskiz.uz orqali SMS yuborish. Token bazadagi app_settings ('eskiz_token')
// jadvalida 25 kun saqlanadi; 401 kelsa bir marta qayta kiriladi.
package eskiz

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"mime/multipart"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	baseURL  = "https://notify.eskiz.uz/api"
	tokenTTL = 25 * 24 * time.Hour
)

type Client struct {
	DB       *pgxpool.Pool
	Email    string
	Password string
	From     string
	TestMode bool
	HTTP     *http.Client
}

func form(fields map[string]string) (*bytes.Buffer, string) {
	var buf bytes.Buffer
	w := multipart.NewWriter(&buf)
	for k, v := range fields {
		w.WriteField(k, v)
	}
	w.Close()
	return &buf, w.FormDataContentType()
}

func (c *Client) login(ctx context.Context) (string, error) {
	body, ct := form(map[string]string{"email": c.Email, "password": c.Password})
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+"/auth/login", body)
	req.Header.Set("Content-Type", ct)
	res, err := c.HTTP.Do(req)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	var out struct {
		Data struct {
			Token string `json:"token"`
		} `json:"data"`
	}
	raw, _ := io.ReadAll(res.Body)
	if err := json.Unmarshal(raw, &out); err != nil || res.StatusCode != http.StatusOK || out.Data.Token == "" {
		return "", fmt.Errorf("Eskiz login xato (%d): %s", res.StatusCode, raw)
	}
	_, err = c.DB.Exec(ctx, `
		insert into app_settings (key, value, updated_at) values ('eskiz_token', $1, now())
		on conflict (key) do update set value = excluded.value, updated_at = now()`, out.Data.Token)
	return out.Data.Token, err
}

func (c *Client) token(ctx context.Context, force bool) (string, error) {
	if !force {
		var value string
		var updated time.Time
		err := c.DB.QueryRow(ctx, `select value, updated_at from app_settings where key = 'eskiz_token'`).Scan(&value, &updated)
		if err == nil && time.Since(updated) < tokenTTL {
			return value, nil
		}
		if err != nil && err != pgx.ErrNoRows {
			return "", err
		}
	}
	return c.login(ctx)
}

func (c *Client) post(ctx context.Context, token, phone, message string) (int, string, error) {
	body, ct := form(map[string]string{"mobile_phone": phone, "message": message, "from": c.From})
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+"/message/sms/send", body)
	req.Header.Set("Content-Type", ct)
	req.Header.Set("Authorization", "Bearer "+token)
	res, err := c.HTTP.Do(req)
	if err != nil {
		return 0, "", err
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(res.Body)
	return res.StatusCode, string(raw), nil
}

// SendOTP kodni SMS bilan yuboradi. Test rejimida Eskiz faqat "Bu Eskiz dan test" matnini
// qabul qiladi — kod server logiga yoziladi.
func (c *Client) SendOTP(ctx context.Context, phone, code string) error {
	var message string
	if c.TestMode {
		message = "Bu Eskiz dan test"
		log.Printf("TEST REJIM - %s uchun OTP: %s", phone, code)
	} else {
		// Eskiz'da moderatsiyadan o'tgan matn bilan harfma-harf bir xil bo'lsin
		message = fmt.Sprintf("Ustago: tasdiqlash kodingiz %s. Kodni hech kimga bermang.", code)
	}

	tok, err := c.token(ctx, false)
	if err != nil {
		return err
	}
	status, body, err := c.post(ctx, tok, phone, message)
	if err == nil && status == http.StatusUnauthorized {
		if tok, err = c.token(ctx, true); err == nil {
			status, body, err = c.post(ctx, tok, phone, message)
		}
	}
	if err != nil {
		return err
	}
	if status < 200 || status >= 300 {
		return fmt.Errorf("Eskiz SMS xato (%d): %s", status, body)
	}
	return nil
}
