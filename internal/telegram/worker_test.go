package telegram

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeTG — Telegram Bot API o'rnida: sendMessage chaqiruvlarini yozib oladi,
// chat_id bo'yicha oldindan berilgan xatoni qaytaradi.
type fakeTG struct {
	mu      sync.Mutex
	sent    []sentMsg
	markups []any            // har bir yuborilgan xabarning reply_markup'i (yo'q bo'lsa nil)
	errFor  map[int64]string // chat_id -> butun JSON javob
}

type sentMsg struct {
	ChatID int64
	Text   string
}

func (f *fakeTG) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	var p map[string]any
	json.NewDecoder(r.Body).Decode(&p)
	switch {
	case strings.HasSuffix(r.URL.Path, "/sendMessage"):
		chat := int64(p["chat_id"].(float64))
		f.mu.Lock()
		defer f.mu.Unlock()
		if body, ok := f.errFor[chat]; ok {
			w.Write([]byte(body))
			return
		}
		f.sent = append(f.sent, sentMsg{chat, p["text"].(string)})
		f.markups = append(f.markups, p["reply_markup"])
		w.Write([]byte(`{"ok":true,"result":{}}`))
	case strings.HasSuffix(r.URL.Path, "/getMe"):
		w.Write([]byte(`{"ok":true,"result":{"username":"UstameTestBot"}}`))
	default:
		w.Write([]byte(`{"ok":false,"error_code":404,"description":"Not Found"}`))
	}
}

type fakeStore struct {
	codes    map[string]bool // haqiqiy kodlar
	linked   map[int64]bool
	unlinked []int64
	queue    []Notification
	released []int64
	username string

	loginCodes map[string]bool  // kutilayotgan kirishlar (start_code)
	loginChats map[int64]bool   // /start login_ bosilgan chatlar
	verified   map[int64]string // chat -> tasdiqlangan raqam
}

func (s *fakeStore) BeginLogin(_ context.Context, code string, chat int64) (bool, error) {
	if !s.loginCodes[code] {
		return false, nil
	}
	s.loginChats[chat] = true
	return true, nil
}

func (s *fakeStore) CompleteLogin(_ context.Context, chat int64, phone string) (bool, error) {
	if !s.loginChats[chat] {
		return false, nil
	}
	delete(s.loginChats, chat)
	s.verified[chat] = phone
	return true, nil
}

func (s *fakeStore) SaveBotUsername(_ context.Context, u string) error { s.username = u; return nil }
func (s *fakeStore) LastUpdateID(context.Context) (int64, error)       { return 0, nil }
func (s *fakeStore) SaveLastUpdateID(context.Context, int64) error     { return nil }
func (s *fakeStore) LinkChat(_ context.Context, code string, chat int64) (bool, error) {
	if !s.codes[code] {
		return false, nil
	}
	s.linked[chat] = true
	return true, nil
}
func (s *fakeStore) UnlinkChat(_ context.Context, chat int64) error {
	s.unlinked = append(s.unlinked, chat)
	return nil
}
func (s *fakeStore) ClaimNotifications(context.Context, int) ([]Notification, error) {
	q := s.queue
	s.queue = nil
	return q, nil
}
func (s *fakeStore) ReleaseNotification(_ context.Context, id int64) error {
	s.released = append(s.released, id)
	return nil
}

func newTest(t *testing.T) (*Worker, *fakeTG, *fakeStore) {
	tg := &fakeTG{errFor: map[int64]string{}}
	srv := httptest.NewServer(tg)
	t.Cleanup(srv.Close)
	st := &fakeStore{codes: map[string]bool{}, linked: map[int64]bool{},
		loginCodes: map[string]bool{}, loginChats: map[int64]bool{}, verified: map[int64]string{}}
	w := &Worker{TG: &Client{Token: "123:SECRET", BaseURL: srv.URL, HTTP: srv.Client()}, Store: st}
	w.defaults()
	return w, tg, st
}

func update(chat int64, text string) Update {
	m := &Message{Text: text}
	m.Chat.ID = chat
	return Update{UpdateID: 1, Message: m}
}

func chat(id int64) *int64 { return &id }

