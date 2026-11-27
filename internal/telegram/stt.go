package telegram

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/url"
	"strings"
)

// Transcriber — ovozli xabarni matnga aylantiradi (nutqni aniqlash, STT).
type Transcriber interface {
	Transcribe(ctx context.Context, audio []byte, filename string) (string, error)
}

// OpenAISTT — OpenAI'ning /v1/audio/transcriptions so'roviga mos har qanday xizmat (OpenAI, Groq va boshqalar):
// manzil va model sozlamadan olinadi (STT_URL, STT_MODEL), shuning uchun xizmatni kodni o'zgartirmasdan almashtirish mumkin.
type OpenAISTT struct {
	APIKey   string
	URL      string // bo'sh bo'lsa https://api.openai.com/v1/audio/transcriptions
	Model    string // bo'sh bo'lsa gpt-4o-transcribe
	Language string // ISO-639-1, bo'sh bo'lsa "uz"
	HTTP     *http.Client
}

func (s *OpenAISTT) Transcribe(ctx context.Context, audio []byte, filename string) (string, error) {
	endpoint := cmpOr(s.URL, "https://api.openai.com/v1/audio/transcriptions")
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	fw, err := mw.CreateFormFile("file", filename)
	if err != nil {
		return "", err
	}
	if _, err := fw.Write(audio); err != nil {
		return "", err
	}
	_ = mw.WriteField("model", cmpOr(s.Model, "gpt-4o-transcribe"))
	_ = mw.WriteField("language", cmpOr(s.Language, "uz"))
	_ = mw.WriteField("response_format", "json")
	if err := mw.Close(); err != nil {
		return "", err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, &body)
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("Authorization", "Bearer "+s.APIKey)
	resp, err := s.HTTP.Do(req)
	if err != nil {
		return "", fmt.Errorf("stt: so'rov bajarilmadi: %w", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("stt: HTTP %d: %s", resp.StatusCode, truncate(string(raw), 300))
	}
	var res struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal(raw, &res); err != nil {
		return "", fmt.Errorf("stt: javobni o'qib bo'lmadi")
	}
	return strings.TrimSpace(res.Text), nil
}

// STTProviderName — foydalanuvchiga aytiladigan xizmat nomi (ovoz qayerga yuborilishi) STT_URL bo'yicha
func STTProviderName(endpoint string) string {
	switch {
	case endpoint == "" || strings.Contains(endpoint, "openai.com"):
		return "OpenAI"
	case strings.Contains(endpoint, "groq.com"):
		return "Groq"
	}
	if u, err := url.Parse(endpoint); err == nil && u.Hostname() != "" {
		return u.Hostname()
	}
	return "tashqi"
}

func cmpOr(v, def string) string {
	if v == "" {
		return def
	}
	return v
}

func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "…"
}
