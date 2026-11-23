package push

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"slices"
	"sync"
	"testing"
	"time"
)

// Push yuborilgach Expo bergan ticket id'lar saqlanadi va receipt ishchisiga signal ketadi.
func TestDeliverSavesTicketsAndSignals(t *testing.T) {
	expo, _ := fakeExpo(t, 200, func(msgs []ExpoMessage) any {
		return map[string]any{"data": []map[string]any{
			{"status": "ok", "id": "t1"},
			{"status": "error", "message": "x", "details": map[string]string{"error": "MessageTooBig"}},
			{"status": "ok", "id": "t3"},
		}}
	})
	store := &fakeStore{}
	sent := make(chan struct{}, 1)
	w := &Worker{Expo: expo, Store: store, Sent: sent}
	now := time.Now()
	store.add(Message{ID: 1, Token: "A", Text: "a", CreatedAt: now})
	store.add(Message{ID: 2, Token: "B", Text: "b", CreatedAt: now})
	store.add(Message{ID: 3, Token: "C", Text: "c", CreatedAt: now})
	w.deliverOnce(context.Background())

	if len(store.tickets) != 2 || store.tickets[0] != (TicketRef{TicketID: "t1", OutboxID: 1, Token: "A"}) ||
		store.tickets[1] != (TicketRef{TicketID: "t3", OutboxID: 3, Token: "C"}) {
		t.Fatalf("saqlangan ticket'lar noto'g'ri: %+v", store.tickets)
	}
	select {
	case <-sent:
	default:
		t.Fatal("receipt ishchisiga signal ketmadi")
	}
}

type fakeReceiptStore struct {
	mu       sync.Mutex
	pending  []TicketRef
	results  []ReceiptResult
	deleted  []string
	pendings int // PendingReceipts chaqiruvlari
}

func (f *fakeReceiptStore) PendingReceipts(_ context.Context, _ time.Duration, limit int) ([]TicketRef, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.pendings++
	return slices.Clone(f.pending[:min(limit, len(f.pending))]), nil
}

func (f *fakeReceiptStore) SaveReceipts(_ context.Context, results []ReceiptResult) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.results = append(f.results, results...)
	done := map[string]bool{}
	for _, r := range results {
		done[r.TicketID] = true
	}
	f.pending = slices.DeleteFunc(f.pending, func(t TicketRef) bool { return done[t.TicketID] })
	return nil
}

func (f *fakeReceiptStore) HasPendingReceipts(context.Context) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.pending) > 0, nil
}

func (f *fakeReceiptStore) DeleteTokens(_ context.Context, tokens []string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.deleted = append(f.deleted, tokens...)
	return nil
}

func (f *fakeReceiptStore) pendingCalls() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.pendings
}

type fakeFetcher struct {
	mu    sync.Mutex
	data  map[string]Receipt
	calls [][]string
}

func (f *fakeFetcher) GetReceipts(_ context.Context, ids []string) (map[string]Receipt, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, slices.Clone(ids))
	out := map[string]Receipt{}
	for _, id := range ids {
		if r, ok := f.data[id]; ok {
			out[id] = r
		}
	}
	return out, nil
}

func receipt(status, errCode string) Receipt {
	var r Receipt
	r.Status = status
	r.Details.Error = errCode
	if errCode != "" {
		r.Message = "sabab"
	}
	return r
}

