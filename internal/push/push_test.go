package push

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"slices"
	"testing"
	"time"
)

type fakeStore struct {
	queue    []Message
	released []int64
	deleted  []string
}

func (f *fakeStore) Claim(_ context.Context, limit int) ([]Message, error) {
	n := min(limit, len(f.queue))
	out := f.queue[:n]
	f.queue = f.queue[n:]
	return out, nil
}

func (f *fakeStore) Release(_ context.Context, ids []int64) error {
	f.released = append(f.released, ids...)
	return nil
}

func (f *fakeStore) DeleteTokens(_ context.Context, tokens []string) error {
	f.deleted = append(f.deleted, tokens...)
	return nil
}

// fakeExpo — Expo Push API o'rnida: kelgan xabarlarni yozib oladi va berilgan javobni qaytaradi.
func fakeExpo(t *testing.T, status int, reply func(msgs []ExpoMessage) any) (*Client, *[]ExpoMessage) {
	t.Helper()
	var got []ExpoMessage
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var msgs []ExpoMessage
		if err := json.NewDecoder(r.Body).Decode(&msgs); err != nil {
			t.Errorf("so'rov tanasi o'qilmadi: %v", err)
		}
		got = append(got, msgs...)
		w.WriteHeader(status)
		json.NewEncoder(w).Encode(reply(msgs))
	}))
	t.Cleanup(srv.Close)
	return &Client{URL: srv.URL, HTTP: srv.Client()}, &got
}

func okTickets(msgs []ExpoMessage) any {
	data := make([]map[string]string, len(msgs))
	for i := range msgs {
		data[i] = map[string]string{"status": "ok", "id": "x"}
	}
	return map[string]any{"data": data}
}

func link(s string) *string { return &s }

func TestDeliverSendsWithLink(t *testing.T) {
	expo, got := fakeExpo(t, 200, okTickets)
	st := &fakeStore{queue: []Message{
		{ID: 1, Token: "ExponentPushToken[aaaaaaaaaaaa]", Text: "Yangi taklif", Link: link("/job/42"), CreatedAt: time.Now()},
		{ID: 1, Token: "ExponentPushToken[bbbbbbbbbbbb]", Text: "Yangi taklif", Link: link("/job/42"), CreatedAt: time.Now()},
		{ID: 2, Token: "ExponentPushToken[aaaaaaaaaaaa]", Text: "Xabar", CreatedAt: time.Now()},
	}}
	w := &Worker{Expo: expo, Store: st}
	if failed := w.deliverOnce(context.Background()); failed {
		t.Fatal("xato bo'lmasligi kerak edi")
	}
	if len(*got) != 3 {
		t.Fatalf("yuborilgan = %d, kutilgan 3 (har bir telefonga alohida)", len(*got))
	}
	m := (*got)[0]
	if m.Title != "Ustame" || m.Body != "Yangi taklif" || m.Data["url"] != "/job/42" || m.ChannelID != "default" {
		t.Fatalf("xabar noto'g'ri: %+v", m)
	}
	if (*got)[2].Data != nil {
		t.Fatalf("havolasiz xabarda data bo'lmasligi kerak: %+v", (*got)[2].Data)
	}
	if len(st.released) != 0 || len(st.deleted) != 0 {
		t.Fatalf("hech narsa qaytarilmasligi/o'chirilmasligi kerak: %v %v", st.released, st.deleted)
	}
}

func TestDeliverDeletesUnregisteredTokens(t *testing.T) {
	expo, _ := fakeExpo(t, 200, func(msgs []ExpoMessage) any {
		return map[string]any{"data": []map[string]any{
			{"status": "ok", "id": "x"},
			{"status": "error", "message": "not registered", "details": map[string]string{"error": "DeviceNotRegistered"}},
		}}
	})
	st := &fakeStore{queue: []Message{
		{ID: 1, Token: "ExponentPushToken[aaaaaaaaaaaa]", Text: "a", CreatedAt: time.Now()},
		{ID: 1, Token: "ExponentPushToken[gonegonegone]", Text: "a", CreatedAt: time.Now()},
	}}
	(&Worker{Expo: expo, Store: st}).deliverOnce(context.Background())
	if !slices.Equal(st.deleted, []string{"ExponentPushToken[gonegonegone]"}) {
		t.Fatalf("o'chirilgan tokenlar = %v", st.deleted)
	}
	if len(st.released) != 0 {
		t.Fatalf("qisman xato butun xabarni qaytarmasligi kerak: %v", st.released)
	}
}

func TestDeliverReleasesOnServerError(t *testing.T) {
	expo, _ := fakeExpo(t, 503, func([]ExpoMessage) any { return map[string]string{"error": "unavailable"} })
	st := &fakeStore{queue: []Message{
		{ID: 7, Token: "ExponentPushToken[aaaaaaaaaaaa]", Text: "a", CreatedAt: time.Now()},
		{ID: 7, Token: "ExponentPushToken[bbbbbbbbbbbb]", Text: "a", CreatedAt: time.Now()},
		{ID: 8, Token: "ExponentPushToken[aaaaaaaaaaaa]", Text: "eski", CreatedAt: time.Now().Add(-7 * time.Hour)},
	}}
	w := &Worker{Expo: expo, Store: st}
	if failed := w.deliverOnce(context.Background()); !failed {
		t.Fatal("xato bo'lishi kerak edi")
	}
	// 7 bir marta qaytariladi (ikki telefon bo'lsa ham), eskirgan 8 tashlab yuboriladi
	if !slices.Equal(st.released, []int64{7}) {
		t.Fatalf("qaytarilganlar = %v, kutilgan [7]", st.released)
	}
}

func TestDeliverDoesNotRetryBadRequest(t *testing.T) {
	expo, _ := fakeExpo(t, 400, func([]ExpoMessage) any { return map[string]string{"error": "bad"} })
	st := &fakeStore{queue: []Message{{ID: 3, Token: "ExponentPushToken[aaaaaaaaaaaa]", Text: "a", CreatedAt: time.Now()}}}
	(&Worker{Expo: expo, Store: st}).deliverOnce(context.Background())
	if len(st.released) != 0 {
		t.Fatalf("400 da qayta urinish befoyda — qaytarilmasligi kerak: %v", st.released)
	}
}

func TestDeliverEmptyQueueSendsNothing(t *testing.T) {
	expo, got := fakeExpo(t, 200, okTickets)
	(&Worker{Expo: expo, Store: &fakeStore{}}).deliverOnce(context.Background())
	if len(*got) != 0 {
		t.Fatalf("bo'sh navbatda so'rov ketmasligi kerak: %d", len(*got))
	}
}
