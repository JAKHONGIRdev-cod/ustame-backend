package push

import (
	"context"
	"log"
	"strings"
	"time"
)

// Expo push receipts (2026-11-23). Expo xabarni qabul qilgach ticket beradi, telefon xizmatiga (FCM/APNs) yetganini
// esa ~15 daqiqadan keyin receipt aytadi. ReceiptWorker push ishchisidan signal kelganda (Worker.Sent) Delay kutib
// receipt'larni oladi:
//   - ok — yetkazildi (push_receipts.status='ok');
//   - error — rad etildi: sababi push_receipts.error va notification_outbox.push_error ga (admin panel ko'radi),
//     DeviceNotRegistered bo'lsa token o'chiriladi (ilova o'chirilgan yoki ruxsat olib qo'yilgan);
//   - 24 soatda receipt kelmasa — 'unknown'.
// Baza doimiy so'ralmaydi (Neon uxlab tursin): faqat push yuborilgandan keyin va server ishga tushganda.

// ReceiptStore — receipt ishchisining baza amallari (pgx'dagisi: store.go).
type ReceiptStore interface {
	// PendingReceipts — tekshirilmagan va olderThan dan oldin yuborilgan ticket'lar (eng eskisi birinchi).
	PendingReceipts(ctx context.Context, olderThan time.Duration, limit int) ([]TicketRef, error)
	// SaveReceipts — natijalar; rad etilganlarning sababi notification_outbox.push_error ga ham yoziladi.
	SaveReceipts(ctx context.Context, results []ReceiptResult) error
	// HasPendingReceipts — hali tekshirilmagan ticket bormi (keyingi tekshiruvni rejalashtirish uchun).
	HasPendingReceipts(ctx context.Context) (bool, error)
	DeleteTokens(ctx context.Context, tokens []string) error
}

// ReceiptFetcher — Expo getReceipts.
type ReceiptFetcher interface {
	GetReceipts(ctx context.Context, ids []string) (map[string]Receipt, error)
}

// ReceiptResult — bitta ticket'ning yakuniy holati.
type ReceiptResult struct {
	TicketID string
	OutboxID int64
	Status   string // ok | error | unknown
	Error    string // error bo'lsa: "DeviceNotRegistered ..." (500 belgigacha)
}

type ReceiptWorker struct {
	Expo  ReceiptFetcher
	Store ReceiptStore
	// Kick — push ishchisidan signal (Worker.Sent bilan bir kanal).
	Kick <-chan struct{}

	Delay   time.Duration // ticket'dan keyin receipt so'rash vaqti (standart 15 daqiqa)
	Expire  time.Duration // shuncha vaqtda receipt kelmasa — unknown (standart 24 soat)
	Batch   int           // bitta getReceipts so'rovidagi id'lar (Expo cheklovi 1000)
	Timeout time.Duration // bitta tekshiruv uchun (standart 1 daqiqa)
}

func (r *ReceiptWorker) defaults() {
	if r.Delay == 0 {
		r.Delay = 15 * time.Minute
	}
	if r.Expire == 0 {
		r.Expire = 24 * time.Hour
	}
	if r.Batch == 0 || r.Batch > 1000 {
		r.Batch = 1000
	}
	if r.Timeout == 0 {
		r.Timeout = time.Minute
	}
}

// Run — ctx bekor qilinguncha. Server ishga tushganda bir marta tekshiradi (oldingi ishga tushishdan qolganlar),
// keyin faqat signal kelganda Delay kutib tekshiradi; tekshirilmaganlar qolsa — yana Delay dan keyin.
func (r *ReceiptWorker) Run(ctx context.Context) {
	r.defaults()
	var timer *time.Timer
	var due <-chan time.Time
	arm := func() {
		if timer == nil {
			timer = time.NewTimer(r.Delay)
			due = timer.C
		}
	}
	if r.checkAll(ctx) {
		arm()
	}
	for {
		select {
		case <-ctx.Done():
			if timer != nil {
				timer.Stop()
			}
			return
		case <-r.Kick:
			arm()
		case <-due:
			timer, due = nil, nil
			if r.checkAll(ctx) {
				arm()
			}
		}
	}
}

// checkAll — tayyor bo'lgan barcha ticket'larni partiyalab tekshiradi. Natija: hali tekshirilmagan ticket qoldimi.
func (r *ReceiptWorker) checkAll(ctx context.Context) bool {
	r.defaults()
	for ctx.Err() == nil {
		n, saved, err := r.checkOnce(ctx)
		if err != nil {
			if ctx.Err() == nil {
				log.Printf("push receipts: %v", err)
			}
			return true // keyinroq qayta urinamiz
		}
		// To'liq partiya va hammasi hal bo'lgan bo'lsa — keyingisi; aks holda (receipt'lar hali tayyor emas) to'xtaymiz,
		// bo'lmasa o'sha ticket'larni qayta-qayta so'rab qolardik
		if n < r.Batch || saved < n {
			break
		}
	}
	cctx, cancel := context.WithTimeout(ctx, r.Timeout)
	defer cancel()
	pending, err := r.Store.HasPendingReceipts(cctx)
	if err != nil {
		return true
	}
	return pending
}

// checkOnce — bitta partiya. n — bazadan olingan ticket'lar, saved — holati yozilganlari.
func (r *ReceiptWorker) checkOnce(ctx context.Context) (n, saved int, err error) {
	ctx, cancel := context.WithTimeout(ctx, r.Timeout)
	defer cancel()
	refs, err := r.Store.PendingReceipts(ctx, r.Delay, r.Batch)
	if err != nil || len(refs) == 0 {
		return 0, 0, err
	}
	ids := make([]string, len(refs))
	for i, ref := range refs {
		ids[i] = ref.TicketID
	}
	receipts, err := r.Expo.GetReceipts(ctx, ids)
	if err != nil {
		return 0, 0, err
	}

	var results []ReceiptResult
	var gone []string
	for _, ref := range refs {
		rc, ok := receipts[ref.TicketID]
		switch {
		case !ok:
			// Receipt hali tayyor emas yoki Expo uni topmadi: muddati o'tgan bo'lsa — noma'lum, aks holda kutamiz
			if !ref.CreatedAt.IsZero() && time.Since(ref.CreatedAt) > r.Expire {
				results = append(results, ReceiptResult{TicketID: ref.TicketID, OutboxID: ref.OutboxID, Status: "unknown"})
			}
		case rc.Status == "ok":
			results = append(results, ReceiptResult{TicketID: ref.TicketID, OutboxID: ref.OutboxID, Status: "ok"})
		default:
			why := strings.TrimSpace(rc.Details.Error + " " + rc.Message)
			if len(why) > 500 {
				why = why[:500]
			}
			if rc.Details.Error == "DeviceNotRegistered" {
				gone = append(gone, ref.Token)
			} else {
				log.Printf("push receipt: %d-xabar telefonga yetmadi: %s", ref.OutboxID, why)
			}
			results = append(results, ReceiptResult{TicketID: ref.TicketID, OutboxID: ref.OutboxID, Status: "error", Error: why})
		}
	}
	if len(gone) > 0 {
		if err := r.Store.DeleteTokens(ctx, gone); err != nil {
			log.Printf("push receipts: eskirgan tokenlar o'chirilmadi: %v", err)
		}
	}
	if len(results) > 0 {
		if err := r.Store.SaveReceipts(ctx, results); err != nil {
			return 0, 0, err
		}
	}
	return len(refs), len(results), nil
}
