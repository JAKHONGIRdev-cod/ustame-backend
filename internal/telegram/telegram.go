// Package telegram — bildirishnomalar boti: foydalanuvchi profilini botga ulaydi
// ("/start <kod>") va notification_outbox jadvalidagi xabarlarni Telegram'ga yuboradi.
package telegram

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
)

// Client — Telegram Bot API'ning bizga kerakli qismi.
type Client struct {
	Token   string
	BaseURL string // bo'sh bo'lsa https://api.telegram.org (testlarda soxta server beriladi)
	HTTP    *http.Client
}

// APIError — Telegram "ok": false qaytargan holat.
type APIError struct {
	Code        int
	Description string
	RetryAfter  int
}

func (e *APIError) Error() string {
	return fmt.Sprintf("telegram %d: %s", e.Code, e.Description)
}

type Update struct {
	UpdateID   int64       `json:"update_id"`
	Message    *Message    `json:"message"`
	PollAnswer *PollAnswer `json:"poll_answer"` // so'rovnomadagi ovoz (faqat nomi oshkor poll'lar)
}

// PollAnswer — foydalanuvchi poll'da variant tanladi (OptionIDs bo'sh — ovozini qaytarib oldi).
type PollAnswer struct {
	PollID    string  `json:"poll_id"`
	User      *Sender `json:"user"`
	OptionIDs []int   `json:"option_ids"`
}

type Message struct {
	Text string `json:"text"`
	Chat struct {
		ID   int64  `json:"id"`
		Type string `json:"type"` // "private", "group", ...
	} `json:"chat"`
	From    *Sender  `json:"from"`
	Contact *Contact `json:"contact"`
}

type Sender struct {
	ID int64 `json:"id"`
}

// Contact — "Raqamni yuborish" tugmasi yoki ulashilgan kontakt. UserID — kontakt egasining
// Telegram id'si; o'z raqamini yuborganda u xabar yuboruvchining id'siga teng bo'ladi.
type Contact struct {
	PhoneNumber string `json:"phone_number"`
	UserID      int64  `json:"user_id"`
}

type User struct {
	Username string `json:"username"`
}

func (c *Client) call(ctx context.Context, method string, params any, out any) error {
	body, err := json.Marshal(params)
	if err != nil {
		return err
	}
	base := c.BaseURL
	if base == "" {
		base = "https://api.telegram.org"
	}
	endpoint := base + "/bot" + url.PathEscape(c.Token) + "/" + method
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.HTTP.Do(req)
	if err != nil {
		// Xato matnida URL (va unda token) bo'lmasin
		return fmt.Errorf("telegram %s: so'rov bajarilmadi", method)
	}
	defer resp.Body.Close()

	var res struct {
		OK          bool            `json:"ok"`
		Result      json.RawMessage `json:"result"`
		ErrorCode   int             `json:"error_code"`
		Description string          `json:"description"`
		Parameters  struct {
			RetryAfter int `json:"retry_after"`
		} `json:"parameters"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&res); err != nil {
		return fmt.Errorf("telegram %s: javobni o'qib bo'lmadi (HTTP %d)", method, resp.StatusCode)
	}
	if !res.OK {
		code := res.ErrorCode
		if code == 0 {
			code = resp.StatusCode
		}
		return &APIError{Code: code, Description: res.Description, RetryAfter: res.Parameters.RetryAfter}
	}
	if out != nil {
		return json.Unmarshal(res.Result, out)
	}
	return nil
}

func (c *Client) GetMe(ctx context.Context) (*User, error) {
	var u User
	if err := c.call(ctx, "getMe", struct{}{}, &u); err != nil {
		return nil, err
	}
	return &u, nil
}

// GetUpdates — long polling: yangi xabar bo'lmasa timeout soniyagacha kutadi.
func (c *Client) GetUpdates(ctx context.Context, offset int64, timeout int) ([]Update, error) {
	var ups []Update
	err := c.call(ctx, "getUpdates", map[string]any{
		"offset": offset, "timeout": timeout, "allowed_updates": []string{"message", "poll_answer"},
	}, &ups)
	return ups, err
}

func (c *Client) SendMessage(ctx context.Context, chatID int64, text string) error {
	return c.SendMessageMarkup(ctx, chatID, text, nil)
}

// SendMessageMarkup — xabar va klaviatura (reply_markup); markup nil bo'lsa oddiy xabar.
func (c *Client) SendMessageMarkup(ctx context.Context, chatID int64, text string, markup any) error {
	params := map[string]any{"chat_id": chatID, "text": text, "disable_web_page_preview": true}
	if markup != nil {
		params["reply_markup"] = markup
	}
	return c.call(ctx, "sendMessage", params, nil)
}

// BotTexts — botning profil matnlari: description — bo'sh chatda «START» tugmasi ustida ko'rinadi,
// short — bot profilida va ulashilganda.
type BotTexts struct {
	Lang        string // "" — standart (boshqa barcha tillar)
	Description string
	Short       string
}

// EnsureTexts — matnlar farq qilsagina o'rnatadi (setMy* tez-tez chaqirilsa Telegram 429 qaytaradi).
func (c *Client) EnsureTexts(ctx context.Context, t BotTexts) error {
	var desc struct {
		Description string `json:"description"`
	}
	if err := c.call(ctx, "getMyDescription", map[string]any{"language_code": t.Lang}, &desc); err != nil {
		return err
	}
	if desc.Description != t.Description {
		if err := c.call(ctx, "setMyDescription",
			map[string]any{"description": t.Description, "language_code": t.Lang}, nil); err != nil {
			return err
		}
	}
	var short struct {
		ShortDescription string `json:"short_description"`
	}
	if err := c.call(ctx, "getMyShortDescription", map[string]any{"language_code": t.Lang}, &short); err != nil {
		return err
	}
	if short.ShortDescription != t.Short {
		return c.call(ctx, "setMyShortDescription",
			map[string]any{"short_description": t.Short, "language_code": t.Lang}, nil)
	}
	return nil
}

// SendPoll — nomi oshkor (is_anonymous: false) so'rovnoma: javoblar poll_answer bilan keladi. Poll id qaytaradi.
func (c *Client) SendPoll(ctx context.Context, chatID int64, question string, options []string, multi bool) (string, error) {
	opts := make([]map[string]string, len(options))
	for i, o := range options {
		opts[i] = map[string]string{"text": o}
	}
	var msg struct {
		Poll struct {
			ID string `json:"id"`
		} `json:"poll"`
	}
	err := c.call(ctx, "sendPoll", map[string]any{
		"chat_id": chatID, "question": question, "options": opts,
		"is_anonymous": false, "allows_multiple_answers": multi,
	}, &msg)
	return msg.Poll.ID, err
}
