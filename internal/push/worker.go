package push

import (
	"context"
	"errors"
	"log"
	"time"
)

// Message — navbatdagi bitta xabar bitta telefon uchun (foydalanuvchining har bir qurilmasiga alohida).
type Message struct {
	ID        int64 // notification_outbox.id
	Token     string
	Text      string
	Link      *string // ilovada ochiladigan sahifa
	CreatedAt time.Time
}

// Store — push ishchisi ishlatadigan baza amallari (pgx'dagisi: store.go).
type Store interface {
	// Claim — push yuborilmagan xabarlarni "yuborildi" deb belgilab oladi va har biri uchun
	// foydalanuvchining barcha tokenlarini qaytaradi (tokeni yo'q foydalanuvchiniki shunchaki belgilanadi).
	Claim(ctx context.Context, limit int) ([]Message, error)
	// Release — yuborib bo'lmagan xabarlarni keyinroq qayta urinish uchun qaytaradi.
	Release(ctx context.Context, ids []int64) error
	// DeleteTokens — ilova o'chirilgan yoki ruxsat olib qo'yilgan telefonlar tokenlari.
	DeleteTokens(ctx context.Context, tokens []string) error
}

type Sender interface {
	Send(ctx context.Context, msgs []ExpoMessage) ([]Ticket, error)
}

type Worker struct {
	Expo  Sender
	Store Store

	Every      time.Duration // navbatni tekshirish oralig'i (standart 3 s)
	RetryDelay time.Duration // xatodan keyin kutish (standart 10 s)
	MaxAge     time.Duration // shundan eski xabar telefonga yuborilmaydi (standart 6 soat)
}

const (
	batchRows = 50  // bir urinishda navbatdan olinadigan xabarlar
	batchSend = 100 // Expo bitta so'rovda qabul qiladigan eng ko'p xabar
	title     = "Ustame"
)

func (w *Worker) defaults() {
	if w.Every == 0 {
		w.Every = 3 * time.Second
	}
	if w.RetryDelay == 0 {
		w.RetryDelay = 10 * time.Second
	}
	if w.MaxAge == 0 {
		w.MaxAge = 6 * time.Hour
	}
}

// Run — ctx bekor qilinguncha ishlaydi.
func (w *Worker) Run(ctx context.Context) {
	w.defaults()
	for ctx.Err() == nil {
		wait := w.Every
		if w.deliverOnce(ctx) {
			wait = w.RetryDelay
		}
		t := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			t.Stop()
			return
		case <-t.C:
		}
	}
}

// deliverOnce — bir partiyani yuboradi; true — xato bo'ldi, keyingi urinishgacha ko'proq kutish kerak.
func (w *Worker) deliverOnce(ctx context.Context) bool {
	w.defaults()
	list, err := w.Store.Claim(ctx, batchRows)
	if err != nil {
		if ctx.Err() == nil {
			log.Printf("push: navbat o'qilmadi: %v", err)
		}
		return true
	}
	failed := false
	for start := 0; start < len(list); start += batchSend {
		if w.send(ctx, list[start:min(start+batchSend, len(list))]) {
			failed = true
		}
	}
	return failed
}

func (w *Worker) send(ctx context.Context, part []Message) bool {
	msgs := make([]ExpoMessage, len(part))
	for i, m := range part {
		msgs[i] = ExpoMessage{To: m.Token, Title: title, Body: m.Text, Sound: "default", ChannelID: "default", Priority: "high"}
		if m.Link != nil {
			msgs[i].Data = map[string]string{"url": *m.Link}
		}
	}
	tickets, err := w.Expo.Send(ctx, msgs)
	if err != nil {
		// Butun so'rov o'tmadi (tarmoq, Expo ishlamayapti, 429): eskirmaganlarini keyinroq qayta yuboramiz
		var retry []int64
		seen := map[int64]bool{}
		for _, m := range part {
			if !seen[m.ID] && time.Since(m.CreatedAt) < w.MaxAge {
				seen[m.ID] = true
				retry = append(retry, m.ID)
			}
		}
		var httpErr *HTTPError
		if !errors.As(err, &httpErr) || httpErr.Status != 400 {
			if len(retry) > 0 {
				if err := w.Store.Release(ctx, retry); err != nil {
					log.Printf("push: xabarlarni qaytarib bo'lmadi: %v", err)
				}
			}
		}
		if ctx.Err() == nil {
			log.Printf("push: %d ta xabar yuborilmadi: %v", len(part), err)
		}
		return true
	}

	var gone []string
	for i, t := range tickets {
		if t.Status == "ok" {
			continue
		}
		if t.Details.Error == "DeviceNotRegistered" {
			gone = append(gone, part[i].Token)
			continue
		}
		// Masalan InvalidCredentials — EAS'ga FCM kaliti yuklanmagan
		log.Printf("push: %d-xabar rad etildi: %s %s", part[i].ID, t.Details.Error, t.Message)
	}
	if len(gone) > 0 {
		if err := w.Store.DeleteTokens(ctx, gone); err != nil {
			log.Printf("push: eskirgan tokenlar o'chirilmadi: %v", err)
		}
	}
	return false
}
