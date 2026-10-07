// Package push — notification_outbox'dagi xabarlarni telefonlarga Expo Push Service orqali
// yuboradi (Android'da FCM, iOS'da APNs Expo tomonidan ulanadi). Telegram'dan mustaqil ishlaydi.
package push

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
)

const defaultURL = "https://exp.host/--/api/v2/push/send"

// Client — Expo Push API'ning bizga kerakli qismi.
type Client struct {
	URL         string // bo'sh bo'lsa Expo'ning manzili (testlarda soxta server beriladi)
	AccessToken string // ixtiyoriy: Expo'da "enhanced push security" yoqilgan bo'lsa
	HTTP        *http.Client
}

// ExpoMessage — bitta telefonga bitta bildirishnoma.
type ExpoMessage struct {
	To        string            `json:"to"`
	Title     string            `json:"title"`
	Body      string            `json:"body"`
	Data      map[string]string `json:"data,omitempty"`
	Sound     string            `json:"sound"`
	ChannelID string            `json:"channelId"` // ilovadagi Android kanali (src/lib/push.ts)
	Priority  string            `json:"priority"`
}

// Ticket — Expo'ning har bir xabarga javobi (yuborilgan tartibda).
type Ticket struct {
	Status  string `json:"status"` // "ok" | "error"
	Message string `json:"message"`
	Details struct {
		Error string `json:"error"` // masalan "DeviceNotRegistered"
	} `json:"details"`
}

// HTTPError — Expo butun so'rovni rad etdi (5xx, 429 va h.k.).
type HTTPError struct {
	Status int
	Body   string
}

func (e *HTTPError) Error() string { return fmt.Sprintf("expo push %d: %s", e.Status, e.Body) }

// Send — 100 tagacha xabarni bitta so'rovda yuboradi.
func (c *Client) Send(ctx context.Context, msgs []ExpoMessage) ([]Ticket, error) {
	body, err := json.Marshal(msgs)
	if err != nil {
		return nil, err
	}
	url := c.URL
	if url == "" {
		url = defaultURL
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	if c.AccessToken != "" {
		req.Header.Set("Authorization", "Bearer "+c.AccessToken)
	}
	res, err := c.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if res.StatusCode != http.StatusOK {
		return nil, &HTTPError{Status: res.StatusCode, Body: string(raw)}
	}
	var out struct {
		Data []Ticket `json:"data"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, fmt.Errorf("expo push javobi o'qilmadi: %w", err)
	}
	if len(out.Data) != len(msgs) {
		return nil, fmt.Errorf("expo push: %d ta xabarga %d ta javob keldi", len(msgs), len(out.Data))
	}
	return out.Data, nil
}