// ok — yetkazildi; DeviceNotRegistered — token o'chiriladi; boshqa xato — sababi yoziladi;
// 24 soatda kelmagan receipt — unknown; hali tayyor bo'lmagani — kutadi.
func TestReceiptsClassifyResults(t *testing.T) {
	now := time.Now()
	store := &fakeReceiptStore{pending: []TicketRef{
		{TicketID: "ok", OutboxID: 1, Token: "A", CreatedAt: now.Add(-20 * time.Minute)},
		{TicketID: "gone", OutboxID: 2, Token: "B", CreatedAt: now.Add(-20 * time.Minute)},
		{TicketID: "big", OutboxID: 3, Token: "C", CreatedAt: now.Add(-20 * time.Minute)},
		{TicketID: "lost", OutboxID: 4, Token: "D", CreatedAt: now.Add(-25 * time.Hour)},
		{TicketID: "wait", OutboxID: 5, Token: "E", CreatedAt: now.Add(-20 * time.Minute)},
	}}
	fetch := &fakeFetcher{data: map[string]Receipt{
		"ok":   receipt("ok", ""),
		"gone": receipt("error", "DeviceNotRegistered"),
		"big":  receipt("error", "MessageTooBig"),
	}}
	r := &ReceiptWorker{Expo: fetch, Store: store}
	pending := r.checkAll(context.Background())

	got := map[string]ReceiptResult{}
	for _, res := range store.results {
		got[res.TicketID] = res
	}
	if got["ok"].Status != "ok" || got["gone"].Status != "error" || got["big"].Status != "error" || got["lost"].Status != "unknown" {
		t.Fatalf("natijalar noto'g'ri: %+v", got)
	}
	if got["big"].Error != "MessageTooBig sabab" || got["big"].OutboxID != 3 {
		t.Fatalf("xato sababi yoki xabar id noto'g'ri: %+v", got["big"])
	}
	if _, ok := got["wait"]; ok {
		t.Fatal("hali tayyor bo'lmagan receipt hal qilinmasligi kerak")
	}
	if !slices.Equal(store.deleted, []string{"B"}) {
		t.Fatalf("faqat DeviceNotRegistered tokeni o'chirilishi kerak: %v", store.deleted)
	}
	if !pending {
		t.Fatal("kutilayotgan ticket qolgan — keyingi tekshiruv rejalashtirilishi kerak")
	}
	if len(fetch.calls) != 1 {
		t.Fatalf("receipt'lar bitta so'rovda olinishi kerak, so'rovlar: %d", len(fetch.calls))
	}
}

// Server ishga tushganda kutilayotgan ticket bo'lmasa baza qayta-qayta so'ralmaydi; signaldan keyin Delay o'tib tekshiradi.
func TestReceiptWorkerChecksAfterKick(t *testing.T) {
	store := &fakeReceiptStore{}
	fetch := &fakeFetcher{data: map[string]Receipt{"t1": receipt("ok", "")}}
	kick := make(chan struct{}, 1)
	r := &ReceiptWorker{Expo: fetch, Store: store, Kick: kick, Delay: 30 * time.Millisecond}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go r.Run(ctx)

	time.Sleep(60 * time.Millisecond)
	if n := store.pendingCalls(); n != 1 {
		t.Fatalf("ishga tushganda bir marta tekshirishi kerak, tekshiruvlar: %d", n)
	}
	store.mu.Lock()
	store.pending = []TicketRef{{TicketID: "t1", OutboxID: 7, Token: "A", CreatedAt: time.Now()}}
	store.mu.Unlock()
	kick <- struct{}{}

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		store.mu.Lock()
		done := len(store.results) == 1 && store.results[0].Status == "ok"
		store.mu.Unlock()
		if done {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("signaldan keyin receipt tekshirilmadi")
}

// Expo getReceipts: id'lar so'rovda, javob xaritaga o'qiladi.
func TestClientGetReceipts(t *testing.T) {
	var asked []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			IDs []string `json:"ids"`
		}
		json.NewDecoder(r.Body).Decode(&body)
		asked = body.IDs
		json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{
			"a": map[string]any{"status": "ok"},
			"b": map[string]any{"status": "error", "message": "m", "details": map[string]string{"error": "DeviceNotRegistered"}},
		}})
	}))
	defer srv.Close()
	c := &Client{ReceiptsURL: srv.URL, HTTP: srv.Client()}
	got, err := c.GetReceipts(context.Background(), []string{"a", "b", "c"})
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(asked, []string{"a", "b", "c"}) {
		t.Fatalf("so'rovdagi id'lar: %v", asked)
	}
	if got["a"].Status != "ok" || got["b"].Details.Error != "DeviceNotRegistered" || len(got) != 2 {
		t.Fatalf("javob noto'g'ri o'qildi: %+v", got)
	}
}