func TestStartLinksChat(t *testing.T) {
	w, tg, st := newTest(t)
	st.codes["abc123"] = true

	w.handleUpdate(context.Background(), update(10, "/start abc123"))
	w.handleUpdate(context.Background(), update(11, "/start eskikod"))
	w.handleUpdate(context.Background(), update(12, "salom"))

	if !st.linked[10] || st.linked[11] {
		t.Fatalf("linked = %v, faqat 10 ulanishi kerak edi", st.linked)
	}
	want := []sentMsg{{10, msgLinked}, {11, msgBadCode}, {12, msgHello}}
	if len(tg.sent) != len(want) {
		t.Fatalf("yuborilgan: %v", tg.sent)
	}
	for i := range want {
		if tg.sent[i] != want[i] {
			t.Errorf("%d: %v, kutilgan %v", i, tg.sent[i], want[i])
		}
	}
}

func TestStartWithBotSuffixAndStop(t *testing.T) {
	w, _, st := newTest(t)
	st.codes["k"] = true
	w.handleUpdate(context.Background(), update(20, "/start@UstameTestBot k"))
	w.handleUpdate(context.Background(), update(20, "/stop"))
	if !st.linked[20] || len(st.unlinked) != 1 || st.unlinked[0] != 20 {
		t.Fatalf("linked=%v unlinked=%v", st.linked, st.unlinked)
	}
}

func TestDeliver(t *testing.T) {
	w, tg, st := newTest(t)
	tg.errFor[2] = `{"ok":false,"error_code":403,"description":"Forbidden: bot was blocked by the user"}`
	tg.errFor[3] = `{"ok":false,"error_code":500,"description":"Internal Server Error"}`
	tg.errFor[4] = `{"ok":false,"error_code":500,"description":"Internal Server Error"}`
	now := time.Now()
	st.queue = []Notification{
		{ID: 1, ChatID: chat(1), Text: "a", CreatedAt: now},
		{ID: 2, ChatID: nil, Text: "ulanmagan", CreatedAt: now},
		{ID: 3, ChatID: chat(2), Text: "bloklagan", CreatedAt: now},
		{ID: 4, ChatID: chat(3), Text: "vaqtinchalik xato", CreatedAt: now},
		{ID: 5, ChatID: chat(4), Text: "eski", CreatedAt: now.Add(-48 * time.Hour)},
	}

	wait := w.deliverOnce(context.Background())

	if len(tg.sent) != 1 || tg.sent[0] != (sentMsg{1, "a"}) {
		t.Errorf("yuborilgan: %v", tg.sent)
	}
	if len(st.unlinked) != 1 || st.unlinked[0] != 2 {
		t.Errorf("uzilgan: %v (bloklagan chat 2 uzilishi kerak)", st.unlinked)
	}
	if len(st.released) != 1 || st.released[0] != 4 {
		t.Errorf("qaytarilgan: %v (faqat 4-xabar qayta urinilishi kerak)", st.released)
	}
	if wait != w.RetryDelay {
		t.Errorf("wait = %v", wait)
	}
}

func TestDeliverRateLimited(t *testing.T) {
	w, tg, st := newTest(t)
	tg.errFor[7] = `{"ok":false,"error_code":429,"description":"Too Many Requests","parameters":{"retry_after":9}}`
	st.queue = []Notification{
		{ID: 1, ChatID: chat(6), Text: "ok", CreatedAt: time.Now()},
		{ID: 2, ChatID: chat(7), Text: "429", CreatedAt: time.Now()},
		{ID: 3, ChatID: chat(6), Text: "keyingi", CreatedAt: time.Now()},
	}
	wait := w.deliverOnce(context.Background())
	if wait != 9*time.Second {
		t.Errorf("wait = %v, 9s kutilgan", wait)
	}
	if len(st.released) != 2 || st.released[0] != 2 || st.released[1] != 3 {
		t.Errorf("qaytarilgan: %v, [2 3] kutilgan", st.released)
	}
	if len(tg.sent) != 1 {
		t.Errorf("yuborilgan: %v", tg.sent)
	}
}

func TestRunSavesUsername(t *testing.T) {
	w, _, st := newTest(t)
	ctx, cancel := context.WithCancel(context.Background())
	w.RetryDelay = 10 * time.Millisecond
	go func() { time.Sleep(200 * time.Millisecond); cancel() }()
	w.Run(ctx) // ctx bekor bo'lgach qaytishi kerak
	if st.username != "UstameTestBot" {
		t.Errorf("username = %q", st.username)
	}
}

func TestErrorsDoNotLeakToken(t *testing.T) {
	c := &Client{Token: "123:SECRET", BaseURL: "http://127.0.0.1:1", HTTP: &http.Client{Timeout: time.Second}}
	err := c.SendMessage(context.Background(), 1, "x")
	if err == nil || strings.Contains(err.Error(), "SECRET") {
		t.Fatalf("xato matnida token bo'lmasligi kerak: %v", err)
	}
}
